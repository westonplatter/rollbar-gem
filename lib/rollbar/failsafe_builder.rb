require 'rollbar/payload'
require 'rollbar/version'

module Rollbar
  class FailsafeBuilder
    attr_reader :notifier

    def initialize(notifier)
      @notifier = notifier
    end

    def configuration
      notifier.configuration
    end

    def build_payload(message, exception)
      environment = configuration.environment

      failsafe_data = {
        :level => 'error',
        :environment => environment.to_s,
        :body => {
          :message => {
            :body => "Failsafe from rollbar-gem: #{message}"
          }
        },
        :notifier => {
          :name => 'rollbar-gem',
          :version => Rollbar::VERSION
        },
        :internal => true,
        :failsafe => true
      }

      payload_value = {
        'access_token' => configuration.access_token,
        'data' => failsafe_data
      }

      Rollbar::Payload.new(payload_value, configuration)
    end
  end
end
