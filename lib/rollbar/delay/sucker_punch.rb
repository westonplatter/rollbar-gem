require 'sucker_punch'

module Rollbar
  module Delay
    class SuckerPunch

      include ::SuckerPunch::Job

      def self.call(payload)
        new.async.perform payload
      end

      def perform(*args)
        payload = Rollbar::Payload.new(args.first, Rollbar.configuration)
        Rollbar.process_payload_safely(*args)
      end
    end
  end
end
