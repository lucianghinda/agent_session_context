# frozen_string_literal: true

require "test_helper"

class LoadTest < Minitest::Test
  def test_public_namespace_and_version_load
    assert defined?(Agent::SessionContext)
    assert_match(/\A\d+\.\d+\.\d+\z/, Agent::SessionContext::VERSION)
  end

  def test_error_constants_load
    assert_equal StandardError, Agent::SessionContext::Error.superclass
    assert_equal Agent::SessionContext::Error, Agent::SessionContext::ConfigurationError.superclass
    assert_equal Agent::SessionContext::Error, Agent::SessionContext::SessionNotFound.superclass
    assert_equal Agent::SessionContext::Error, Agent::SessionContext::AmbiguousSession.superclass
    assert_equal Agent::SessionContext::Error, Agent::SessionContext::CurrentSessionUnavailable.superclass
    assert_equal Agent::SessionContext::Error, Agent::SessionContext::UnsupportedAgent.superclass
    assert_equal Agent::SessionContext::Error, Agent::SessionContext::SummarizerUnavailable.superclass
    assert_equal Agent::SessionContext::Error, Agent::SessionContext::SummarizerFailed.superclass
    assert_equal Agent::SessionContext::Error, Agent::SessionContext::InvalidSummary.superclass
    assert_equal StandardError, Agent::SessionContext::SubprocessRunner::TimeoutError.superclass
    assert_equal StandardError, Agent::SessionContext::SubprocessRunner::OutputLimitError.superclass
  end

  def test_zeitwerk_eager_load_is_clean
    Zeitwerk::Loader.eager_load_all

    assert defined?(Agent::SessionContext::Error)
    assert defined?(Agent::SessionContext::ConfigurationError)
    assert defined?(Agent::SessionContext::Config)
    assert defined?(Agent::SessionContext::SubprocessRunner)
    assert defined?(Agent::SessionContext::SubprocessRunner::TimeoutError)
    assert defined?(Agent::SessionContext::SubprocessRunner::OutputLimitError)
  end
end
