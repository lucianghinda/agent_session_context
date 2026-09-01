# frozen_string_literal: true

require "test_helper"
require "fileutils"
require_relative "support/fake_summarizer"

class IntegrationTest < Minitest::Test
  SNAPSHOT_KEYS = %w[
    session_uid
    agent
    project_path
    captured_at
    message_count
    prompts
    injected_context
    files
    documents
    tool_activity
    goals
    decisions
    terms
    constraints
    open_questions
    next_actions
    warnings
    summary_metadata
  ].freeze

  def test_claude_fixture_exercises_public_api_with_real_reader_and_exact_prompt_filtering
    fixture_path = fixture("claude/session.jsonl")
    tracked = tracked_fixture_copy(fixture_path)

    with_fixture_session(:claude, fixture_path) do |session, staged|
      summarizer = FakeSummarizer.new(name: nil, responses: [claude_summary_payload(session)])
      builder = Agent::SessionContext::Builder.new

      show_snapshot = Agent::SessionContext.show(session)
      prompts = Agent::SessionContext.prompts(session)
      full_show_snapshot = builder.show(session, include_injected: true)
      summary_snapshot = builder.summarize(session, summarizer:)

      assert_equal "/Users/you/demo-app", session.project_path
      refute File.symlink?(session.path)
      assert_operator tracked.fetch(:bytes).bytesize, :<, 10_240
      assert_snapshot_keys(show_snapshot)
      assert_snapshot_keys(summary_snapshot)
      assert_equal 5, show_snapshot.message_count
      assert_equal 5, summary_snapshot.message_count
      assert_equal({ injected_parts_filtered: 2 }, show_snapshot.summary_metadata)
      assert_equal({ backend: :custom, chunks: 1, injected_parts_filtered: 2 }, summary_snapshot.summary_metadata)

      assert_equal ["README.md"], show_snapshot.files.map(&:label)
      assert_equal ["README.md"], show_snapshot.documents.map(&:label)
      assert_equal ["Read"], show_snapshot.tool_activity.map(&:label)
      assert_equal ["Decide whether Agent Context should ship"], summary_snapshot.goals.map(&:label)
      assert_equal ["Ship the initial release"], summary_snapshot.decisions.map(&:label)
      assert_equal([["prompt exclusion", "Injected or tool-result text omitted from semantic extraction"]],
                   summary_snapshot.terms.map { |item| [item.label, item.detail] })
      assert_equal ["Inspect README.md before shipping"], summary_snapshot.constraints.map(&:label)
      assert_equal ["Should the README explain prompt exclusions?"], summary_snapshot.open_questions.map(&:label)
      assert_equal ["Update README"], summary_snapshot.next_actions.map(&:label)

      assert_equal [
        Agent::SessionContext::Prompt.new(
          index: 1,
          at: Time.utc(2026, 8, 27, 10, 0, 0),
          text: "Please read README.md and decide whether Agent Context should ship.",
          source_refs: [ref(session, 1, 1)]
        )
      ], prompts
      assert_equal prompts, show_snapshot.prompts
      assert_equal [], summary_snapshot.prompts
      assert_equal [], summary_snapshot.injected_context
      assert(show_snapshot.injected_context.all? { |context| context.text.nil? })
      assert_equal %i[command_name provider_meta], show_snapshot.injected_context.map(&:kind)
      assert_equal [1, 1], show_snapshot.injected_context.map(&:occurrences)

      injected_texts = [
        "<command-name>/compact</command-name>\n" \
        "<command-message>Keep only the release decision.</command-message>",
        "Internal planner note: preserve the release rationale only."
      ]
      assert_equal injected_texts, full_show_snapshot.injected_context.map(&:text)

      request = summarizer.requests.fetch(0)
      assert_equal 1, summarizer.requests.length
      assert_includes request.prompt, "Please read README.md and decide whether Agent Context should ship."
      assert_includes request.prompt, "Decision: ship the initial release."
      assert_includes request.prompt, "\"kind\":\"tool_use\""
      assert_includes request.prompt, "\"label\":\"README.md\""
      summarizer.requests.each do |recorded_request|
        refute_includes recorded_request.prompt, "README body from tool output"
        refute_includes recorded_request.prompt, "<command-name>/compact</command-name>"
        refute_includes recorded_request.prompt, "<command-message>"
        refute_includes recorded_request.prompt, "Keep only the release decision."
        refute_includes recorded_request.prompt, "Internal planner note: preserve the release rationale only."
      end

      assert_equal(
        [{ "index" => 1, "at" => "2026-08-27T10:00:00Z",
           "text" => "Please read README.md and decide whether Agent Context should ship.",
           "source_refs" => [serialized_ref(session, 1, 1)] }],
        parse_jsonl(prompts)
      )

      show_json = parse_snapshot(show_snapshot)
      full_show_json = parse_snapshot(full_show_snapshot)
      summary_json = parse_snapshot(summary_snapshot)
      assert_equal parse_jsonl(prompts), show_json.fetch("prompts")
      assert_equal 2, show_json.fetch("injected_context").length
      assert(show_json.fetch("injected_context").all? { |context| context.fetch("text").nil? })
      assert_equal [
        { "kind" => "command_name", "bytes" => injected_texts.fetch(0).bytesize, "occurrences" => 1,
          "source_refs" => [serialized_ref(session, 4, 1)], "text" => injected_texts.fetch(0) },
        { "kind" => "provider_meta", "bytes" => injected_texts.fetch(1).bytesize, "occurrences" => 1,
          "source_refs" => [serialized_ref(session, 5, 1)], "text" => injected_texts.fetch(1) }
      ], full_show_json.fetch("injected_context")
      assert_equal [], summary_json.fetch("prompts")
      assert_equal [], summary_json.fetch("injected_context")
      assert_snapshot_collections(
        show_json,
        files: [{ "kind" => "file", "label" => "README.md", "detail" => nil, "evidence" => "observed",
                  "source_refs" => [serialized_ref(session, 2, 2)], "attributes" => { "action" => "read" } }],
        documents: [{ "kind" => "file", "label" => "README.md", "detail" => nil, "evidence" => "observed",
                      "source_refs" => [serialized_ref(session, 2, 2)], "attributes" => { "action" => "read" } }],
        tool_activity: [{ "kind" => "tool", "label" => "Read", "detail" => nil, "evidence" => "observed",
                          "source_refs" => [serialized_ref(session, 2, 2)],
                          "attributes" => { "call_id" => "toolu_1", "input_keys" => ["path"] } }],
        goals: [],
        decisions: [],
        terms: [],
        constraints: [],
        open_questions: [],
        next_actions: []
      )
      assert_snapshot_collections(
        summary_json,
        files: [{ "kind" => "file", "label" => "README.md", "detail" => nil, "evidence" => "observed",
                  "source_refs" => [serialized_ref(session, 2, 2)], "attributes" => { "action" => "read" } }],
        documents: [{ "kind" => "file", "label" => "README.md", "detail" => nil, "evidence" => "observed",
                      "source_refs" => [serialized_ref(session, 2, 2)], "attributes" => { "action" => "read" } }],
        tool_activity: [{ "kind" => "tool", "label" => "Read", "detail" => nil, "evidence" => "observed",
                          "source_refs" => [serialized_ref(session, 2, 2)],
                          "attributes" => { "call_id" => "toolu_1", "input_keys" => ["path"] } }],
        goals: [{ "kind" => "goal", "label" => "Decide whether Agent Context should ship", "detail" => nil,
                  "evidence" => "explicit", "source_refs" => [serialized_ref(session, 1, 1)], "attributes" => {} }],
        decisions: [{ "kind" => "decision", "label" => "Ship the initial release", "detail" => nil,
                      "evidence" => "explicit", "source_refs" => [serialized_ref(session, 2, 1)], "attributes" => {} }],
        terms: [{ "kind" => "term", "label" => "prompt exclusion",
                  "detail" => "Injected or tool-result text omitted from semantic extraction",
                  "evidence" => "explicit", "source_refs" => [serialized_ref(session, 2, 1)], "attributes" => {} }],
        constraints: [{ "kind" => "constraint", "label" => "Inspect README.md before shipping", "detail" => nil,
                        "evidence" => "explicit", "source_refs" => [serialized_ref(session, 2, 1)],
                        "attributes" => {} }],
        open_questions: [{ "kind" => "open_question",
                           "label" => "Should the README explain prompt exclusions?",
                           "detail" => nil, "evidence" => "explicit",
                           "source_refs" => [serialized_ref(session, 2, 1)], "attributes" => {} }],
        next_actions: [{ "kind" => "next_action", "label" => "Update README",
                         "detail" => nil,
                         "evidence" => "explicit", "source_refs" => [serialized_ref(session, 2, 1)],
                         "attributes" => {} }]
      )

      assert_unchanged_copy(tracked, fixture_path)
      assert_unchanged_copy(staged, session.path)
    end
  end

  def test_codex_fixture_exercises_public_api_with_real_reader_and_exact_prompt_filtering
    fixture_path = fixture("codex/rollout.jsonl")
    tracked = tracked_fixture_copy(fixture_path)

    with_fixture_session(:codex, fixture_path) do |session, staged|
      summarizer = FakeSummarizer.new(name: nil, responses: [codex_summary_payload(session)])
      builder = Agent::SessionContext::Builder.new

      show_snapshot = Agent::SessionContext.show(session)
      prompts = Agent::SessionContext.prompts(session)
      full_show_snapshot = builder.show(session, include_injected: true)
      summary_snapshot = builder.summarize(session, summarizer:)

      assert_equal "/Users/you/demo-app", session.project_path
      refute File.symlink?(session.path)
      assert_operator tracked.fetch(:bytes).bytesize, :<, 10_240
      assert_snapshot_keys(show_snapshot)
      assert_snapshot_keys(summary_snapshot)
      assert_equal 6, show_snapshot.message_count
      assert_equal 6, summary_snapshot.message_count
      assert_equal({ injected_parts_filtered: 2 }, show_snapshot.summary_metadata)
      assert_equal({ backend: :custom, chunks: 1, injected_parts_filtered: 2 }, summary_snapshot.summary_metadata)

      assert_equal ["README.md"], show_snapshot.files.map(&:label)
      assert_equal ["README.md"], show_snapshot.documents.map(&:label)
      assert_equal ["Read"], show_snapshot.tool_activity.map(&:label)
      assert_equal ["Record what should be documented"], summary_snapshot.goals.map(&:label)
      assert_equal ["Keep injected environment and AGENTS blocks out of prompts and summaries"],
                   summary_snapshot.decisions.map(&:label)
      assert_equal([["packet", "One bounded evidence batch"]],
                   summary_snapshot.terms.map { |item| [item.label, item.detail] })
      assert_equal ["Inspect README.md before documenting the API"], summary_snapshot.constraints.map(&:label)
      assert_equal ["Should the README list every excluded injected shape?"],
                   summary_snapshot.open_questions.map(&:label)
      assert_equal ["Document the public Ruby API"], summary_snapshot.next_actions.map(&:label)

      assert_equal [
        Agent::SessionContext::Prompt.new(
          index: 1,
          at: Time.utc(2026, 8, 27, 10, 5, 3),
          text: "Please define packet, inspect README.md, and record what should be documented.",
          source_refs: [ref(session, 3, 1)]
        )
      ], prompts
      assert_equal prompts, show_snapshot.prompts
      assert_equal [], summary_snapshot.prompts
      assert_equal [], summary_snapshot.injected_context
      assert(show_snapshot.injected_context.all? { |context| context.text.nil? })
      assert_equal %i[environment_context agents_instructions], show_snapshot.injected_context.map(&:kind)
      assert_equal [1, 1], show_snapshot.injected_context.map(&:occurrences)

      injected_texts = [
        "<environment_context>\n<cwd>/Users/you/demo-app</cwd>\n" \
        "<approval_policy>never</approval_policy>\n</environment_context>",
        "# AGENTS.md instructions\nUse Ruby for utility scripts.\n"
      ]
      assert_equal injected_texts, full_show_snapshot.injected_context.map(&:text)

      request = summarizer.requests.fetch(0)
      assert_equal 1, summarizer.requests.length
      assert_includes request.prompt, "Please define packet, inspect README.md, and record what should be documented."
      assert_includes request.prompt, "Term: packet means one bounded evidence batch."
      assert_includes request.prompt, "\"kind\":\"tool_use\""
      assert_includes request.prompt, "\"label\":\"README.md\""
      summarizer.requests.each do |recorded_request|
        refute_includes recorded_request.prompt, "README body from tool output"
        refute_includes recorded_request.prompt, "<environment_context>"
        refute_includes recorded_request.prompt, "<approval_policy>never</approval_policy>"
        refute_includes recorded_request.prompt, "</environment_context>"
        refute_includes recorded_request.prompt, "# AGENTS.md instructions"
        refute_includes recorded_request.prompt, "Use Ruby for utility scripts."
      end

      assert_equal(
        [{ "index" => 1, "at" => "2026-08-27T10:05:03Z",
           "text" => "Please define packet, inspect README.md, and record what should be documented.",
           "source_refs" => [serialized_ref(session, 3, 1)] }],
        parse_jsonl(prompts)
      )

      show_json = parse_snapshot(show_snapshot)
      full_show_json = parse_snapshot(full_show_snapshot)
      summary_json = parse_snapshot(summary_snapshot)
      assert_equal parse_jsonl(prompts), show_json.fetch("prompts")
      assert_equal 2, show_json.fetch("injected_context").length
      assert(show_json.fetch("injected_context").all? { |context| context.fetch("text").nil? })
      assert_equal [
        { "kind" => "environment_context", "bytes" => injected_texts.fetch(0).bytesize, "occurrences" => 1,
          "source_refs" => [serialized_ref(session, 1, 1)], "text" => injected_texts.fetch(0) },
        { "kind" => "agents_instructions", "bytes" => injected_texts.fetch(1).bytesize, "occurrences" => 1,
          "source_refs" => [serialized_ref(session, 2, 1)], "text" => injected_texts.fetch(1) }
      ], full_show_json.fetch("injected_context")
      assert_equal [], summary_json.fetch("prompts")
      assert_equal [], summary_json.fetch("injected_context")
      assert_snapshot_collections(
        show_json,
        files: [{ "kind" => "file", "label" => "README.md", "detail" => nil, "evidence" => "observed",
                  "source_refs" => [serialized_ref(session, 5, 1)], "attributes" => { "action" => "read" } }],
        documents: [{ "kind" => "file", "label" => "README.md", "detail" => nil, "evidence" => "observed",
                      "source_refs" => [serialized_ref(session, 5, 1)], "attributes" => { "action" => "read" } }],
        tool_activity: [{ "kind" => "tool", "label" => "Read", "detail" => nil, "evidence" => "observed",
                          "source_refs" => [serialized_ref(session, 5, 1)],
                          "attributes" => { "call_id" => "call_1", "input_keys" => ["path"] } }],
        goals: [],
        decisions: [],
        terms: [],
        constraints: [],
        open_questions: [],
        next_actions: []
      )
      assert_snapshot_collections(
        summary_json,
        files: [{ "kind" => "file", "label" => "README.md", "detail" => nil, "evidence" => "observed",
                  "source_refs" => [serialized_ref(session, 5, 1)], "attributes" => { "action" => "read" } }],
        documents: [{ "kind" => "file", "label" => "README.md", "detail" => nil, "evidence" => "observed",
                      "source_refs" => [serialized_ref(session, 5, 1)], "attributes" => { "action" => "read" } }],
        tool_activity: [{ "kind" => "tool", "label" => "Read", "detail" => nil, "evidence" => "observed",
                          "source_refs" => [serialized_ref(session, 5, 1)],
                          "attributes" => { "call_id" => "call_1", "input_keys" => ["path"] } }],
        goals: [{ "kind" => "goal", "label" => "Record what should be documented", "detail" => nil,
                  "evidence" => "explicit", "source_refs" => [serialized_ref(session, 3, 1)], "attributes" => {} }],
        decisions: [{ "kind" => "decision",
                      "label" => "Keep injected environment and AGENTS blocks out of prompts and summaries",
                      "detail" => nil, "evidence" => "explicit",
                      "source_refs" => [serialized_ref(session, 4, 1)], "attributes" => {} }],
        terms: [{ "kind" => "term", "label" => "packet", "detail" => "One bounded evidence batch",
                  "evidence" => "explicit", "source_refs" => [serialized_ref(session, 4, 1)], "attributes" => {} }],
        constraints: [{ "kind" => "constraint", "label" => "Inspect README.md before documenting the API",
                        "detail" => nil, "evidence" => "explicit",
                        "source_refs" => [serialized_ref(session, 4, 1)], "attributes" => {} }],
        open_questions: [{ "kind" => "open_question",
                           "label" => "Should the README list every excluded injected shape?",
                           "detail" => nil, "evidence" => "explicit",
                           "source_refs" => [serialized_ref(session, 4, 1)], "attributes" => {} }],
        next_actions: [{ "kind" => "next_action", "label" => "Document the public Ruby API",
                         "detail" => nil, "evidence" => "explicit",
                         "source_refs" => [serialized_ref(session, 4, 1)], "attributes" => {} }]
      )

      assert_unchanged_copy(tracked, fixture_path)
      assert_unchanged_copy(staged, session.path)
    end
  end

  private

  def fixture(relative_path)
    File.expand_path(File.join("fixtures", relative_path), __dir__)
  end

  def with_fixture_session(agent, fixture_path)
    tracked = tracked_fixture_copy(fixture_path)
    staged = nil
    staged_path = nil
    body_error = nil

    Dir.mktmpdir("agent-context-integration") do |home|
      staged_path = stage_fixture_copy(agent, fixture_path, home)
      staged = tracked_fixture_copy(staged_path)
      session = Agent::Sessions.sessions(agent, env: { "HOME" => home }).first
      refute_nil session
      yield session, staged
    # Cleanup must also run for interrupts and other non-StandardError failures.
    rescue Exception => e # rubocop:disable Lint/RescueException
      body_error = e
      raise
    ensure
      begin
        assert_unchanged_copy(tracked, fixture_path)
        assert_unchanged_copy(staged, staged_path) if staged && staged_path
      rescue Minitest::Assertion, StandardError => e
        raise e unless body_error

        nil
      end
    end
  end

  def stage_fixture_copy(agent, fixture_path, home)
    target =
      case agent
      when :claude
        File.join(home, ".claude", "projects", "-Users-you-demo-app",
                  "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee.jsonl")
      when :codex
        File.join(home, ".codex", "sessions", "2026", "08", "27",
                  "rollout-2026-08-27T10-05-00-00000000-0000-4000-8000-000000000001.jsonl")
      else
        raise "unsupported fixture agent #{agent.inspect}"
      end

    FileUtils.mkdir_p(File.dirname(target))
    FileUtils.cp(fixture_path, target)
    target
  end

  def tracked_fixture_copy(path)
    { bytes: File.binread(path), mtime: File.mtime(path) }
  end

  def assert_unchanged_copy(snapshot, path)
    assert_equal snapshot.fetch(:bytes), File.binread(path)
    assert_equal snapshot.fetch(:mtime).to_f, File.mtime(path).to_f
  end

  def parse_snapshot(snapshot)
    parsed = JSON.parse(Agent::SessionContext::Renderers::JSON.new.call(snapshot))
    assert_equal SNAPSHOT_KEYS, parsed.keys
    parsed
  end

  def parse_jsonl(prompts)
    Agent::SessionContext::Renderers::JSONLines.new.call(prompts).split("\n").map { |line| JSON.parse(line) }
  end

  def assert_snapshot_keys(snapshot)
    assert_equal(
      %i[
        session_uid
        agent
        project_path
        captured_at
        message_count
        prompts
        injected_context
        files
        documents
        tool_activity
        goals
        decisions
        terms
        constraints
        open_questions
        next_actions
        warnings
        summary_metadata
      ],
      snapshot.members
    )
  end

  def assert_snapshot_collections(snapshot_json, expected)
    expected.each do |key, value|
      assert_equal value, snapshot_json.fetch(key.to_s)
      assert_instance_of Array, snapshot_json.fetch(key.to_s)
    end
  end

  def ref(session, message_index, part_index)
    Agent::SessionContext::SourceRef.new(
      session_uid: session.uid,
      message_index: message_index,
      part_index: part_index
    )
  end

  def serialized_ref(session, message_index, part_index)
    { "session_uid" => session.uid, "message_index" => message_index, "part_index" => part_index }
  end

  def claude_summary_payload(session)
    JSON.generate(
      "goals" => [{ "text" => "Decide whether Agent Context should ship", "evidence" => "explicit",
                    "source_refs" => [ref(session, 1, 1).to_s] }],
      "decisions" => [{ "text" => "Ship the initial release", "evidence" => "explicit",
                        "source_refs" => [ref(session, 2, 1).to_s] }],
      "terms" => [{ "term" => "prompt exclusion",
                    "definition" => "Injected or tool-result text omitted from semantic extraction",
                    "evidence" => "explicit", "source_refs" => [ref(session, 2, 1).to_s] }],
      "constraints" => [{ "text" => "Inspect README.md before shipping", "evidence" => "explicit",
                          "source_refs" => [ref(session, 2, 1).to_s] }],
      "open_questions" => [{ "text" => "Should the README explain prompt exclusions?", "evidence" => "explicit",
                             "source_refs" => [ref(session, 2, 1).to_s] }],
      "next_actions" => [{ "text" => "Update README", "evidence" => "explicit",
                           "source_refs" => [ref(session, 2, 1).to_s] }]
    )
  end

  def codex_summary_payload(session)
    JSON.generate(
      "goals" => [{ "text" => "Record what should be documented", "evidence" => "explicit",
                    "source_refs" => [ref(session, 3, 1).to_s] }],
      "decisions" => [{ "text" => "Keep injected environment and AGENTS blocks out of prompts and summaries",
                        "evidence" => "explicit", "source_refs" => [ref(session, 4, 1).to_s] }],
      "terms" => [{ "term" => "packet", "definition" => "One bounded evidence batch",
                    "evidence" => "explicit", "source_refs" => [ref(session, 4, 1).to_s] }],
      "constraints" => [{ "text" => "Inspect README.md before documenting the API", "evidence" => "explicit",
                          "source_refs" => [ref(session, 4, 1).to_s] }],
      "open_questions" => [{ "text" => "Should the README list every excluded injected shape?",
                             "evidence" => "explicit", "source_refs" => [ref(session, 4, 1).to_s] }],
      "next_actions" => [{ "text" => "Document the public Ruby API", "evidence" => "explicit",
                           "source_refs" => [ref(session, 4, 1).to_s] }]
    )
  end
end
