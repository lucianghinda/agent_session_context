# frozen_string_literal: true

require "test_helper"

class SummarizerCommandExecutionPolicyTest < Minitest::Test
  Status = Struct.new(:success?, :exitstatus)

  class ClaudeSubclass < Agent::SessionContext::Summarizers::Claude
  end

  class CodexSubclass < Agent::SessionContext::Summarizers::Codex
  end

  def test_built_in_summarizers_share_command_execution_policy
    shared_policy = Agent::SessionContext::Summarizers.const_get(:CommandExecutionPolicy, false)

    [Agent::SessionContext::Summarizers::Claude, Agent::SessionContext::Summarizers::Codex].each do |summarizer|
      assert_includes summarizer.ancestors, shared_policy
    end
  rescue NameError
    flunk "expected built-in summarizers to share Agent::SessionContext::Summarizers::CommandExecutionPolicy"
  end

  def test_claude_subclass_inherits_provider_env_filtering_without_redeclaring_constants
    captured_env = nil

    summarizer = ClaudeSubclass.new(runner: lambda { |env:, argv:, stdin_data:|
      captured_env = env
      [JSON.generate("structured_output" => { "summary" => "ok" }), "", success_status]
    })

    with_env(
      "ANTHROPIC_API_KEY" => "anthropic-test-token",
      "CLAUDE_CODE_OAUTH_TOKEN" => "oauth-test-token",
      "AGENT_CONTEXT_SECRET" => "blocked-secret"
    ) do
      assert_equal JSON.generate("summary" => "ok"), summarizer.call(prompt: "hidden", schema: { "type" => "object" })
    end

    assert_equal "anthropic-test-token", captured_env["ANTHROPIC_API_KEY"]
    assert_equal "oauth-test-token", captured_env["CLAUDE_CODE_OAUTH_TOKEN"]
    refute_includes captured_env.keys, "AGENT_CONTEXT_SECRET"
  end

  def test_codex_subclass_inherits_provider_env_filtering_without_redeclaring_constants
    captured_env = nil

    summarizer = CodexSubclass.new(runner: lambda { |env:, argv:, stdin_data:|
      captured_env = env
      File.write(value_after(argv, "--output-last-message"), JSON.generate("summary" => "ok"))
      ["", "", success_status]
    })

    with_env(
      "OPENAI_API_KEY" => "openai-test-token",
      "CODEX_HOME" => "/tmp/codex-home",
      "AGENT_CONTEXT_SECRET" => "blocked-secret"
    ) do
      assert_equal JSON.generate("summary" => "ok"), summarizer.call(prompt: "hidden", schema: { "type" => "object" })
    end

    assert_equal "openai-test-token", captured_env["OPENAI_API_KEY"]
    assert_equal "/tmp/codex-home", captured_env["CODEX_HOME"]
    refute_includes captured_env.keys, "AGENT_CONTEXT_SECRET"
  end

  private

  def success_status
    Status.new(true, 0)
  end

  def value_after(argv, flag)
    flag_index = argv.index(flag)
    refute_nil flag_index, "Expected #{flag.inspect} in argv"
    argv.fetch(flag_index + 1)
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
