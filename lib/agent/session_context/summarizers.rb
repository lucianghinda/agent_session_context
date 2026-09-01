# frozen_string_literal: true

module Agent
  module SessionContext
    module Summarizers
      module_function

      def for(name, timeout_seconds: Config::DEFAULT_TIMEOUT_SECONDS)
        case normalize_name(name)
        when :codex then Codex.new(timeout_seconds:)
        when :claude then Claude.new(timeout_seconds:)
        else
          raise unsupported_summarizer(name)
        end
      end

      def normalize_name(name)
        return name if name.is_a?(Symbol)
        raise unsupported_summarizer(name) unless name.respond_to?(:to_sym)

        normalized = name.to_sym
        raise unsupported_summarizer(name) unless normalized.is_a?(Symbol)

        normalized
      rescue NoMethodError, TypeError, ArgumentError
        raise unsupported_summarizer(name)
      end

      def unsupported_summarizer(name)
        UnsupportedAgent.new("unsupported summarizer #{name.inspect}; use claude or codex")
      end
      private_class_method :normalize_name, :unsupported_summarizer
    end
  end
end
