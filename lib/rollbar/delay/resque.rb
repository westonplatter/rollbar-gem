require 'resque'
require 'rollbar/payload'

module Rollbar
  module Delay
    class Resque
      def self.call(payload)
        new.call(payload)
      end

      def call(payload)
        ::Resque.enqueue(Job, payload)
      end

      class Job
        class << self
          attr_accessor :queue
        end

        self.queue = :default

        def self.perform(payload)
          new.perform(payload)
        end

        def perform(payload_value)
          payload = Rollbar::Payload.new(payload_value, Rollbar.configuration)

          Rollbar.process_payload_safely(payload)
        end
      end
    end
  end
end
