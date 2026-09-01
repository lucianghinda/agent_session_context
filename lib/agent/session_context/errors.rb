# frozen_string_literal: true

module Agent
  module SessionContext
    class Error < StandardError; end
    class ConfigurationError < Error; end
    class SessionNotFound < Error; end
    class AmbiguousSession < Error; end
    class CurrentSessionUnavailable < Error; end
    class UnsupportedAgent < Error; end
    class SummarizerUnavailable < Error; end
    class SummarizerFailed < Error; end
    class InvalidSummary < Error; end
  end
end
