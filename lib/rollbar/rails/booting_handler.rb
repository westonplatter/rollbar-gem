module Rollbar
  module Rails
    class BootingHandler
      def self.call!(&block); new.call!(&block); end

      def call!(&block)
        begin
          block.call
        rescue => e
          Rollbar.error(e)
          raise e
        end
      end
    end
  end
end
