require 'fluent/output'

module Fluent
  class MongoOutput < BufferedOutput
    Plugin.register_output('mongo', self)

    require 'fluent/plugin/mongo_util'
    include MongoUtil

    include SetTagKeyMixin
    config_set_default :include_tag_key, false

    include SetTimeKeyMixin
    config_set_default :include_time_key, true

    config_param :database, :string
    config_param :collection, :string, :default => 'untagged'
    config_param :host, :string, :default => 'localhost'
    config_param :port, :integer, :default => 27017
    config_param :ignore_invalid_record, :bool, :default => false
    config_param :disable_collection_check, :bool, :default => nil
    config_param :exclude_broken_fields, :string, :default => nil
    config_param :write_concern, :integer, :default => nil
    config_param :journaled, :bool, :default => false
    config_param :socket_pool_size, :integer, :default => 1
    config_param :replace_dot_in_key_with, :string, :default => nil
    config_param :replace_dollar_in_key_with, :string, :default => nil

    # tag mapping mode
    config_param :tag_mapped, :bool, :default => false
    config_param :remove_tag_prefix, :string, :default => nil

    # SSL connection
    config_param :ssl, :bool, :default => false
    config_param :ssl_cert, :string, :default => nil
    config_param :ssl_key, :string, :default => nil
    config_param :ssl_key_pass_phrase, :string, :default => nil, :secret => true
    config_param :ssl_verify, :bool, :default => false
    config_param :ssl_ca_cert, :string, :default => nil

    # For older (1.7 or earlier) MongoDB versions
    config_param :mongodb_smaller_bson_limit, :bool, :default => false

    attr_reader :collection_options, :connection_options

    unless method_defined?(:log)
      define_method(:log) { $log }
    end

    def initialize
      super
      require 'mongo'
      require 'msgpack'

      @clients = {}
      @connection_options = {}
      @collection_options = {:capped => false}
    end

    # Following limits are heuristic. BSON is sometimes bigger than MessagePack and JSON.
    LIMIT_BEFORE_v1_8 = 2 * 1024 * 1024  # 2MB = 4MB  / 2
    LIMIT_AFTER_v1_8 =  8 * 1024 * 1024  # 8MB = 16MB / 2

    def configure(conf)
      if conf.has_key?('buffer_chunk_limit')
        configured_chunk_limit_size = Config.size_value(conf['buffer_chunk_limit'])
        estimated_limit_size = LIMIT_AFTER_v1_8
        estimated_limit_size_conf = '8m'
        if conf.has_key?('mongodb_smaller_bson_limit') && Config.bool_value(conf['mongodb_smaller_bson_limit'])
          estimated_limit_size = LIMIT_BEFORE_v1_8
          estimated_limit_size_conf = '2m'
        end
        if configured_chunk_limit_size > estimated_limit_size
          log.warn ":buffer_chunk_limit(#{conf['buffer_chunk_limit']}) is large. Reset :buffer_chunk_limit with #{estimated_limit_size_conf}"
          conf['buffer_chunk_limit'] = estimated_limit_size_conf
        end
      else
        if conf.has_key?('mongodb_smaller_bson_limit') && Config.bool_value(conf['mongodb_smaller_bson_limit'])
          conf['buffer_chunk_limit'] = '2m'
        else
          conf['buffer_chunk_limit'] = '8m'
        end
      end

      super

      if conf.has_key?('tag_mapped')
        @tag_mapped = true
        @disable_collection_check = true if @disable_collection_check.nil?
      else
        @disable_collection_check = false if @disable_collection_check.nil?
      end
      raise ConfigError, "normal mode requires collection parameter" if !@tag_mapped and !conf.has_key?('collection')

      if remove_tag_prefix = conf['remove_tag_prefix']
        @remove_tag_prefix = Regexp.new('^' + Regexp.escape(remove_tag_prefix))
      end

      @exclude_broken_fields = @exclude_broken_fields.split(',') if @exclude_broken_fields

      if conf.has_key?('capped')
        raise ConfigError, "'capped_size' parameter is required on <store> of Mongo output" unless conf.has_key?('capped_size')
        @collection_options[:capped] = true
        @collection_options[:size] = Config.size_value(conf['capped_size'])
        @collection_options[:max] = Config.size_value(conf['capped_max']) if conf.has_key?('capped_max')
      end

      @connection_options[:w] = @write_concern unless @write_concern.nil?
      @connection_options[:j] = @journaled
      @connection_options[:pool_size] = @socket_pool_size

      @connection_options[:ssl] = @ssl

      if @ssl
       @connection_options[:ssl_cert] = @ssl_cert
       @connection_options[:ssl_key] = @ssl_key
       @connection_options[:ssl_key_pass_phrase] = @ssl_key_pass_phrase
       @connection_options[:ssl_verify] = @ssl_verify
       @connection_options[:ssl_ca_cert] = @ssl_ca_cert
      end

      # MongoDB uses BSON's Date for time.
      def @timef.format_nocache(time)
        time
      end

      $log.debug "Setup mongo configuration: mode = #{@tag_mapped ? 'tag mapped' : 'normal'}"
    end

    def start
      # Non tag mapped mode, we can check collection configuration before server start.
      get_or_create_collection(@collection) unless @tag_mapped

      super
    end

    def shutdown
      # Mongo::Connection checks alive or closed myself
      @clients.values.each { |client| client.db.connection.close }
      super
    end

    def format(tag, time, record)
      [time, record].to_msgpack
    end

    def emit(tag, es, chain)
      # TODO: Should replacement using eval in configure?
      if @tag_mapped
        super(tag, es, chain, tag)
      else
        super(tag, es, chain)
      end
    end

    def write(chunk)
      # TODO: See emit comment
      collection_name = @tag_mapped ? chunk.key : @collection
      operate(get_or_create_collection(collection_name), collect_records(chunk))
    end

    private

    INSERT_ARGUMENT = {:collect_on_error => true}
    BROKEN_DATA_KEY = '__broken_data'

    def operate(collection, records)
      begin
        if @replace_dot_in_key_with
          records.map! do |r|
            replace_key_of_hash(r, ".", @replace_dot_in_key_with)
          end
        end
        if @replace_dollar_in_key_with
          records.map! do |r|
            replace_key_of_hash(r, /^\$/, @replace_dollar_in_key_with)
          end
        end

        record_ids, error_records = collection.insert(records, INSERT_ARGUMENT)
        if !@ignore_invalid_record and error_records.size > 0
          operate_invalid_records(collection, error_records)
        end
      rescue Mongo::OperationFailure => e
        # Probably, all records of _records_ are broken...
        if e.error_code == 13066  # 13066 means "Message contains no documents"
          operate_invalid_records(collection, records) unless @ignore_invalid_record
        else
          raise e
        end
      end
      records
    end

    def operate_invalid_records(collection, records)
      converted_records = records.map { |record|
        new_record = {}
        new_record[@tag_key] = record.delete(@tag_key) if @include_tag_key
        new_record[@time_key] = record.delete(@time_key)
        if @exclude_broken_fields
          @exclude_broken_fields.each { |key|
            new_record[key] = record.delete(key)
          }
        end
        new_record[BROKEN_DATA_KEY] = BSON::Binary.new(Marshal.dump(record))
        new_record
      }
      collection.insert(converted_records)
    end

    def collect_records(chunk)
      records = []
      chunk.msgpack_each { |time, record|
        record[@time_key] = Time.at(time || record[@time_key]) if @include_time_key
        records << record
      }
      records
    end

    FORMAT_COLLECTION_NAME_RE = /(^\.+)|(\.+$)/

    def format_collection_name(collection_name)
      formatted = collection_name
      formatted = formatted.gsub(@remove_tag_prefix, '') if @remove_tag_prefix
      formatted = formatted.gsub(FORMAT_COLLECTION_NAME_RE, '')
      formatted = @collection if formatted.size == 0 # set default for nil tag
      formatted
    end

    def get_or_create_collection(collection_name)
      collection_name = format_collection_name(collection_name)
      return @clients[collection_name] if @clients[collection_name]

      @db ||= get_connection
      if @db.collection_names.include?(collection_name)
        collection = @db.collection(collection_name)
        unless @disable_collection_check
          capped = collection.capped?
          unless @collection_options[:capped] == capped # TODO: Verify capped configuration
            new_mode = format_collection_mode(@collection_options[:capped])
            old_mode = format_collection_mode(capped)
            raise ConfigError, "New configuration is different from existing collection: new = #{new_mode}, old = #{old_mode}"
          end
        end
      else
        collection = @db.create_collection(collection_name, @collection_options)
      end

      @clients[collection_name] = collection
    end

    def format_collection_mode(mode)
      mode ? 'capped' : 'normal'
    end

    def get_connection
      db = Mongo::MongoClient.new(@host, @port, @connection_options).db(@database)
      authenticate(db)
    end

    def replace_key_of_hash(hash_or_array, pattern, replacement)
      case hash_or_array
      when Array
        hash_or_array.map do |elm|
          replace_key_of_hash(elm, pattern, replacement)
        end
      when Hash
        result = Hash.new
        hash_or_array.each_pair do |k, v|
          k = k.gsub(pattern, replacement)

          if v.is_a?(Hash) || v.is_a?(Array)
            result[k] = replace_key_of_hash(v, pattern, replacement)
          else
            result[k] = v
          end
        end
        result
      else
        hash_or_array
      end
    end
  end
end
