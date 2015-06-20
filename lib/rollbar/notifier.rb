require 'thread'
require 'socket'
require 'multi_json'

require 'rollbar/configuration'
require 'rollbar/builder'
require 'rollbar/failsafe_builder'
require 'rollbar/delay/girl_friday'
require 'rollbar/delay/thread'
require 'rollbar/logger_proxy'
require 'rollbar/truncation'
require 'rollbar/util'
require 'rollbar/version'

class Notifier
  attr_accessor :configuration
  attr_accessor :last_report

  @file_semaphore = Mutex.new

  def initialize(parent_notifier = nil, payload_options = nil)
    if parent_notifier
      @configuration = parent_notifier.configuration.clone

      if payload_options
        Rollbar::Util.deep_merge(@configuration.payload_options, payload_options)
      end
    else
      @configuration = Rollbar::Configuration.new
    end
  end

  # Similar to configure below, but used only internally within the gem
  # to configure it without initializing any of the third party hooks
  def preconfigure
    yield(configuration)
  end

  def configure
    configuration.enabled = true if configuration.enabled.nil?

    yield(configuration)
  end

  def scope(options = {})
    self.class.new(self, options)
  end

  def scope!(options = {})
    Rollbar::Util.deep_merge(@configuration.payload_options, options)
    self
  end

  # Returns a new notifier with same configuration options
  # but it sets Configuration#safely to true.
  # We are using this flag to avoid having inifite loops
  # when evaluating some custom user methods.
  def safely
    new_notifier = scope
    new_notifier.configuration.safely = true

    new_notifier
  end

  # Turns off reporting for the given block.
  #
  # @example
  #   Rollbar.silenced { raise }
  #
  # @yield Block which exceptions won't be reported.
  def silenced
    yield
  rescue => e
    e.instance_variable_set(:@_rollbar_do_not_report, true)
    raise
  end

  # Sends a report to Rollbar.
  #
  # Accepts any number of arguments. The last String argument will become
  # the message or description of the report. The last Exception argument
  # will become the associated exception for the report. The last hash
  # argument will be used as the extra data for the report.
  #
  # @example
  #   begin
  #     foo = bar
  #   rescue => e
  #     Rollbar.log(e)
  #   end
  #
  # @example
  #   Rollbar.log('This is a simple log message')
  #
  # @example
  #   Rollbar.log(e, 'This is a description of the exception')
  #
  def log(level, *args)
    return 'disabled' unless configuration.enabled

    message = nil
    exception = nil
    extra = nil

    args.each do |arg|
      if arg.is_a?(String)
        message = arg
      elsif arg.is_a?(Exception)
        exception = arg
      elsif arg.is_a?(Hash)
        extra = arg
      end
    end

    use_exception_level_filters = extra && extra.delete(:use_exception_level_filters) == true

    return 'ignored' if ignored?(exception, use_exception_level_filters)

    exception_level = filtered_level(exception)
    level = exception_level if exception_level && use_exception_level_filters

    begin
      report(level, message, exception, extra)
    rescue Exception => e
      report_internal_error(e)
      'error'
    end
  end

  # See log() above
  def debug(*args)
    log('debug', *args)
  end

  # See log() above
  def info(*args)
    log('info', *args)
  end

  # See log() above
  def warn(*args)
    log('warning', *args)
  end

  # See log() above
  def warning(*args)
    log('warning', *args)
  end

  # See log() above
  def error(*args)
    log('error', *args)
  end

  # See log() above
  def critical(*args)
    log('critical', *args)
  end

  def process_payload(payload)
    if configuration.write_to_file
      if configuration.use_async
        @file_semaphore.synchronize {
          write_payload(payload.value)
        }
      else
        write_payload(payload.value)
      end
    else
      send_payload(payload)
    end
  rescue => e
    log_error("[Rollbar] Error processing the payload: #{e.class}, #{e.message}. Payload: #{payload.inspect}")
    raise e
  end

  def process_payload_safely(payload)
    process_payload(payload)
  rescue => e
    report_internal_error(e)
  end

  private

  def ignored?(exception, use_exception_level_filters = false)
    return false unless exception
    return true if use_exception_level_filters && filtered_level(exception) == 'ignore'
    return true if exception.instance_variable_get(:@_rollbar_do_not_report)

    false
  end

  def filtered_level(exception)
    return unless exception

    filter = configuration.exception_level_filters[exception.class.name]

    if filter.respond_to?(:call)
      filter.call(exception)
    else
      filter
    end
  end

  def report(level, message, exception, extra)
    unless message || exception || extra
      log_error "[Rollbar] Tried to send a report with no message, exception or extra data."
      return 'error'
    end

    payload = build_payload(level, message, exception, extra)
    data = payload.data

    return 'ignored' if payload.ignored?

    schedule_payload(payload)

    log_instance_link(data)

    Rollbar.last_report = data

    data
  end

  # Reports an internal error in the Rollbar library. This will be reported within the configured
  # Rollbar project. We'll first attempt to provide a report including the exception traceback.
  # If that fails, we'll fall back to a more static failsafe response.
  def report_internal_error(exception)
    log_error "[Rollbar] Reporting internal error encountered while sending data to Rollbar."

    begin
      payload = build_payload('error', nil, exception, {:internal => true})
    rescue => e
      send_failsafe("build_payload in exception_data", e)
      return
    end

    begin
      process_payload(payload)
    rescue => e
      send_failsafe("error in process_payload", e)
      return
    end

    begin
      log_instance_link(payload['data'])
    rescue => e
      send_failsafe("error logging instance link", e)
      return
    end
  end

  def build_payload(level, message, exception, extra)
    builder = Rollbar::Builder.new(self)
    builder.build_payload(level, message, exception, extra)
  end

  def report_custom_data_error(e)
    data = safely.error(e)

    return {} unless data[:uuid]

    uuid_url = uuid_rollbar_url(data)

    { :_error_in_custom_data_method => uuid_url }
  end

  def send_payload(payload)
    log_info '[Rollbar] Sending payload'

    return send_payload_using_eventmachine(payload) if configuration.use_eventmachine

    body = payload.dump

    uri = URI.parse(configuration.endpoint)
    http = Net::HTTP.new(uri.host, uri.port)
    http.read_timeout = configuration.request_timeout

    if uri.scheme == 'https'
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    end

    request = Net::HTTP::Post.new(uri.request_uri)
    request.body = body
    request.add_field('X-Rollbar-Access-Token', payload.access_token)
    response = http.request(request)

    if response.code == '200'
      log_info '[Rollbar] Success'
    else
      log_warning "[Rollbar] Got unexpected status code from Rollbar api: #{response.code}"
      log_info "[Rollbar] Response: #{response.body}"
    end
  end

  def send_payload_using_eventmachine(payload)
    body = payload.dump
    headers = { 'X-Rollbar-Access-Token' => payload.access_token }
    req = EventMachine::HttpRequest.new(configuration.endpoint).post(:body => body, :head => headers)

    req.callback do
      if req.response_header.status == 200
        log_info '[Rollbar] Success'
      else
        log_warning "[Rollbar] Got unexpected status code from Rollbar.io api: #{req.response_header.status}"
        log_info "[Rollbar] Response: #{req.response}"
      end
    end

    req.errback do
      log_warning "[Rollbar] Call to API failed, status code: #{req.response_header.status}"
      log_info "[Rollbar] Error's response: #{req.response}"
    end
  end

  def write_payload(payload)
    if configuration.use_async
      @file_semaphore.synchronize {
        do_write_payload(payload)
      }
    else
      do_write_payload(payload)
    end
  end

  def do_write_payload(payload)
    log_info '[Rollbar] Writing payload to file'

    body = dump_payload(payload)

    begin
      @file ||= File.open(configuration.filepath, "a")

      @file.puts(body)
      @file.flush
      # TODO: close @file ?
      log_info "[Rollbar] Success"
    rescue IOError => e
      log_error "[Rollbar] Error opening/writing to file: #{e}"
    end
  end

  def send_failsafe(message, exception)
    log_error "[Rollbar] Sending failsafe response due to #{message}."
    if exception
      begin
        log_error "[Rollbar] #{exception.class.name}: #{exception}"
      rescue => e
      end
    end

    builder = Rollbar::FailsafeBuilder.new(self)
    failsafe_payload = builder.build_payload(message, exception)

    begin
      schedule_payload(failsafe_payload)
    rescue => e
      log_error "[Rollbar] Error sending failsafe : #{e}"
    end
  end

  def schedule_payload(payload)
    return if payload.nil?

    log_info '[Rollbar] Scheduling payload'

    if configuration.use_async
      process_async_payload(payload)
    else
      process_payload(payload)
    end
  end

  def default_async_handler
    return Rollbar::Delay::GirlFriday if defined?(GirlFriday)

    Rollbar::Delay::Thread
  end

  def process_async_payload(payload)
    configuration.async_handler ||= default_async_handler
    configuration.async_handler.call(payload.value)
  rescue => e
    if configuration.failover_handlers.empty?
      log_error '[Rollbar] Async handler failed, and there are no failover handlers configured. See the docs for "failover_handlers"'
      return
    end

    async_failover(payload)
  end

  def async_failover(payload)
    log_warning '[Rollbar] Primary async handler failed. Trying failovers...'

    failover_handlers = configuration.failover_handlers

    failover_handlers.each do |handler|
      begin
        handler.call(payload.value)
      rescue
        next unless handler == failover_handlers.last

        log_error "[Rollbar] All failover handlers failed while processing payload: #{MultiJson.dump(payload.value)}"
      end
    end
  end

  %w(debug info warn error).each do |level|
    define_method(:"log_#{level}") do |message|
      logger.send(level, message)
    end
  end

  alias_method :log_warning, :log_warn

  def log_instance_link(data)
    if data[:uuid]
      uuid_url = uuid_rollbar_url(data)
      log_info "[Rollbar] Details: #{uuid_url} (only available if report was successful)"
    end
  end

  def uuid_rollbar_url(data)
    "#{configuration.web_base}/instance/uuid?uuid=#{data[:uuid]}"
  end

  def logger
    @logger ||= Rollbar::LoggerProxy.new(configuration.logger)
  end
end
