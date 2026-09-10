# frozen_string_literal: true

require "test_helper"
require_relative "support/fake_summarizer"
require_relative "support/claude_fixtures"
require_relative "support/codex_fixtures"

class CLITest < Minitest::Test
  include ClaudeFixtures
  include CodexFixtures

  Session = Data.define(:id, :uid, :agent, :project_path)
  FakeConfig = Data.define(:timeout_seconds)
  PromptsResult = Data.define(:prompts, :reader_warnings, :partial_capture?) do
    def initialize(prompts:, reader_warnings:)
      super(prompts:, reader_warnings:, partial_capture?: !Array(reader_warnings).empty?)
    end
  end

  class FakeResolver
    attr_reader :resolve_calls, :current_calls

    def initialize(resolve_result: nil, current_result: nil, resolve_error: nil, current_error: nil,
                   current_fallback: false)
      @resolve_result = resolve_result
      @current_result = current_result
      @resolve_error = resolve_error
      @current_error = current_error
      @current_fallback = current_fallback
      @resolve_calls = []
      @current_calls = []
    end

    def resolve(identifier, agent: nil)
      @resolve_calls << { identifier:, agent: }
      raise @resolve_error if @resolve_error

      @resolve_result
    end

    def current(agent: nil)
      @current_calls << { agent: }
      raise @current_error if @current_error

      yield @current_result if @current_fallback && block_given?
      @current_result
    end
  end

  class FakeBuilder
    attr_reader :show_calls, :prompts_calls, :prompts_result_calls, :loop_calls, :summarize_calls

    def initialize(show_result: nil, prompts_result: nil, loop_result: nil, summarize_result: nil)
      @show_result = show_result
      @prompts_result = prompts_result
      @loop_result = loop_result
      @summarize_result = summarize_result
      @show_calls = []
      @prompts_calls = []
      @prompts_result_calls = []
      @loop_calls = []
      @summarize_calls = []
    end

    def show(session, include_injected: false)
      @show_calls << { session:, include_injected: }
      @show_result
    end

    def prompts(session)
      @prompts_calls << session
      prompts_result(session).prompts
    end

    def prompts_result(session)
      @prompts_result_calls << session
      @prompts_result
    end

    def loop(session)
      @loop_calls << session
      @loop_result
    end

    def summarize(session, summarizer:)
      @summarize_calls << { session:, summarizer: }
      @summarize_result
    end
  end

  class FakeConfigLoader
    attr_reader :calls

    def initialize(result: FakeConfig.new(timeout_seconds: Agent::SessionContext::Config::DEFAULT_TIMEOUT_SECONDS),
                   error: nil)
      @result = result
      @error = error
      @calls = []
    end

    def load(session:, env:, timeout:)
      @calls << { session:, env:, timeout: }
      raise @error if @error

      @result
    end
  end

  class FakeBackendFactory
    attr_reader :calls

    def initialize(backends = {})
      @backends = backends.transform_keys(&:to_sym)
      @calls = []
    end

    def for(name, timeout_seconds:)
      key = name.to_sym
      @calls << { name: key, timeout_seconds: }
      @backends.fetch(key)
    end
  end

  def test_help_lists_commands_and_exits_zero
    status, out, err = run_cli

    assert_equal 0, status
    assert_equal "", err
    assert_includes out, "Usage: agent-session-context"
    assert_includes out, "show"
    assert_includes out, "prompts"
    assert_includes out, "summarize"
    assert out.end_with?("\n")
    refute out.end_with?("\n\n")
  end

  def test_help_mentions_timeout_range_and_provider_call_scope
    with_cli_env_variants do
      status, out, err = run_cli("help")

      assert_equal 0, status
      assert_equal "", err
      assert_includes out, "--timeout SECONDS"
      assert_includes out, "1-3600"
      assert_includes out, "each provider call"
    end
  end

  def test_help_describes_show_privacy_boundary_after_common_options
    status, out, err = run_cli("help")

    assert_equal 0, status
    assert_equal "", err
    assert_includes out, <<~HELP
      Common options:
        --current             Use environment identity, else latest on disk
        --agent claude|codex  Narrow explicit lookup or --current disk fallback
        --format text|markdown|json|jsonl

      Show behavior:
        Includes exact user prompts and an injected-context inventory.
        --include-injected  Include deduplicated full injected text
        Excludes assistant messages, thinking, tool-result bodies,
        and raw provider envelopes.
    HELP
  end

  def test_version_writes_the_gem_version
    status, out, err = run_cli("version")

    assert_equal 0, status
    assert_equal "", err
    assert_equal "#{Agent::SessionContext::VERSION}\n", out
  end

  def test_version_rejects_extra_arguments
    status, out, err = run_cli("version", "extra")

    assert_equal 1, status
    assert_equal "", out
    assert_equal "unexpected arguments: extra\n", err
  end

  def test_help_rejects_extra_arguments
    status, out, err = run_cli("help", "extra")

    assert_equal 1, status
    assert_equal "", out
    assert_equal "unexpected arguments: extra\n", err
  end

  def test_unknown_command_prints_one_sanitized_actionable_line
    status, out, err = run_cli(unsafe_command)

    assert_equal 1, status
    assert_equal "", out
    assert_equal "unknown command: #{safe_inline(unsafe_command)}\n", err
    refute_includes err, "\e"
  end

  def test_unknown_flag_reports_cleanly
    session = build_session(agent: :codex, id: "session-1")

    status, out, err = run_cli(
      "show", session.id, "--bogus",
      resolver: FakeResolver.new(resolve_result: session),
      builder: FakeBuilder.new(show_result: build_snapshot(session))
    )

    assert_equal 1, status
    assert_equal "", out
    assert_includes err, "invalid option: --bogus"
  end

  def test_unknown_flag_before_later_json_routes_parse_error_to_json_stdout
    status, out, err = run_cli("show", "--bogus", "--format", "json")

    assert_equal 1, status
    assert_equal "", err
    assert_equal(
      {
        "error" => {
          "type" => "OptionParser::InvalidOption",
          "message" => "invalid option: --bogus"
        }
      },
      JSON.parse(out)
    )
  end

  def test_last_pre_parse_json_format_wins_for_error_routing
    status, out, err = run_cli("show", "--format", "json", "--format", "markdown")

    assert_equal 1, status
    assert_equal "", out
    assert_equal "pass SESSION or --current\n", err

    status2, out2, err2 = run_cli("show", "--format", "markdown", "--format", "json")

    assert_equal 1, status2
    assert_equal "", err2
    assert_equal(
      {
        "error" => {
          "type" => "OptionParser::ParseError",
          "message" => "pass SESSION or --current"
        }
      },
      JSON.parse(out2)
    )
  end

  def test_equals_form_of_json_format_routes_parse_errors_to_json_stdout
    status, out, err = run_cli("show", "--format=json")

    assert_equal 1, status
    assert_equal "", err
    assert_equal(
      {
        "error" => {
          "type" => "OptionParser::ParseError",
          "message" => "pass SESSION or --current"
        }
      },
      JSON.parse(out)
    )
  end

  def test_missing_format_value_does_not_force_json_error_routing
    status, out, err = run_cli("show", "--format")

    assert_equal 1, status
    assert_equal "", out
    assert_equal "missing argument: --format\n", err
  end

  def test_abbreviated_split_format_flag_is_rejected_consistently_and_json_routing_stays_order_independent
    with_cli_env_variants do
      [
        {
          argv: ["show", "--format", "json", "--forma", "json"],
          expected_type: "OptionParser::InvalidOption",
          expected_message: "invalid option: --forma"
        },
        {
          argv: ["show", "--forma", "json", "--format", "json"],
          expected_type: "OptionParser::InvalidOption",
          expected_message: "invalid option: --forma"
        },
        {
          argv: ["show", "--bogus", "--forma", "json", "--format", "json"],
          expected_type: "OptionParser::InvalidOption",
          expected_message: "invalid option: --bogus"
        },
        {
          argv: ["show", "--forma", "json", "--bogus", "--format", "json"],
          expected_type: "OptionParser::InvalidOption",
          expected_message: "invalid option: --forma"
        }
      ].each do |scenario|
        status, out, err = run_cli_array(scenario.fetch(:argv))

        assert_equal 1, status
        assert_equal "", err
        assert_equal(
          {
            "error" => {
              "type" => scenario.fetch(:expected_type),
              "message" => scenario.fetch(:expected_message)
            }
          },
          JSON.parse(out)
        )
      end
    end
  end

  def test_abbreviated_equals_format_flag_is_rejected_consistently_and_json_routing_stays_order_independent
    with_cli_env_variants do
      [
        {
          argv: ["show", "--format=json", "--forma=json"],
          expected_type: "OptionParser::InvalidOption",
          expected_message: "invalid option: --forma=json"
        },
        {
          argv: ["show", "--forma=json", "--format=json"],
          expected_type: "OptionParser::InvalidOption",
          expected_message: "invalid option: --forma=json"
        },
        {
          argv: ["show", "--bogus", "--forma=json", "--format=json"],
          expected_type: "OptionParser::InvalidOption",
          expected_message: "invalid option: --bogus"
        },
        {
          argv: ["show", "--forma=json", "--bogus", "--format=json"],
          expected_type: "OptionParser::InvalidOption",
          expected_message: "invalid option: --forma=json"
        }
      ].each do |scenario|
        status, out, err = run_cli_array(scenario.fetch(:argv))

        assert_equal 1, status
        assert_equal "", err
        assert_equal(
          {
            "error" => {
              "type" => scenario.fetch(:expected_type),
              "message" => scenario.fetch(:expected_message)
            }
          },
          JSON.parse(out)
        )
      end
    end
  end

  def test_show_resolves_explicit_session_with_optional_agent
    session = build_session(agent: :codex, id: "session-1")
    resolver = FakeResolver.new(resolve_result: session)
    builder = FakeBuilder.new(show_result: build_snapshot(session))

    status, out, err = run_cli("show", session.id, "--agent", "codex", resolver:, builder:)

    assert_equal 0, status
    assert_equal "warning: exact prompts may contain secrets; review before sharing\n", err
    assert_equal [{ identifier: "session-1", agent: :codex }], resolver.resolve_calls
    assert_equal [{ session:, include_injected: false }], builder.show_calls
    assert_equal <<~TEXT, out
      Session
      - UID: codex:session-1
      - Agent: codex
      - Project path: /tmp/project
      - Captured at: 2026-08-27T13:00:00Z
      - Message count: 0
      - Summary metadata: injected_parts_filtered=0
    TEXT
  end

  def test_show_current_uses_resolver_current_and_json_output
    session = build_session(agent: :claude, id: "session-2")
    resolver = FakeResolver.new(current_result: session)
    builder = FakeBuilder.new(show_result: build_snapshot(session))

    status, out, err = run_cli("show", "--current", "--format", "json", resolver:, builder:)

    assert_equal 0, status
    assert_equal "warning: exact prompts may contain secrets; review before sharing\n", err
    assert_equal [{ agent: nil }], resolver.current_calls
    assert_empty resolver.resolve_calls
    assert_equal [{ session:, include_injected: false }], builder.show_calls
    assert_equal(
      {
        "session_uid" => "claude:session-2",
        "agent" => "claude",
        "project_path" => "/tmp/project",
        "captured_at" => "2026-08-27T13:00:00Z",
        "message_count" => 0,
        "prompts" => [],
        "injected_context" => [],
        "files" => [],
        "documents" => [],
        "tool_activity" => [],
        "goals" => [],
        "decisions" => [],
        "terms" => [],
        "constraints" => [],
        "open_questions" => [],
        "next_actions" => [],
        "warnings" => [],
        "summary_metadata" => { "injected_parts_filtered" => 0 }
      },
      JSON.parse(out)
    )
    refute out.end_with?("\n")
  end

  def test_show_current_disk_fallback_warns_on_stderr_and_forwards_agent
    session = build_session(agent: :codex, id: "session-2")
    resolver = FakeResolver.new(current_result: session, current_fallback: true)
    builder = FakeBuilder.new(show_result: build_snapshot(session))

    status, out, err = run_cli("show", "--current", "--agent", "codex", "--format", "json", resolver:, builder:)

    assert_equal 0, status
    assert_equal [{ agent: :codex }], resolver.current_calls
    assert_equal <<~WARNING, err
      warning: --current found no session environment identifier; using latest session on disk: codex:session-2
      warning: exact prompts may contain secrets; review before sharing
    WARNING
    assert_equal "codex:session-2", JSON.parse(out).fetch("session_uid")
  end

  def test_show_uses_permute_so_posixly_correct_does_not_change_session_then_option_order
    session = build_session(agent: :codex, id: "session-1")
    resolver = FakeResolver.new(resolve_result: session)
    builder = FakeBuilder.new(show_result: build_snapshot(session))
    original = ENV.fetch("POSIXLY_CORRECT", nil)

    with_posixly_correct do
      status, out, err = run_cli("show", session.id, "--format", "json", resolver:, builder:)

      assert_equal 0, status
      assert_equal "warning: exact prompts may contain secrets; review before sharing\n", err
      assert_equal [{ identifier: "session-1", agent: nil }], resolver.resolve_calls
      assert_equal "codex:session-1", JSON.parse(out).fetch("session_uid")
    end

    if original.nil?
      assert_nil ENV.fetch("POSIXLY_CORRECT", nil)
    else
      assert_equal original, ENV.fetch("POSIXLY_CORRECT", nil)
    end
  end

  def test_show_include_injected_is_forwarded_regardless_of_selection_and_format_option_position
    session = build_session(agent: :codex, id: "session-injected")

    with_cli_env_variants do
      [
        ["show", "--include-injected", session.uid, "--format", "json"],
        ["show", session.uid, "--format", "json", "--include-injected"],
        ["show", "--format=json", "--include-injected", session.uid]
      ].each do |argv|
        resolver = FakeResolver.new(resolve_result: session)
        builder = FakeBuilder.new(show_result: build_snapshot(session))

        status, out, err = run_cli_array(argv, resolver:, builder:)

        assert_equal 0, status
        assert_equal "warning: exact prompts and full injected context may contain secrets; review before sharing\n",
                     err
        assert_equal [{ identifier: session.uid, agent: nil }], resolver.resolve_calls
        assert_equal [{ session:, include_injected: true }], builder.show_calls
        assert_equal session.uid, JSON.parse(out).fetch("session_uid")
      end
    end
  end

  def test_include_injected_is_scoped_to_show_and_rejected_for_prompts_and_summarize
    with_cli_env_variants do
      [
        ["prompts", "session-1", "--include-injected"],
        ["summarize", "session-1", "--include-injected"]
      ].each do |argv|
        status, out, err = run_cli_array(argv)

        assert_equal 1, status
        assert_equal "", out
        assert_equal "invalid option: --include-injected\n", err
      end
    end
  end

  def test_prompts_support_text_markdown_json_and_jsonl_formats_with_privacy_warning_on_stderr
    session = build_session(agent: :codex, id: "session-3")
    prompts = build_prompts(session)

    {
      "text" => proc do |out|
        assert_includes out, "Prompt 1"
        assert_includes out, "first prompt"
        assert out.end_with?("\n")
        refute out.end_with?("\n\n")
      end,
      "markdown" => proc do |out|
        assert_includes out, "## Prompt 1"
        assert_includes out, "```text"
        assert out.end_with?("\n")
        refute out.end_with?("\n\n")
      end,
      "json" => proc do |out|
        payload = JSON.parse(out)
        assert_equal(["first prompt", "second prompt"], payload.map { |prompt| prompt.fetch("text") })
        refute out.end_with?("\n")
      end,
      "jsonl" => proc do |out|
        lines = out.split("\n")
        assert_equal 2, lines.length
        assert_equal "first prompt", JSON.parse(lines.first).fetch("text")
        assert_equal "second prompt", JSON.parse(lines.last).fetch("text")
        refute out.end_with?("\n")
      end
    }.each do |format, assertion|
      resolver = FakeResolver.new(resolve_result: session)
      builder = FakeBuilder.new(prompts_result: build_prompts_result(prompts))

      status, out, err = run_cli("prompts", session.uid, "--format", format, resolver:, builder:)

      assert_equal 0, status, "expected prompts #{format} to succeed"
      assert_equal [{ identifier: session.uid, agent: nil }], resolver.resolve_calls
      assert_equal [session], builder.prompts_result_calls
      assert_includes err, "exact prompts may contain secrets"
      assertion.call(out)
    end
  end

  def test_prompts_current_disk_fallback_warns_before_privacy_warning_and_keeps_jsonl_parseable
    session = build_session(agent: :codex, id: "session-3")
    resolver = FakeResolver.new(current_result: session, current_fallback: true)
    builder = FakeBuilder.new(prompts_result: build_prompts_result(build_prompts(session)))

    status, out, err = run_cli("prompts", "--current", "--agent", "codex", "--format", "jsonl", resolver:, builder:)

    assert_equal 0, status
    assert_equal [{ agent: :codex }], resolver.current_calls
    assert_equal <<~WARNING, err
      warning: --current found no session environment identifier; using latest session on disk: codex:session-3
      warning: exact prompts may contain secrets; review before sharing
    WARNING
    assert_equal(["first prompt", "second prompt"], out.split("\n").map { |line| JSON.parse(line).fetch("text") })
  end

  def test_show_with_real_reader_warning_keeps_json_valid_and_returns_nonzero
    content = [
      JSON.generate(codex_session_meta),
      "not json at all",
      JSON.generate(codex_user_message("Recovered prompt")),
      ""
    ].join("\n")

    with_real_codex_session_file(content) do |session|
      builder = Agent::SessionContext::Builder.new(catalog: Agent::Sessions, now: fixed_time)
      status, out, err = run_cli(
        "show", session.uid, "--format", "json",
        resolver: FakeResolver.new(resolve_result: session),
        builder:
      )

      assert_equal 1, status
      payload = JSON.parse(out)
      assert_equal session.uid, payload.fetch("session_uid")
      assert_equal 1, payload.fetch("summary_metadata").fetch("reader_warning_count")
      assert_equal ["line 2 is not valid JSON; skipped"], payload.fetch("warnings")
      assert_match(/\Awarning: exact prompts may contain secrets; review before sharing\n/, err)
      assert_includes err, "warning: #{session.uid}: line 2 is not valid JSON; skipped"
    end
  end

  def test_prompts_with_real_oversized_record_keeps_jsonl_valid_and_returns_nonzero
    oversized = "x" * (Agent::Sessions::Readers::Base::MAX_RECORD_BYTES + 1)
    content = [
      JSON.generate(codex_session_meta),
      JSON.generate(codex_user_message(oversized)),
      JSON.generate(codex_user_message("Visible prompt")),
      ""
    ].join("\n")

    with_real_codex_session_file(content) do |session|
      builder = Agent::SessionContext::Builder.new(catalog: Agent::Sessions, now: fixed_time)
      status, out, err = run_cli(
        "prompts", session.uid, "--format", "jsonl",
        resolver: FakeResolver.new(resolve_result: session),
        builder:
      )

      assert_equal 1, status
      lines = out.split("\n")
      assert_equal 1, lines.length
      assert_equal "Visible prompt", JSON.parse(lines.first).fetch("text")
      assert_includes err, "exact prompts may contain secrets"
      assert_includes err, "warning: #{session.uid}:"
      assert_includes err, "too large to read"
    end
  end

  def test_loop_prints_the_ascii_view_and_exits_zero
    session = build_session(agent: :codex, id: "session-4")
    resolver = FakeResolver.new(resolve_result: session)
    builder = FakeBuilder.new(loop_result: build_loop(session))

    status, out, err = run_cli("loop", session.uid, resolver:, builder:)

    assert_equal 0, status
    assert_equal "", err, "loop prints no secrets warning: it renders sizes and tool names only"
    assert_equal [{ identifier: session.uid, agent: nil }], resolver.resolve_calls
    assert_equal [session], builder.loop_calls
    assert_includes out, "session #{session.uid}"
    assert_includes out, "ending:"
    assert out.end_with?("\n")
    refute out.end_with?("\n\n")
  end

  def test_loop_supports_text_markdown_and_json_formats
    session = build_session(agent: :codex, id: "session-5")

    {
      "text" => proc do |out|
        assert_includes out, "session #{session.uid}"
        assert out.end_with?("\n")
        refute out.end_with?("\n\n")
      end,
      "markdown" => proc do |out|
        assert out.start_with?("# session")
        assert out.end_with?("\n")
        refute out.end_with?("\n\n")
      end,
      "json" => proc do |out|
        payload = JSON.parse(out)
        assert_equal true, payload.dig("ending", "inferred")
        refute out.end_with?("\n")
      end
    }.each do |format, assertion|
      resolver = FakeResolver.new(resolve_result: session)
      builder = FakeBuilder.new(loop_result: build_loop(session))

      status, out, err = run_cli("loop", session.uid, "--format", format, resolver:, builder:)

      assert_equal 0, status, "expected loop #{format} to succeed"
      assert_equal "", err
      assertion.call(out)
    end
  end

  def test_loop_jsonl_format_emits_one_object_per_round_trip
    with_session([user_turn("hi"), assistant_turn("hello there")]) do |reader|
      session = reader.session
      loop = Agent::SessionContext::Loop.for(reader)
      resolver = FakeResolver.new(resolve_result: session)
      builder = FakeBuilder.new(loop_result: loop)

      status, out, err = run_cli("loop", session.uid, "--format", "jsonl", resolver:, builder:)

      assert_equal 0, status
      assert_equal "", err
      lines = out.split("\n")
      assert_equal loop.round_trips.size, lines.length
      refute out.end_with?("\n")
      lines.each { |line| JSON.parse(line) }
    end
  end

  def test_loop_current_disk_fallback_works_through_the_resolver
    session = build_session(agent: :codex, id: "session-3")
    resolver = FakeResolver.new(current_result: session, current_fallback: true)
    builder = FakeBuilder.new(loop_result: build_loop(session))

    status, out, err = run_cli("loop", "--current", "--agent", "codex", resolver:, builder:)

    assert_equal 0, status
    assert_equal [{ agent: :codex }], resolver.current_calls
    assert_equal(
      "warning: --current found no session environment identifier; using latest session on disk: codex:session-3\n",
      err
    )
    assert_includes out, "session codex:session-3"
  end

  def test_loop_requires_session_or_current
    status, out, err = run_cli("loop")

    assert_equal 1, status
    assert_equal "", out
    assert_equal "pass SESSION or --current\n", err
  end

  def test_loop_with_warnings_exits_nonzero_and_the_warnings_reach_stderr
    session = build_session(agent: :codex, id: "session-9")
    builder = FakeBuilder.new(loop_result: build_loop(session, warnings: ["tool result toolu_x answers no call"]))

    status, out, err = run_cli("loop", session.uid, resolver: FakeResolver.new(resolve_result: session), builder:)

    assert_equal 1, status
    assert_equal "warning: #{session.uid}: tool result toolu_x answers no call\n", err
    assert_includes out, "session #{session.uid}"
  end

  def test_help_lists_loop
    status, out, err = run_cli("help")

    assert_equal 0, status
    assert_equal "", err
    assert_includes out, "loop"
  end

  def test_loop_human_formats_emit_warnings_only_on_stderr
    session = build_session(agent: :codex, id: "session-warning")
    warning = "line 2: unrecognized record type telepathy"
    %w[text markdown].each do |format|
      builder = FakeBuilder.new(loop_result: build_loop(session, warnings: [warning]))
      status, out, err = run_cli("loop", session.uid, "--format", format,
                                 resolver: FakeResolver.new(resolve_result: session), builder:)
      assert_equal 1, status
      assert_equal "warning: #{session.uid}: #{warning}\n", err
      refute_includes out, warning
    end
  end

  def test_loop_json_preserves_structured_warnings
    session = build_session(agent: :codex, id: "session-warning")
    warning = "line 2: unrecognized record type telepathy"
    builder = FakeBuilder.new(loop_result: build_loop(session, warnings: [warning]))
    status, out, err = run_cli("loop", session.uid, "--format", "json",
                               resolver: FakeResolver.new(resolve_result: session), builder:)
    assert_equal 1, status
    assert_equal [warning], JSON.parse(out).fetch("warnings")
    assert_equal "warning: #{session.uid}: #{warning}\n", err
  end

  def test_codex_accounting_is_not_a_loop_entry_or_cli_warning
    records = [codex_message("hello", role: "user"), codex_message("checking", phase: "commentary"),
               codex_reasoning, codex_tool_call, codex_token_usage, codex_tool_result,
               codex_message("done", phase: "final_answer"), codex_token_usage]
    with_codex_session(records) do |reader|
      %w[text markdown json jsonl].each do |format|
        status, out, err = run_cli("loop", reader.session.uid, "--format", format,
                                   resolver: FakeResolver.new(resolve_result: reader.session),
                                   builder: Agent::SessionContext::Builder.new)
        assert_equal 0, status
        assert_empty err
        refute_includes out, "token_usage_record"
        if format == "json"
          data = JSON.parse(out)
          assert_equal 6, data.fetch("round_trips").size
          assert_equal 1, data.fetch("tool_calls").size
          assert data.fetch("tool_calls").first.fetch("answered")
          assert_equal "answered", data.dig("ending", "name")
        elsif format == "jsonl"
          assert_equal 6, out.lines.size
        else
          assert_includes out, "entries: 6"
          assert_includes out, "model entries: 4"
        end
      end
    end
  end

  def test_summarize_with_real_reader_warning_keeps_json_valid_and_returns_nonzero
    content = [
      JSON.generate(codex_session_meta),
      "not json at all",
      JSON.generate(codex_user_message("Recovered prompt")),
      ""
    ].join("\n")

    with_real_codex_session_file(content) do |session|
      builder = Agent::SessionContext::Builder.new(catalog: Agent::Sessions, now: fixed_time)
      backend = FakeSummarizer.new(name: :codex, responses: [JSON.generate(full_payload)])
      status, out, err = run_cli(
        "summarize", session.uid, "--using", "codex", "--format", "json",
        resolver: FakeResolver.new(resolve_result: session),
        builder:,
        backend_factory: FakeBackendFactory.new(codex: backend)
      )

      assert_equal 1, status
      payload = JSON.parse(out)
      assert_equal 1, payload.fetch("summary_metadata").fetch("reader_warning_count")
      assert_match(/\Asummarizing with codex \(timeout: 300s\)\n/, err)
      assert_includes err, "line 2 is not valid JSON; skipped"
    end
  end

  def test_flags_after_double_dash_are_not_parsed_or_used_for_json_error_routing
    status, out, err = run_cli("show", "--", "session-1", "--format", "json")

    assert_equal 1, status
    assert_equal "", out
    assert_equal "unexpected arguments: --format json\n", err
  end

  def test_summarize_supports_codex_claude_and_auto_backends
    [
      { using: "codex", session_agent: :claude, expected_backend: :codex },
      { using: "claude", session_agent: :codex, expected_backend: :claude },
      { using: "auto", session_agent: :claude, expected_backend: :claude }
    ].each do |scenario|
      session = build_session(agent: scenario.fetch(:session_agent), id: "summary-#{scenario.fetch(:using)}")
      backend = FakeSummarizer.new(name: scenario.fetch(:expected_backend), responses: [JSON.generate(full_payload)])
      factory = FakeBackendFactory.new(scenario.fetch(:expected_backend) => backend)
      resolver = FakeResolver.new(resolve_result: session)
      builder = FakeBuilder.new(summarize_result: build_summary_snapshot(session))

      status, out, err = run_cli(
        "summarize", session.uid, "--using", scenario.fetch(:using), "--format", "json",
        resolver:,
        builder:,
        backend_factory: factory
      )

      assert_equal 0, status, "expected summarize #{scenario.fetch(:using)} to succeed"
      assert_equal(
        [{ name: scenario.fetch(:expected_backend),
           timeout_seconds: Agent::SessionContext::Config::DEFAULT_TIMEOUT_SECONDS }],
        factory.calls
      )
      assert_equal [{ session:, summarizer: backend }], builder.summarize_calls
      assert_match(/\Asummarizing with #{scenario.fetch(:expected_backend)} \(timeout: 300s\)\n/, err)
      assert_equal(["Ship it"], JSON.parse(out).fetch("goals").map { |goal| goal.fetch("label") })
    end
  end

  def test_summarize_current_disk_fallback_warns_before_backend_announcement_and_keeps_json_parseable
    session = build_session(agent: :codex, id: "summary-current")
    resolver = FakeResolver.new(current_result: session, current_fallback: true)
    backend = Object.new
    factory = FakeBackendFactory.new(codex: backend)
    builder = FakeBuilder.new(summarize_result: build_summary_snapshot(session))

    status, out, err = run_cli(
      "summarize", "--current", "--agent", "codex", "--format", "json",
      resolver:,
      builder:,
      backend_factory: factory
    )

    assert_equal 0, status
    assert_equal [{ agent: :codex }], resolver.current_calls
    assert_equal <<~WARNING, err
      warning: --current found no session environment identifier; using latest session on disk: codex:summary-current
      summarizing with codex (timeout: 300s)
    WARNING
    assert_equal(["Ship it"], JSON.parse(out).fetch("goals").map { |goal| goal.fetch("label") })
  end

  def test_summarize_loads_config_after_session_resolution_and_forwards_effective_timeout
    session = build_session(agent: :claude, id: "summary-config")
    backend = FakeSummarizer.new(name: :codex, responses: [JSON.generate(full_payload)])
    factory = FakeBackendFactory.new(codex: backend)
    resolver = FakeResolver.new(resolve_result: session)
    builder = FakeBuilder.new(summarize_result: build_summary_snapshot(session))
    config_loader = FakeConfigLoader.new(result: FakeConfig.new(timeout_seconds: 321))
    env = { "AGENT_CONTEXT_TIMEOUT_SOURCE" => "project" }.freeze

    status, out, err = run_cli(
      "summarize", session.uid, "--using", "codex", "--format", "json",
      env:,
      resolver:,
      builder:,
      backend_factory: factory,
      config_loader:
    )

    assert_equal 0, status
    assert_equal [{ identifier: session.uid, agent: nil }], resolver.resolve_calls
    assert_equal [{ session:, env:, timeout: nil }], config_loader.calls
    assert_equal [{ name: :codex, timeout_seconds: 321 }], factory.calls
    assert_equal [{ session:, summarizer: backend }], builder.summarize_calls
    assert_equal(["Ship it"], JSON.parse(out).fetch("goals").map { |goal| goal.fetch("label") })
    assert_equal "summarizing with codex (timeout: 321s)\n", err
  end

  def test_summarize_passes_fractional_cli_timeout_to_loader_and_effective_timeout_to_backend
    with_cli_env_variants do
      session = build_session(agent: :claude, id: "summary-cli-timeout")
      backend = FakeSummarizer.new(name: :claude, responses: [JSON.generate(full_payload)])
      factory = FakeBackendFactory.new(claude: backend)
      resolver = FakeResolver.new(resolve_result: session)
      builder = FakeBuilder.new(summarize_result: build_summary_snapshot(session))
      config_loader = FakeConfigLoader.new(result: FakeConfig.new(timeout_seconds: 12.5))
      env = { "AGENT_CONTEXT_TIMEOUT_SOURCE" => "cli" }.freeze

      status, out, err = run_cli(
        "summarize", session.uid, "--timeout", "12.5", "--format", "json",
        env:,
        resolver:,
        builder:,
        backend_factory: factory,
        config_loader:
      )

      assert_equal 0, status
      assert_equal [{ session:, env:, timeout: 12.5 }], config_loader.calls
      assert_equal [{ name: :claude, timeout_seconds: 12.5 }], factory.calls
      assert_equal [{ session:, summarizer: backend }], builder.summarize_calls
      assert_equal(["Ship it"], JSON.parse(out).fetch("goals").map { |goal| goal.fetch("label") })
      assert_equal "summarizing with claude (timeout: 12.5s)\n", err
    end
  end

  def test_summarize_uses_effective_timeout_from_loader_for_project_user_and_default_sources
    [
      { label: "project", env: { "HOME" => "/tmp/home" }, result: 45, announcement: "45s" },
      { label: "user", env: { "HOME" => "/tmp/home" }, result: 120.0, announcement: "120s" },
      { label: "default", env: {}, result: Agent::SessionContext::Config::DEFAULT_TIMEOUT_SECONDS, announcement: "300s" }
    ].each do |scenario|
      session = build_session(agent: :codex, id: "summary-#{scenario.fetch(:label)}")
      backend = FakeSummarizer.new(name: :codex, responses: [JSON.generate(full_payload)])
      factory = FakeBackendFactory.new(codex: backend)
      resolver = FakeResolver.new(resolve_result: session)
      builder = FakeBuilder.new(summarize_result: build_summary_snapshot(session))
      config_loader = FakeConfigLoader.new(result: FakeConfig.new(timeout_seconds: scenario.fetch(:result)))

      status, out, err = run_cli(
        "summarize", session.uid, "--format", "json",
        env: scenario.fetch(:env),
        resolver:,
        builder:,
        backend_factory: factory,
        config_loader:
      )

      assert_equal 0, status, "expected #{scenario.fetch(:label)} timeout to succeed"
      assert_equal [{ session:, env: scenario.fetch(:env), timeout: nil }], config_loader.calls
      assert_equal [{ name: :codex, timeout_seconds: scenario.fetch(:result) }], factory.calls
      assert_equal(["Ship it"], JSON.parse(out).fetch("goals").map { |goal| goal.fetch("label") })
      assert_equal "summarizing with codex (timeout: #{scenario.fetch(:announcement)})\n", err
    end
  end

  def test_summarize_announces_backend_before_backend_failure
    session = build_session(agent: :claude, id: "summary-fail")
    failure = Agent::SessionContext::SummarizerFailed.new(String.new("bad\x1Bmsg\xFF".b, encoding: Encoding::BINARY))
    backend = FakeSummarizer.new(name: :codex) { raise failure }
    factory = FakeBackendFactory.new(codex: backend)
    builder = FakeBuilder.new
    builder.define_singleton_method(:summarize) do |_session, summarizer:|
      summarizer.call(prompt: "prompt", schema: {})
    end

    status, out, err = run_cli(
      "summarize", session.uid, "--using", "codex",
      resolver: FakeResolver.new(resolve_result: session),
      builder:,
      backend_factory: factory
    )

    assert_equal 1, status
    assert_equal "", out
    assert_equal "summarizing with codex (timeout: 300s)\nbad\\emsg�\n", err
  end

  def test_explicit_session_and_current_are_mutually_exclusive
    status, out, err = run_cli("show", "session-1", "--current")

    assert_equal 1, status
    assert_equal "", out
    assert_includes err, "SESSION and --current are mutually exclusive"
  end

  def test_selection_requires_session_or_current
    status, out, err = run_cli("show")

    assert_equal 1, status
    assert_equal "", out
    assert_includes err, "pass SESSION or --current"
  end

  def test_show_rejects_jsonl_format
    session = build_session(agent: :codex, id: "session-4")

    status, out, err = run_cli(
      "show", session.uid, "--format", "jsonl",
      resolver: FakeResolver.new(resolve_result: session),
      builder: FakeBuilder.new(show_result: build_snapshot(session))
    )

    assert_equal 1, status
    assert_equal "", out
    assert_includes err, "--format jsonl is not supported for show"
  end

  def test_summarize_rejects_jsonl_format
    session = build_session(agent: :codex, id: "session-5")

    status, out, err = run_cli(
      "summarize", session.uid, "--using", "codex", "--format", "jsonl",
      resolver: FakeResolver.new(resolve_result: session),
      builder: FakeBuilder.new(summarize_result: build_summary_snapshot(session)),
      backend_factory: FakeBackendFactory.new(codex: FakeSummarizer.new(responses: [JSON.generate(full_payload)]))
    )

    assert_equal 1, status
    assert_equal "", out
    assert_includes err, "--format jsonl is not supported for summarize"
  end

  def test_timeout_is_scoped_to_summarize_and_rejected_for_show_and_prompts
    with_cli_env_variants do
      [
        ["show", "session-1", "--timeout", "12"],
        ["prompts", "session-1", "--timeout", "12"],
        ["show", "session-1", "--timeout=12"],
        ["prompts", "session-1", "--timeout=12"],
        ["show", "session-1", "--time", "12"],
        ["prompts", "session-1", "--tim", "12"]
      ].each do |argv|
        config_loader = FakeConfigLoader.new
        status, out, err = run_cli_array(argv, config_loader:)

        assert_equal 1, status
        assert_equal "", out
        assert_includes err, "invalid option:"
        assert_equal [], config_loader.calls
      end
    end
  end

  def test_summarize_timeout_parser_rejects_missing_and_nonnumeric_before_config_load
    session = build_session(agent: :codex, id: "summary-timeout-parse")

    with_cli_env_variants do
      [
        { argv: ["summarize", session.uid, "--timeout"], message: "missing argument: --timeout" },
        { argv: ["summarize", session.uid, "--timeout", "bogus"], message: "invalid argument: --timeout bogus" }
      ].each do |scenario|
        config_loader = FakeConfigLoader.new
        status, out, err = run_cli_array(
          scenario.fetch(:argv),
          resolver: FakeResolver.new(resolve_result: session),
          config_loader:
        )

        assert_equal 1, status
        assert_equal "", out
        assert_equal "#{scenario.fetch(:message)}\n", err
        assert_equal [], config_loader.calls
      end
    end
  end

  def test_summarize_rejects_invalid_utf8_timeout_argument_before_resolution_in_text_mode
    session = build_session(agent: :codex, id: "summary-invalid-utf8-timeout-text")

    with_cli_env_variants do
      resolver = FakeResolver.new(resolve_result: session)
      builder = FakeBuilder.new(summarize_result: build_summary_snapshot(session))
      factory = FakeBackendFactory.new(codex: FakeSummarizer.new(responses: [JSON.generate(full_payload)]))
      config_loader = FakeConfigLoader.new

      status, out, err = run_cli_array(
        ["summarize", session.uid, "--timeout", invalid_utf8_timeout_argument],
        resolver:,
        builder:,
        backend_factory: factory,
        config_loader:
      )

      assert_equal 1, status
      assert_equal "", out
      assert_equal "invalid argument: arguments must be valid UTF-8\n", err
      refute_includes err.b, "\xFF".b
      assert_equal [], resolver.resolve_calls
      assert_equal [], config_loader.calls
      assert_equal [], factory.calls
      assert_equal [], builder.summarize_calls
    end
  end

  def test_summarize_rejects_invalid_utf8_timeout_argument_with_json_envelope_regardless_of_order
    session = build_session(agent: :codex, id: "summary-invalid-utf8-timeout-json")

    with_cli_env_variants do
      [
        ["summarize", session.uid, "--timeout", invalid_utf8_timeout_argument, "--format", "json"],
        ["summarize", session.uid, "--format", "json", "--timeout", invalid_utf8_timeout_argument]
      ].each do |argv|
        resolver = FakeResolver.new(resolve_result: session)
        builder = FakeBuilder.new(summarize_result: build_summary_snapshot(session))
        factory = FakeBackendFactory.new(codex: FakeSummarizer.new(responses: [JSON.generate(full_payload)]))
        config_loader = FakeConfigLoader.new

        status, out, err = run_cli_array(
          argv,
          resolver:,
          builder:,
          backend_factory: factory,
          config_loader:
        )

        assert_equal 1, status
        assert_equal "", err
        assert_equal(
          {
            "error" => {
              "type" => "OptionParser::InvalidArgument",
              "message" => "invalid argument: arguments must be valid UTF-8"
            }
          },
          JSON.parse(out)
        )
        refute_includes out.b, "\xFF".b
        assert_equal [], resolver.resolve_calls
        assert_equal [], config_loader.calls
        assert_equal [], factory.calls
        assert_equal [], builder.summarize_calls
      end
    end
  end

  def test_summarize_timeout_range_validation_comes_from_config_loader
    session = build_session(agent: :codex, id: "summary-timeout-range")

    with_cli_env_variants do
      [
        { input: "NaN", expected_timeout: :nan },
        { input: "Infinity", expected_timeout: Float::INFINITY },
        { input: "0", expected_timeout: 0 },
        { input: "3601", expected_timeout: 3601 }
      ].each do |scenario|
        timeout_observer = Class.new do
          attr_reader :calls

          def initialize
            @calls = []
          end

          def load(session:, env:, timeout:)
            @calls << { session:, env:, timeout: }
            raise Agent::SessionContext::ConfigurationError,
                  "Invalid timeout: timeout_seconds must be a finite number between 1 and 3600."
          end
        end.new

        status, out, err = run_cli(
          "summarize", session.uid, "--timeout", scenario.fetch(:input),
          resolver: FakeResolver.new(resolve_result: session),
          backend_factory: FakeBackendFactory.new(codex: FakeSummarizer.new(responses: [JSON.generate(full_payload)])),
          config_loader: timeout_observer
        )

        assert_equal 1, status
        assert_equal "", out
        assert_equal "Invalid timeout: timeout_seconds must be a finite number between 1 and 3600.\n", err
        assert_equal 1, timeout_observer.calls.length
        observed = timeout_observer.calls.first.fetch(:timeout)
        if scenario.fetch(:expected_timeout) == :nan
          assert_predicate observed, :nan?
        else
          assert_equal scenario.fetch(:expected_timeout), observed
        end
      end
    end
  end

  def test_summarize_configuration_errors_use_existing_envelopes_and_skip_work
    session = build_session(agent: :codex, id: "summary-config-error")
    error = Agent::SessionContext::ConfigurationError.new(
      "Invalid timeout at /tmp/project/.agent-context.yml: " \
      "timeout_seconds must be a finite number between 1 and 3600."
    )

    [
      { argv: ["summarize", session.uid], json: false },
      { argv: ["summarize", session.uid, "--format", "json"], json: true }
    ].each do |scenario|
      resolver = FakeResolver.new(resolve_result: session)
      builder = FakeBuilder.new
      factory = FakeBackendFactory.new(codex: FakeSummarizer.new(responses: [JSON.generate(full_payload)]))
      config_loader = FakeConfigLoader.new(error:)

      status, out, err = run_cli_array(
        scenario.fetch(:argv),
        resolver:,
        builder:,
        backend_factory: factory,
        config_loader:
      )

      assert_equal 1, status
      assert_equal [{ identifier: session.uid, agent: nil }], resolver.resolve_calls
      assert_equal [{ session:, env: {}, timeout: nil }], config_loader.calls
      assert_equal [], factory.calls
      assert_equal [], builder.summarize_calls

      if scenario.fetch(:json)
        assert_equal "", err
        assert_equal(
          {
            "error" => {
              "type" => "Agent::SessionContext::ConfigurationError",
              "message" => error.message
            }
          },
          JSON.parse(out)
        )
      else
        assert_equal "", out
        assert_equal "#{error.message}\n", err
      end
    end
  end

  def test_show_and_prompts_never_load_config
    session = build_session(agent: :codex, id: "summary-no-config")
    config_loader = FakeConfigLoader.new

    show_status, = run_cli(
      "show", session.uid,
      resolver: FakeResolver.new(resolve_result: session),
      builder: FakeBuilder.new(show_result: build_snapshot(session)),
      config_loader:
    )
    prompts_status, = run_cli(
      "prompts", session.uid,
      resolver: FakeResolver.new(resolve_result: session),
      builder: FakeBuilder.new(prompts_result: build_prompts_result(build_prompts(session))),
      config_loader:
    )

    assert_equal 0, show_status
    assert_equal 0, prompts_status
    assert_equal [], config_loader.calls
  end

  def test_summarize_rejects_configured_timeout_strings_without_leaking_content_or_calling_backend
    session = build_session(agent: :codex, id: "summary-unsafe-timeout-string")
    malicious_timeout = "300\nSECRET=shh\r\e[31mred"
    config_loader = FakeConfigLoader.new(result: FakeConfig.new(timeout_seconds: malicious_timeout))
    resolver = FakeResolver.new(resolve_result: session)
    builder = FakeBuilder.new(summarize_result: build_summary_snapshot(session))
    factory = FakeBackendFactory.new(codex: FakeSummarizer.new(responses: [JSON.generate(full_payload)]))

    [
      { argv: ["summarize", session.uid], json: false },
      { argv: ["summarize", session.uid, "--format", "json"], json: true }
    ].each_with_index do |scenario, index|
      status, out, err = run_cli_array(
        scenario.fetch(:argv),
        resolver:,
        builder:,
        backend_factory: factory,
        config_loader:
      )

      assert_equal 1, status
      assert_equal index + 1, resolver.resolve_calls.length
      assert_equal [], factory.calls
      assert_equal [], builder.summarize_calls

      if scenario.fetch(:json)
        assert_equal "", err
        payload = JSON.parse(out)
        assert_equal "Agent::SessionContext::ConfigurationError", payload.fetch("error").fetch("type")
        assert_equal "Invalid configured timeout_seconds.", payload.fetch("error").fetch("message")
        refute_includes out, "SECRET=shh"
        refute_includes out, "\e"
      else
        assert_equal "", out
        assert_equal "Invalid configured timeout_seconds.\n", err
        refute_includes err, "SECRET=shh"
        refute_includes err, "\e"
      end
    end
  end

  def test_summarize_rejects_configured_timeout_objects_without_invoking_to_s_or_backend
    session = build_session(agent: :codex, id: "summary-unsafe-timeout-object")
    dangerous_value = Object.new
    dangerous_value.define_singleton_method(:to_s) { raise "should not stringify timeout" }
    config_loader = FakeConfigLoader.new(result: FakeConfig.new(timeout_seconds: dangerous_value))
    resolver = FakeResolver.new(resolve_result: session)
    builder = FakeBuilder.new(summarize_result: build_summary_snapshot(session))
    factory = FakeBackendFactory.new(codex: FakeSummarizer.new(responses: [JSON.generate(full_payload)]))

    [
      { argv: ["summarize", session.uid], json: false },
      { argv: ["summarize", session.uid, "--format", "json"], json: true }
    ].each do |scenario|
      status, out, err = run_cli_array(
        scenario.fetch(:argv),
        resolver:,
        builder:,
        backend_factory: factory,
        config_loader:
      )

      assert_equal 1, status
      assert_equal [], factory.calls
      assert_equal [], builder.summarize_calls

      if scenario.fetch(:json)
        assert_equal "", err
        payload = JSON.parse(out)
        assert_equal "Agent::SessionContext::ConfigurationError", payload.fetch("error").fetch("type")
        assert_equal "Invalid configured timeout_seconds.", payload.fetch("error").fetch("message")
      else
        assert_equal "", out
        assert_equal "Invalid configured timeout_seconds.\n", err
      end
    end
  end

  def test_domain_errors_print_actionable_text_to_stderr
    error = Agent::SessionContext::SessionNotFound.new("Session \"missing\" was not found for codex.")

    status, out, err = run_cli(
      "show", "missing",
      resolver: FakeResolver.new(resolve_error: error),
      builder: FakeBuilder.new
    )

    assert_equal 1, status
    assert_equal "", out
    assert_equal "Session \"missing\" was not found for codex.\n", err
  end

  def test_text_diagnostics_escape_control_characters_for_session_warning_and_error_messages
    session = build_session(agent: :codex, id: "warned", uid: String.new("codex:bad\r\n\x1B]8;;https://evil.example\u0007uid\x1B]8;;\u0007".b))
    warning = String.new("warn\tline\r\n\x1B[31mred\xFF".b, encoding: Encoding::BINARY)
    snapshot = build_snapshot(session, warnings: [warning])

    status, out, err = run_cli(
      "show", session.id,
      resolver: FakeResolver.new(resolve_result: session),
      builder: FakeBuilder.new(show_result: snapshot)
    )

    assert_equal 0, status
    assert_equal <<~TEXT, out
      Session
      - UID: codex:bad\\r\\n\\e]8;;https://evil.example\\u0007uid\\e]8;;\\u0007
      - Agent: codex
      - Project path: /tmp/project
      - Captured at: 2026-08-27T13:00:00Z
      - Message count: 0
      - Summary metadata: injected_parts_filtered=0

      Warnings
      - warn\\tline\\r\\n\\e[31mred�
    TEXT
    assert_equal <<~WARNINGS, err
      warning: exact prompts may contain secrets; review before sharing
      warning: codex:bad\\r\\n\\e]8;;https://evil.example\\u0007uid\\e]8;;\\u0007: warn\\tline\\r\\n\\e[31mred�
    WARNINGS
    refute_includes err, "\e"
  end

  def test_json_errors_use_a_stable_error_envelope_without_stderr_noise
    error = Agent::SessionContext::SessionNotFound.new("Session \"missing\" was not found for codex.")

    status, out, err = run_cli(
      "show", "missing", "--format", "json",
      resolver: FakeResolver.new(resolve_error: error),
      builder: FakeBuilder.new
    )

    assert_equal 1, status
    assert_equal "", err
    assert_equal(
      {
        "error" => {
          "type" => "Agent::SessionContext::SessionNotFound",
          "message" => "Session \"missing\" was not found for codex."
        }
      },
      JSON.parse(out)
    )
    refute out.end_with?("\n")
  end

  def test_json_error_envelope_scrubs_invalid_utf8_type_and_message_without_partial_output
    error_class = Class.new(Agent::SessionContext::Error)
    error_class.define_singleton_method(:name) { String.new("Bad\xFFType".b, encoding: Encoding::BINARY) }
    error = error_class.new(String.new("broken\x1Bmsg\xFF".b, encoding: Encoding::BINARY))

    status, out, err = run_cli(
      "show", "missing", "--bogus", "--format=json",
      resolver: FakeResolver.new(resolve_error: error),
      builder: FakeBuilder.new
    )

    assert_equal 1, status
    assert_equal "", err
    assert_equal(
      {
        "error" => {
          "type" => "OptionParser::InvalidOption",
          "message" => "invalid option: --bogus"
        }
      },
      JSON.parse(out)
    )

    status2, out2, err2 = run_cli(
      "show", "missing", "--format=json",
      resolver: FakeResolver.new(resolve_error: error),
      builder: FakeBuilder.new
    )

    assert_equal 1, status2
    assert_equal "", err2
    assert_equal(
      {
        "error" => {
          "type" => "Bad�Type",
          "message" => "broken\u001bmsg�"
        }
      },
      JSON.parse(out2)
    )
  end

  def test_snapshot_warnings_go_to_stderr_without_polluting_json_stdout
    session = build_session(agent: :codex, id: "warned")
    snapshot = build_snapshot(session, warnings: ["reader warning"])

    status, out, err = run_cli(
      "show", session.uid, "--format", "json",
      resolver: FakeResolver.new(resolve_result: session),
      builder: FakeBuilder.new(show_result: snapshot)
    )

    assert_equal 0, status
    assert_equal ["reader warning"], JSON.parse(out).fetch("warnings")
    assert_match(/\Awarning: exact prompts may contain secrets; review before sharing\n/, err)
    assert_includes err, session.uid
    assert_includes err, "reader warning"
  end

  def test_argv_is_not_mutated
    argv = ["show", "session-1", "--format", "json"]
    session = build_session(agent: :codex, id: "session-1")

    status, = run_cli_array(
      argv,
      resolver: FakeResolver.new(resolve_result: session),
      builder: FakeBuilder.new(show_result: build_snapshot(session))
    )

    assert_equal 0, status
    assert_equal ["show", "session-1", "--format", "json"], argv
  end

  def test_executable_delegates_to_the_cli
    executable = File.read(File.expand_path("../exe/agent-session-context", __dir__))

    assert_includes executable, 'require "agent/session_context"'
    assert_includes executable, "exit Agent::SessionContext::CLI.new(ARGV).run"
  end

  private

  def run_cli(
    *argv,
    env: {},
    resolver: FakeResolver.new,
    builder: FakeBuilder.new,
    backend_factory: FakeBackendFactory.new,
    config_loader: FakeConfigLoader.new
  )
    run_cli_array(argv, env:, resolver:, builder:, backend_factory:, config_loader:)
  end

  def run_cli_array(
    argv,
    env: {},
    resolver: FakeResolver.new,
    builder: FakeBuilder.new,
    backend_factory: FakeBackendFactory.new,
    config_loader: FakeConfigLoader.new
  )
    stdout = StringIO.new
    stderr = StringIO.new
    status = Agent::SessionContext::CLI.new(
      argv,
      env:,
      stdout:,
      stderr:,
      now: fixed_time,
      resolver:,
      builder:,
      backend_factory:,
      config_loader:
    ).run
    [status, stdout.string, stderr.string]
  end

  def fixed_time
    @fixed_time ||= Time.utc(2026, 8, 27, 13, 0, 0)
  end

  def build_session(agent:, id:, uid: nil)
    Session.new(id:, uid: uid || "#{agent}:#{id}", agent:, project_path: "/tmp/project")
  end

  def build_snapshot(session, warnings: [])
    Agent::SessionContext::Snapshot.new(
      session_uid: session.uid,
      agent: session.agent,
      project_path: session.project_path,
      captured_at: fixed_time,
      message_count: 0,
      warnings:,
      summary_metadata: { injected_parts_filtered: 0 }
    )
  end

  def build_summary_snapshot(session)
    Agent::SessionContext::Snapshot.new(
      session_uid: session.uid,
      agent: session.agent,
      project_path: session.project_path,
      captured_at: fixed_time,
      message_count: 2,
      summary_metadata: { backend: :fake, chunks: 1, injected_parts_filtered: 0 },
      goals: [
        Agent::SessionContext::Item.new(
          kind: :goal,
          label: "Ship it",
          evidence: :explicit,
          source_refs: [ref(session.uid, 1, 1)]
        )
      ]
    )
  end

  def build_prompts(session)
    [
      Agent::SessionContext::Prompt.new(
        index: 1,
        at: Time.utc(2026, 8, 27, 12, 0, 0),
        text: "first prompt",
        source_refs: [ref(session.uid, 1, 1)]
      ),
      Agent::SessionContext::Prompt.new(
        index: 2,
        at: nil,
        text: "second prompt",
        source_refs: [ref(session.uid, 2, 1)]
      )
    ].freeze
  end

  def build_prompts_result(prompts, reader_warnings: [])
    PromptsResult.new(prompts:, reader_warnings:)
  end

  # An empty Loop (no round trips recorded) is enough for the CLI-level
  # tests here: they cover dispatch, format selection, and exit codes, not
  # LoopView's own rendering, which loop_view_test.rb already covers in
  # full against real round trips.
  def build_loop(session, warnings: [])
    Agent::SessionContext::Loop.new(
      session:,
      round_trips: [],
      tool_calls: [],
      speakers: {},
      ending: :empty,
      recorded: false,
      warnings:
    )
  end

  def ref(session_uid, message_index, part_index)
    Agent::SessionContext::SourceRef.new(session_uid:, message_index:, part_index:)
  end

  def full_payload(overrides = {})
    {
      "goals" => [],
      "decisions" => [],
      "terms" => [],
      "constraints" => [],
      "open_questions" => [],
      "next_actions" => []
    }.merge(overrides)
  end

  def unsafe_command
    String.new("frobnicate\r\n\x1B]8;;https://evil.example\u0007owned\x1B]8;;\u0007\xFF".b, encoding: Encoding::BINARY)
  end

  def safe_inline(value)
    Agent::SessionContext::Renderers::HumanDisplay.text_inline(value)
  end

  def with_posixly_correct
    original = ENV.fetch("POSIXLY_CORRECT", nil)
    ENV["POSIXLY_CORRECT"] = "1"
    yield
  ensure
    if original.nil?
      ENV.delete("POSIXLY_CORRECT")
    else
      ENV["POSIXLY_CORRECT"] = original
    end
  end

  def with_cli_env_variants(&)
    yield
    with_posixly_correct(&)
  end

  def with_real_codex_session_file(content)
    Dir.mktmpdir("agent-context-cli") do |dir|
      session_id = "00000000-0000-4000-8000-000000000001"
      path = File.join(dir, "rollout-2026-07-21T09-12-03-#{session_id}.jsonl")
      File.binwrite(path, content)
      session = Agent::Sessions::Session.new(
        agent: :codex,
        id: session_id,
        path: path,
        started_at: Time.utc(2026, 7, 21, 9, 12, 3),
        updated_at: Time.utc(2026, 7, 21, 9, 12, 3),
        bytes: File.size(path),
        format: :jsonl,
        fidelity: :full,
        project_path: "/tmp/project"
      )
      yield session
    end
  end

  def codex_session_meta
    {
      type: "session_meta",
      timestamp: "2026-07-21T09:12:03.000Z",
      payload: { id: "00000000-0000-4000-8000-000000000001", cwd: "/tmp/project", cli_version: "0.0.0" }
    }
  end

  def codex_user_message(text)
    {
      type: "response_item",
      timestamp: "2026-07-21T09:12:03.000Z",
      payload: { type: "message", role: "user", content: [{ type: "input_text", text: text }] }
    }
  end

  def invalid_utf8_timeout_argument
    String.new("\xFF".b, encoding: Encoding::UTF_8)
  end
end
