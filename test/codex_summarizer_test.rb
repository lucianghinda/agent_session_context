# frozen_string_literal: true

require "test_helper"
class CodexSummarizerTest < Minitest::Test
  Status = Struct.new(:success?, :exitstatus)

  def test_name_returns_codex
    assert_equal :codex, summarizer.name
  end

  def test_call_passes_prompt_only_via_stdin_and_reads_json_from_last_message_file
    prompt = "Summarize the hidden prompt"
    schema = {
      "type" => "object",
      "properties" => { "summary" => { "type" => "string" } },
      "required" => ["summary"]
    }
    captured = {}

    with_env(
      "OPENAI_API_KEY" => "openai-test-token",
      "CODEX_HOME" => "/tmp/codex-home",
      "ANTHROPIC_API_KEY" => "blocked-anthropic-token",
      "AGENT_CONTEXT_SECRET" => "blocked-secret"
    ) do
      summarizer = build_summarizer do |env:, argv:, stdin_data:|
        captured[:env] = env
        captured[:argv] = argv
        captured[:stdin_data] = stdin_data

        schema_path = value_after(argv, "--output-schema")
        output_path = value_after(argv, "--output-last-message")

        captured[:schema_json] = File.read(schema_path)
        File.write(output_path, JSON.generate("summary" => "Grounded"))

        ["runner stdout is ignored", "", success_status]
      end

      assert_equal JSON.generate("summary" => "Grounded"), summarizer.call(prompt:, schema:)
      assert_equal prompt, captured[:stdin_data]
      assert_equal schema, JSON.parse(captured[:schema_json])
      assert_equal "openai-test-token", captured[:env]["OPENAI_API_KEY"]
      assert_equal "/tmp/codex-home", captured[:env]["CODEX_HOME"]
      refute_includes captured[:env].keys, "ANTHROPIC_API_KEY"
      refute_includes captured[:env].keys, "AGENT_CONTEXT_SECRET"
      assert_equal ENV.fetch("PATH", nil), captured[:env]["PATH"]
      assert_equal "codex", captured[:argv][0]
      assert_equal "exec", captured[:argv][1]
      assert_equal "--ephemeral", captured[:argv][2]
      assert_equal ["--sandbox", "read-only"], captured[:argv][3, 2]
      assert_equal "--ignore-user-config", captured[:argv][5]
      assert_equal "--ignore-rules", captured[:argv][6]
      assert_equal "--skip-git-repo-check", captured[:argv][7]
      assert_equal "--output-schema", captured[:argv][8]
      refute_empty captured[:argv][9]
      assert_equal "--output-last-message", captured[:argv][10]
      refute_empty captured[:argv][11]
      assert_equal "-", captured[:argv].last
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
      summarizer = Agent::SessionContext::Summarizers::Codex.new

      assert_equal :codex, summarizer.name
    end

    assert_equal(
      {
        timeout_seconds: Agent::SessionContext::Config::DEFAULT_TIMEOUT_SECONDS,
        max_output_bytes: Agent::SessionContext::Summarizers::Codex::MAX_OUTPUT_BYTES
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
      Agent::SessionContext::Summarizers::Codex.new(timeout_seconds: 42)
    end

    assert_equal(
      {
        timeout_seconds: 42,
        max_output_bytes: Agent::SessionContext::Summarizers::Codex::MAX_OUTPUT_BYTES
      },
      captured
    )
  end

  def test_initialize_with_injected_runner_does_not_construct_default_subprocess_runner
    injected_runner = lambda do |env:, argv:, stdin_data:|
      File.write(value_after(argv, "--output-last-message"), JSON.generate("ok" => true))
      ["", "", success_status]
    end

    Agent::SessionContext::SubprocessRunner.stub(:new, lambda { |**_kwargs|
      flunk("should not construct default runner")
    }) do
      summarizer = Agent::SessionContext::Summarizers::Codex.new(runner: injected_runner)

      assert_equal JSON.generate("ok" => true), summarizer.call(prompt: "hidden", schema: { "type" => "object" })
    end
  end

  def test_call_raises_summarizer_unavailable_when_runner_cannot_find_codex
    summarizer = build_summarizer do |env:, argv:, stdin_data:|
      raise Errno::ENOENT, argv.first
    end

    error = assert_raises(Agent::SessionContext::SummarizerUnavailable) do
      summarizer.call(prompt: "secret prompt", schema: { "type" => "object" })
    end

    assert_match(/codex/i, error.message)
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

    assert_match(/codex/i, error.message)
    assert_match(/stdout=.*bytes/i, error.message)
    assert_match(/stderr=.*bytes/i, error.message)
    assert_match(/exit_status=17/i, error.message)
    refute_message_leaks(error.message, prompt, "TOP_SECRET_TOKEN", "prefix", "suffix")
  end

  def test_call_translates_timeout_error_using_adapter_timeout_not_exception_metadata
    prompt = "prefix TIMEOUT_SECRET suffix"
    summarizer = Agent::SessionContext::Summarizers::Codex.new(
      runner: lambda { |env:, argv:, stdin_data:|
        raise Agent::SessionContext::SubprocessRunner::TimeoutError, 42
      },
      timeout_seconds: 7
    )

    error = assert_raises(Agent::SessionContext::SummarizerFailed) do
      summarizer.call(prompt:, schema: { "type" => "object" })
    end

    assert_equal "codex summarizer exceeded its 7-second timeout", error.message
    refute_message_leaks(error.message, prompt, "TIMEOUT_SECRET", "42", "prefix", "suffix")
  end

  def test_call_translates_timeout_error_without_leaking_untrusted_timeout_metadata
    prompt = "prefix TIMEOUT_SECRET suffix"
    summarizer = Agent::SessionContext::Summarizers::Codex.new(
      runner: lambda { |env:, argv:, stdin_data:|
        raise Agent::SessionContext::SubprocessRunner::TimeoutError, "TOP_SECRET_TIMEOUT"
      },
      timeout_seconds: 7
    )

    error = assert_raises(Agent::SessionContext::SummarizerFailed) do
      summarizer.call(prompt:, schema: { "type" => "object" })
    end

    assert_equal "codex summarizer exceeded its 7-second timeout", error.message
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

    assert_equal "codex summarizer stdout exceeded 1048576 bytes", error.message
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

    assert_equal "codex summarizer stderr exceeded 1048576 bytes", error.message
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

    assert_equal "codex summarizer output exceeded 1048576 bytes", error.message
    refute_message_leaks(error.message, prompt, "OUTPUT_SECRET", "TOP_SECRET_STREAM", "999", "prefix", "suffix")
  end

  def test_call_raises_summarizer_failed_when_last_message_file_is_missing
    summarizer = build_summarizer do |env:, argv:, stdin_data:|
      File.unlink(value_after(argv, "--output-last-message"))
      ["", "", success_status]
    end

    error = assert_raises(Agent::SessionContext::SummarizerFailed) do
      summarizer.call(prompt: "hidden", schema: { "type" => "object" })
    end

    assert_match(/missing/i, error.message)
    assert_match(/last message/i, error.message)
  end

  def test_call_raises_summarizer_failed_when_last_message_file_is_empty
    summarizer = build_summarizer do |env:, argv:, stdin_data:|
      File.write(value_after(argv, "--output-last-message"), "")
      ["", "", success_status]
    end

    error = assert_raises(Agent::SessionContext::SummarizerFailed) do
      summarizer.call(prompt: "hidden", schema: { "type" => "object" })
    end

    assert_match(/empty/i, error.message)
    assert_match(/last message/i, error.message)
  end

  def test_call_raises_summarizer_failed_when_last_message_is_not_json
    prompt = "prefix LAST_MESSAGE_SECRET suffix"

    summarizer = build_summarizer do |env:, argv:, stdin_data:|
      File.binwrite(value_after(argv, "--output-last-message"), "{broken #{stdin_data} LAST_MESSAGE_SECRET \xFF".b)
      ["", "", success_status]
    end

    error = assert_raises(Agent::SessionContext::SummarizerFailed) do
      summarizer.call(prompt:, schema: { "type" => "object" })
    end

    assert_match(/invalid json/i, error.message)
    assert_match(/last message/i, error.message)
    assert_match(/output=.*bytes/i, error.message)
    refute_message_leaks(error.message, prompt, "LAST_MESSAGE_SECRET", "prefix", "suffix")
  end

  def test_call_rejects_oversized_stdout_and_stderr_without_echoing_content
    {
      "stdout" => ["x" * (max_output_bytes + 1), ""],
      "stderr" => ["", "y" * (max_output_bytes + 1)]
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

  def test_call_rejects_oversized_last_message_file_before_json_parse
    summarizer = build_summarizer do |env:, argv:, stdin_data:|
      File.binwrite(value_after(argv, "--output-last-message"), "z" * (max_output_bytes + 1))
      ["", "", success_status]
    end

    error = assert_raises(Agent::SessionContext::SummarizerFailed) do
      summarizer.call(prompt: "hidden", schema: { "type" => "object" })
    end

    assert_match(/last message/i, error.message)
    assert_match(/exceeded/i, error.message)
    assert_match(/#{max_output_bytes}/, error.message)
  end

  private

  def summarizer
    @summarizer ||= Agent::SessionContext::Summarizers::Codex.new(runner: lambda { |env:, argv:, stdin_data:|
      ["", "", success_status]
    })
  end

  def build_summarizer(&runner)
    Agent::SessionContext::Summarizers::Codex.new(runner:)
  end

  def value_after(argv, flag)
    flag_index = argv.index(flag)
    refute_nil flag_index, "Expected #{flag.inspect} in argv"
    argv.fetch(flag_index + 1)
  end

  def success_status
    Status.new(true, 0)
  end

  def failure_status
    Status.new(false, 17)
  end

  def max_output_bytes
    Agent::SessionContext::Summarizers::Codex::MAX_OUTPUT_BYTES
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
