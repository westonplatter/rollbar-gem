require 'multi_json'
require 'iconv' unless ''.respond_to? :encode

require 'rollbar/util'
require 'rollbar/truncation'

module Rollbar
  class Payload
    attr_reader :value
    attr_reader :configuration

    def initialize(value, configuration)
      @value = value
      @configuration = configuration

      enforce_valid_utf8
    end

    def inspect
      value.inspect
    end

    def [](key)
      value[key]
    end

    def data
      value['data']
    end

    def access_token
      value['access_token']
    end

    def ignored?
      ignored_person?
    end

    def ignored_person?
      configuration.ignored_person_ids.include?(person_id)
    end

    def person_id
      person_data = value['data'][:person]
      return unless person_data

      person_data[configuration.person_id_method.to_sym]
    end

    def enforce_valid_utf8
      normalizer = lambda do |object|
        is_symbol = object.is_a?(Symbol)

        return object unless object == object.to_s || is_symbol

        value = object.to_s

        if value.respond_to? :encode
          options = { :invalid => :replace, :undef => :replace, :replace => '' }
          ascii_encodings = [Encoding.find('US-ASCII'), Encoding.find('ASCII-8BIT')]

          args = ['UTF-8']
          args << 'binary' if ascii_encodings.include?(value.encoding)
          args << options

          encoded_value = value.encode(*args)
        else
          encoded_value = ::Iconv.conv('UTF-8//IGNORE', 'UTF-8', value)
        end

        is_symbol ? encoded_value.to_sym : encoded_value
      end

      Rollbar::Util.iterate_and_update(value, normalizer)
    end

    def dump
      payload = value
      payload = MultiJson.load(value) if value.is_a?(String)

      # Ensure all keys are strings since we can receive the payload inline or
      # from an async handler job, which can be serialized.
      stringified_payload = Rollbar::Util::Hash.deep_stringify_keys(payload)
      result = Rollbar::Truncation.truncate(stringified_payload)

      return result unless Rollbar::Truncation.truncate?(result)

      original_size = MultiJson.dump(payload).bytesize
      final_size = result.bytesize
      send_failsafe("Could not send payload due to it being too large after truncating attempts. Original size: #{original_size} Final size: #{final_size}", nil)
      log_error "[Rollbar] Payload too large to be sent: #{MultiJson.dump(payload)}"

      nil
    end
  end
end
