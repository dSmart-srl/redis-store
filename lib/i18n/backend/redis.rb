require 'redis-store'

module I18n
  module Backend
    class Redis
      include Base, Flatten
      attr_accessor :store


      RESERVED_KEYS = [:scope, :default, :separator, :resolve]
      RESERVED_KEYS_PATTERN = /%\{(#{RESERVED_KEYS.join("|")})\}/
      DEPRECATED_INTERPOLATION_SYNTAX_PATTERN = /(\\)?\{\{([^\}]+)\}\}/
      INTERPOLATION_SYNTAX_PATTERN = /%\{([^\}]+)\}/

      # Instantiate the store.
      #
      # Example:
      #   RedisStore.new
      #     # => host: localhost,   port: 6379,  db: 0
      #
      #   RedisStore.new "example.com"
      #     # => host: example.com, port: 6379,  db: 0
      #
      #   RedisStore.new "example.com:23682"
      #     # => host: example.com, port: 23682, db: 0
      #
      #   RedisStore.new "example.com:23682/1"
      #     # => host: example.com, port: 23682, db: 1
      #
      #   RedisStore.new "example.com:23682/1/theplaylist"
      #     # => host: example.com, port: 23682, db: 1, namespace: theplaylist
      #
      #   RedisStore.new "localhost:6379/0", "localhost:6380/0"
      #     # => instantiate a cluster
      def initialize(*addresses)
        @store = ::Redis::Store::Factory.create(addresses)
      end

      def store_translations(locale, data, options = {})
        escape = options.fetch(:escape, true)
        flatten_translations(locale, data, escape, false).each do |key, value|
          case value
          when Proc
            raise "Key-value stores cannot handle procs"
          else
            @store.set "#{locale}.#{key}", value
          end
        end
      end

      def available_locales
        locales = @store.keys.map { |k| k =~ /\./; $` }
        locales.uniq!
        locales.compact!
        locales.map! { |k| k.to_sym }
        locales
      end

      protected
        def default(locale, object, subject, options = {})
          options = options.dup.reject { |key, value| key == :default }
          case subject
          when Array
            subject.each do |item|
              result = resolve(locale, object, item, options) and return result
            end and nil
          else
            resolve(locale, object, subject, options)
          end
        end


        def pluralize(locale, entry, count)
          return entry unless entry.is_a?(Hash) && count

          key = :zero if count == 0 && entry.has_key?(:zero)
          key ||= count == 1 ? :one : :other
          raise InvalidPluralizationData.new(entry, count) unless entry.has_key?(key)
          entry[key]
        end
        def interpolate(locale, string, values = {})
          return string unless string.is_a?(::String) && !values.empty?
          original_values = values.dup

          preserve_encoding(string) do
            string = string.gsub(DEPRECATED_INTERPOLATION_SYNTAX_PATTERN) do
              escaped, key = $1, $2.to_sym
              if escaped
                "{{#{key}}}"
              else
                warn_syntax_deprecation!
                "%{#{key}}"
              end
            end

            keys = string.scan(INTERPOLATION_SYNTAX_PATTERN).flatten
            return string if keys.empty?

            values.each do |key, value|
              if keys.include?(key.to_s)
                value = value.call(values) if interpolate_lambda?(value, string, key)
                value = value.to_s unless value.is_a?(::String)
                values[key] = value
              else
                values.delete(key)
              end
            end

            string % values
          end
        rescue KeyError => e
          if string =~ RESERVED_KEYS_PATTERN
            raise ReservedInterpolationKey.new($1.to_sym, string)
          else
            raise MissingInterpolationArgument.new(original_values, string)
          end
        end





      def lookup(locale, key, scope = [], options = {})
        if options[:scope] and (scope.nil? or (scope.is_a?(Array) and scope.empty?))
          scope = options[:scope]
        end
        #puts '-'
        #puts locale
        #puts key
        #puts scope.inspect
        #puts options.inspect
        #puts '-'

        key = normalize_flat_keys(locale, key, scope, options[:separator])
        #puts "normalize_flat_keys #{key}"

        main_key = "#{locale}.#{key}"
        if result = @store.get(main_key)
          #puts "Main ->->->-> #{result}"
          return result
        end

        child_keys = @store.keys("#{main_key}.*")

        if child_keys.empty?
          #puts "NIL"
          return nil
        end

        result = { }
        subkey_part = (main_key.size + 1)..(-1)
        child_keys.each do |child_key|
          subkey         = child_key[subkey_part].to_sym
          result[subkey] = @store.get child_key
        end
        ##puts "Final ->->-> #{result.inspect}"
        result
      end

      def resolve_link(locale, key)
        key
      end
    end
  end
end

