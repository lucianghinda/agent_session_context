# frozen_string_literal: true

require "test_helper"
class ClaudeSummarizerTest < Minitest::Test
  Status = Struct.new(:success?, :exitstatus)

  def test_name_returns_claude
    assert_equal :claude, summarizer.name
  end

  def test_call_passes_prompt_only_via_stdin_and_returns_structured_output_hash_as_json
    prompt = "Never pass me as an argv"
    schema = { "type" => "object", "properties" => { "decision" => { "type" => "string" } } }
    captured = {}

    with_env(
      "ANTHROPIC_API_KEY" => "anthropic-test-token",
      "CLAUDE_CODE_OAUTH_TOKEN" => "oauth-test-token",
      "OPENAI_API_KEY" => "blocked-openai-token",
      "AGENT_CONTEXT_SECRET" => "blocked-secret"
    ) do
      summarizer = build_summarizer do |env:, argv:, stdin_data:|
        captured[:env] = env
        captured[:argv] = argv
        captured[:stdin_data] = stdin_data

        envelope = {
          "structured_output" => { "decision" => "Ship it" },
          "result" => "ignored fallback"
        }

        [JSON.generate(envelope), "", success_status]
      end

      assert_equal JSON.generate("decision" => "Ship it"), summarizer.call(prompt:, schema:)
      assert_equal "anthropic-test-token", captured[:env]["ANTHROPIC_API_KEY"]
      assert_equal "oauth-test-token", captured[:env]["CLAUDE_CODE_OAUTH_TOKEN"]
      refute_includes captured[:env].keys, "OPENAI_API_KEY"
      refute_includes captured[:env].keys, "AGENT_CONTEXT_SECRET"
      assert_equal ENV.fetch("PATH", nil), captured[:env]["PATH"]
      assert_equal prompt, captured[:stdin_data]
      assert_equal exact_argv(schema), captured[:argv]
      refute_includes captured[:argv].join(" "), prompt
    end
  end

  def test_initialize_builds_default_subprocess_runner_with_config_timeout_and_max_output_bytes
    runner = ->(env:, argv:, stdin_data:) { ["", "", success_status] }
    captured = nil

    Agent::SessionContext::SubprocessRunner.stub(:new, lambda { |**kwargs|
      captured = kwargs
      runner
    }) do
      summarizer = Agent::SessionContext::Summarizers::Claude.new

      assert_equal :claude, summarizer.name
    end

    assert_equal(
      {
        timeout_seconds: Agent::SessionContext::Config::DEFAULT_TIMEOUT_SECONDS,
        max_output_bytes: Agent::SessionContext::Summarizers::Claude::MAX_OUTPUT_BYTES
      },
      captured
    )
  end

  def test_initialize_builds_default_subprocess_runner_with_explicit_timeout
    runner = ->(env:, argv:, stdin_data:) { ["", "", success_status] }
    captured = nil

    Agent::SessionContext::SubprocessRunner.stub(:new, lambda { |**kwargs|
      captured = kwargs
      runner
    }) do
      Agent::SessionContext::Summarizers::Claude.new(timeout_seconds: 42)
    end

    assert_equal(
      {
        timeout_seconds: 42,
        max_output_bytes: Agent::SessionContext::Summarizers::Claude::MAX_OUTPUT_BYTES
      },
      captured
    )
  end

  def test_initialize_with_injected_runner_does_not_construct_default_subprocess_runner
    injected_runner = ->(env:, argv:, stdin_data:) { [JSON.generate("result" => "{\"ok\":true}"), "", success_status] }

    Agent::SessionContext::SubprocessRunner.stub(:new, lambda { |**_kwargs|
      flunk("should not construct default runner")
    }) do
      summarizer = Agent::SessionContext::Summarizers::Claude.new(runner: injected_runner)

      assert_equal JSON.generate("ok" => true), summarizer.call(prompt: "hidden", schema: { "type" => "object" })
    end
  end

  def test_call_uses_result_fallback_when_structured_output_is_missing
    summarizer = build_summarizer do |env:, argv:, stdin_data:|
      [JSON.generate("result" => "{\"goal\":\"Ground it\"}"), "", success_status]
    end

    assert_equal JSON.generate("goal" => "Ground it"), summarizer.call(prompt: "hidden", schema: { "type" => "object" })
  end

  def test_call_raises_summarizer_unavailable_when_runner_cannot_find_claude
    summarizer = build_summarizer do |env:, argv:, stdin_data:|
      raise Errno::ENOENT, argv.first
    end

    error = assert_raises(Agent::SessionContext::SummarizerUnavailable) do
      summarizer.call(prompt: "secret prompt", schema: { "type" => "object" })
    end

    assert_match(/claude/i, error.message)
    refute_includes error.message, "secret prompt"
  end

  def test_call_raises_summarizer_failed_for_non_success_status_without_echoing_prompt
    prompt = "prefix TOP_SECRET_TOKEN suffix"

    summarizer = build_summarizer do |env:, argv:, stdin_data:|
      ["stdout #{stdin_data} TOP_SECRET_TOKEN \xFF".b, "stderr prefix suffix #{stdin_data}".b, failure_status]
    end

    error = assert_raises(Agent::SessionContext::SummarizerFailed) do
      summarizer.call(prompt:, schema: { "type" => "object" })
    end

    assert_match(/claude/i, error.message)
    assert_match(/stdout=.*bytes/i, error.message)
    assert_match(/stderr=.*bytes/i, error.message)
    assert_match(/exit_status=17/i, error.message)
    refute_message_leaks(error.message, prompt, "TOP_SECRET_TOKEN", "prefix", "suffix")
  end

  def test_call_translates_timeout_error_using_adapter_timeout_not_exception_metadata
    prompt = "prefix TIMEOUT_SECRET suffix"
    summarizer = Agent::SessionContext::Summarizers::Claude.new(
      runner: lambda { |env:, argv:, stdin_data:|
        raise Agent::SessionContext::SubprocessRunner::TimeoutError, 42
      },
      timeout_seconds: 7
    )

    error = assert_raises(Agent::SessionContext::SummarizerFailed) do
      summarizer.call(prompt:, schema: { "type" => "object" })
    end

    assert_equal "claude summarizer exceeded its 7-second timeout", error.message
    refute_message_leaks(error.message, prompt, "TIMEOUT_SECRET", "42", "prefix", "suffix")
  end

  def test_call_translates_timeout_error_without_leaking_untrusted_timeout_metadata
    prompt = "prefix TIMEOUT_SECRET suffix"
    summarizer = Agent::SessionContext::Summarizers::Claude.new(
      runner: lambda { |env:, argv:, stdin_data:|
        raise Agent::SessionContext::SubprocessRunner::TimeoutError, "TOP_SECRET_TIMEOUT"
      },
      timeout_seconds: 7
    )

    error = assert_raises(Agent::SessionContext::SummarizerFailed) do
      summarizer.call(prompt:, schema: { "type" => "object" })
    end

    assert_equal "claude summarizer exceeded its 7-second timeout", error.message
    refute_message_leaks(error.message, prompt, "TIMEOUT_SECRET", "TOP_SECRET_TIMEOUT", "prefix", "suffix")
  end

  def test_call_translates_stdout_output_limit_error_using_allowlisted_stream_and_adapter_bound
    prompt = "prefix OUTPUT_SECRET suffix"

    summarizer = build_summarizer do |env:, argv:, stdin_data:|
      raise Agent::SessionContext::SubprocessRunner::OutputLimitError.new(stream: :stdout, max_output_bytes: 123)
    end

    error = assert_raises(Agent::SessionContext::SummarizerFailed) do
      summarizer.call(prompt:, schema: { "type" => "object" })
    end

    assert_equal "claude summarizer stdout exceeded 1048576 bytes", error.message
    refute_message_leaks(error.message, prompt, "OUTPUT_SECRET", "123", "prefix", "suffix")
  end

  def test_call_translates_stderr_output_limit_error_using_allowlisted_stream_and_adapter_bound
    prompt = "prefix OUTPUT_SECRET suffix"

    summarizer = build_summarizer do |env:, argv:, stdin_data:|
      raise Agent::SessionContext::SubprocessRunner::OutputLimitError.new(stream: :stderr, max_output_bytes: 456)
    end

    error = assert_raises(Agent::SessionContext::SummarizerFailed) do
      summarizer.call(prompt:, schema: { "type" => "object" })
    end

    assert_equal "claude summarizer stderr exceeded 1048576 bytes", error.message
    refute_message_leaks(error.message, prompt, "OUTPUT_SECRET", "456", "prefix", "suffix")
  end

  def test_call_translates_untrusted_output_limit_metadata_to_safe_output_label_and_adapter_bound
    prompt = "prefix OUTPUT_SECRET suffix"

    summarizer = build_summarizer do |env:, argv:, stdin_data:|
      raise Agent::SessionContext::SubprocessRunner::OutputLimitError.new(
        stream: "TOP_SECRET_STREAM",
        max_output_bytes: 999
      )
    end

    error = assert_raises(Agent::SessionContext::SummarizerFailed) do
      summarizer.call(prompt:, schema: { "type" => "object" })
    end

    assert_equal "claude summarizer output exceeded 1048576 bytes", error.message
    refute_message_leaks(error.message, prompt, "OUTPUT_SECRET", "TOP_SECRET_STREAM", "999", "prefix", "suffix")
  end

  def test_call_raises_summarizer_failed_for_empty_stdout
    summarizer = build_summarizer do |env:, argv:, stdin_data:|
      ["", "", success_status]
    end

    error = assert_raises(Agent::SessionContext::SummarizerFailed) do
      summarizer.call(prompt: "hidden", schema: { "type" => "object" })
    end

    assert_match(/empty/i, error.message)
    assert_match(/stdout/i, error.message)
  end

  def test_call_raises_summarizer_failed_for_malformed_json_envelope
    prompt = "prefix ENVELOPE_SECRET suffix"

    summarizer = build_summarizer do |env:, argv:, stdin_data:|
      ["{broken #{stdin_data} ENVELOPE_SECRET \xFF".b, "", success_status]
    end

    error = assert_raises(Agent::SessionContext::SummarizerFailed) do
      summarizer.call(prompt:, schema: { "type" => "object" })
    end

    assert_match(/invalid json/i, error.message)
    assert_match(/envelope/i, error.message)
    assert_match(/stdout=.*bytes/i, error.message)
    refute_message_leaks(error.message, prompt, "ENVELOPE_SECRET", "prefix", "suffix")
  end

  def test_call_raises_summarizer_failed_for_missing_structured_fields
    summarizer = build_summarizer do |env:, argv:, stdin_data:|
      [JSON.generate("message" => "no structured content"), "", success_status]
    end

    error = assert_raises(Agent::SessionContext::SummarizerFailed) do
      summarizer.call(prompt: "hidden", schema: { "type" => "object" })
    end

    assert_match(/structured_output/i, error.message)
    assert_match(/result/i, error.message)
  end

  def test_call_raises_summarizer_failed_for_malformed_structured_output_string
    prompt = "prefix STRUCTURED_SECRET suffix"

    summarizer = build_summarizer do |env:, argv:, stdin_data:|
      [JSON.generate("structured_output" => "not json #{stdin_data} STRUCTURED_SECRET \u0000"), "", success_status]
    end

    error = assert_raises(Agent::SessionContext::SummarizerFailed) do
      summarizer.call(prompt:, schema: { "type" => "object" })
    end

    assert_match(/structured_output/i, error.message)
    assert_match(/invalid json/i, error.message)
    refute_message_leaks(error.message, prompt, "STRUCTURED_SECRET", "prefix", "suffix")
  end

  def test_call_raises_summarizer_failed_for_malformed_result_fallback_string
    prompt = "prefix RESULT_SECRET suffix"

    summarizer = build_summarizer do |env:, argv:, stdin_data:|
      [JSON.generate("result" => "not json #{stdin_data} RESULT_SECRET \u0000"), "", success_status]
    end

    error = assert_raises(Agent::SessionContext::SummarizerFailed) do
      summarizer.call(prompt:, schema: { "type" => "object" })
    end

    assert_match(/result/i, error.message)
    assert_match(/invalid json/i, error.message)
    refute_includes error.message, "structured_output"
    refute_message_leaks(error.message, prompt, "RESULT_SECRET", "prefix", "suffix")
  end

  def test_call_rejects_oversized_stdout_and_stderr_without_echoing_content
    {
      "stdout" => ["x" * (max_output_bytes + 1), ""],
      "stderr" => [JSON.generate("structured_output" => { "ok" => true }), "y" * (max_output_bytes + 1)]
    }.each do |label, (stdout, stderr)|
      summarizer = build_summarizer do |env:, argv:, stdin_data:|
        [stdout, stderr, success_status]
      end

      error = assert_raises(Agent::SessionContext::SummarizerFailed) do
        summarizer.call(prompt: "hidden", schema: { "type" => "object" })
      end

      assert_match(/#{label}/i, error.message)
      assert_match(/exceeded/i, error.message)
      assert_match(/#{max_output_bytes}/, error.message)
    end
  end

  private

  def summarizer
    @summarizer ||= Agent::SessionContext::Summarizers::Claude.new(runner: lambda { |env:, argv:, stdin_data:|
      ["", "", success_status]
    })
  end

  def build_summarizer(&runner)
    Agent::SessionContext::Summarizers::Claude.new(runner:)
  end

  def exact_argv(schema)
    [
      "claude",
      "--print",
      "--safe-mode",
      "--tools",
      "",
      "--no-session-persistence",
      "--output-format",
      "json",
      "--json-schema",
      JSON.generate(schema)
    ]
  end

  def success_status
    Status.new(true, 0)
  end

  def failure_status
    Status.new(false, 17)
  end

  def max_output_bytes
    Agent::SessionContext::Summarizers::Claude::MAX_OUTPUT_BYTES
  end

  def refute_message_leaks(message, *fragments)
    fragments.each do |fragment|
      refute_includes message, fragment
    end
  end

  def with_env(overrides)
    previous = {}

    overrides.each do |key, value|
      previous[key] = ENV.key?(key) ? ENV[key] : :__missing__

      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end

    yield
  ensure
    previous.each do |key, value|
      if value == :__missing__
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
  end
end
