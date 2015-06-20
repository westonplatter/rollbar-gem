begin
  require 'securerandom'
rescue LoadError
end

require 'rollbar/version'
require 'rollbar/util'

module Rollbar
  class Builder
    attr_reader :notifier

    def initialize(notifier)
      @notifier = notifier
    end

    def configuration
      notifier.configuration
    end

    def build_payload(level, message, exception, extra)
      environment = configuration.environment
      environment = 'unspecified' if environment.nil? || environment.empty?

      data = {
        :timestamp => Time.now.to_i,
        :environment => environment,
        :level => level,
        :language => 'ruby',
        :framework => configuration.framework,
        :server => server_data,
        :notifier => {
          :name => 'rollbar-gem',
          :version => Rollbar::VERSION
        }
      }

      data[:body] = build_payload_body(message, exception, extra)
      data[:project_package_paths] = configuration.project_gem_paths if configuration.project_gem_paths
      data[:code_version] = configuration.code_version if configuration.code_version
      data[:uuid] = SecureRandom.uuid if defined?(SecureRandom) && SecureRandom.respond_to?(:uuid)

      Rollbar::Util.deep_merge(data, configuration.payload_options)

      data[:person] = data[:person].call if data[:person].respond_to?(:call)
      data[:request] = data[:request].call if data[:request].respond_to?(:call)
      data[:context] = data[:context].call if data[:context].respond_to?(:call)

      # Our API doesn't allow null context values, so just delete
      # the key if value is nil.
      data.delete(:context) unless data[:context]

      payload_value = {
        'access_token' => configuration.access_token,
        'data' => data
      }

      Rollbar::Payload.new(payload_value, configuration)
    end

    def build_payload_body(message, exception, extra)
      extra = Rollbar::Util.deep_merge(custom_data, extra || {}) if custom_data_method?

      if exception
        build_payload_body_exception(message, exception, extra)
      else
        build_payload_body_message(message, extra)
      end
    end

    def custom_data_method?
      !!configuration.custom_data_method
    end

    def custom_data
      data = configuration.custom_data_method.call
      Rollbar::Util.deep_copy(data)
    rescue => e
      return {} if configuration.safely?

      notifier.report_custom_data_error(e)
    end

    def build_payload_body_exception(message, exception, extra)
      traces = trace_chain(exception)

      traces[0][:exception][:description] = message if message
      traces[0][:extra] = extra if extra

      if traces.size > 1
        { :trace_chain => traces }
      elsif traces.size == 1
        { :trace => traces[0] }
      end
    end

    def trace_chain(exception)
      traces = [trace_data(exception)]
      visited = [exception]

      while exception.respond_to?(:cause) && (cause = exception.cause) && !visited.include?(cause)
        traces << trace_data(cause)
        visited << cause
        exception = cause
      end

      traces
    end

    def trace_data(exception)
      frames = exception_backtrace(exception).map do |frame|
        # parse the line
        match = frame.match(/(.*):(\d+)(?::in `([^']+)')?/)

        if match
          { :filename => match[1], :lineno => match[2].to_i, :method => match[3] }
        else
          { :filename => "<unknown>", :lineno => 0, :method => frame }
        end
      end

      # reverse so that the order is as rollbar expects
      frames.reverse!

      {
        :frames => frames,
        :exception => {
          :class => exception.class.name,
          :message => exception.message
        }
      }
    end

    # Returns the backtrace to be sent to our API. There are 3 options:
    #
    # 1. The exception received has a backtrace, then that backtrace is returned.
    # 2. configuration.populate_empty_backtraces is disabled, we return [] here
    # 3. The user has configuration.populate_empty_backtraces is enabled, then:
    #
    # We want to send the caller as backtrace, but the first lines of that array
    # are those from the user's Rollbar.error line until this method. We want
    # to remove those lines.
    def exception_backtrace(exception)
      return exception.backtrace if exception.backtrace.respond_to?( :map )
      return [] unless configuration.populate_empty_backtraces

      caller_backtrace = caller
      caller_backtrace.shift while caller_backtrace[0].include?(rollbar_lib_gem_dir)
      caller_backtrace
    end

    def rollbar_lib_gem_dir
      Gem::Specification.find_by_name('rollbar').gem_dir + '/lib'
    end

    def build_payload_body_message(message, extra)
      result = { :body => message || 'Empty message'}
      result[:extra] = extra if extra

      { :message => result }
    end

    def server_data
      data = {
        :host => Socket.gethostname
      }
      data[:root] = configuration.root.to_s if configuration.root
      data[:branch] = configuration.branch if configuration.branch
      data[:pid] = Process.pid

      data
    end
  end
end
