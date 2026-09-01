# frozen_string_literal: true

require "test_helper"

class RenderersTest < Minitest::Test
  def test_text_renderer_formats_snapshot_in_deterministic_section_order
    expected = <<~TEXT.chomp
      Session
      - UID: codex:session-123
      - Agent: codex
      - Project path: /tmp/project
      - Captured at: 2026-08-27T13:00:00Z
      - Message count: 4
      - Summary metadata: backend=codex, chunks=2, injected_parts_filtered=1

      Goal
      - Ship deterministic renderers [explicit] refs 1:1, 2:1

      Files
      - README.md (action=read, bytes=128) [observed] refs 2:1

      Documents
      - docs/spec.md (action=read, format=markdown) [observed] refs 2:2

      Tool activity
      - apply_patch (call_id=call-7, path=lib/agent/context/renderers/text.rb) [observed] refs 3:1

      Decisions
      - Use one shared serializer [inferred] refs 3:2

      Terminology
      - snapshot: One captured session view [explicit] refs 1:2

      Constraints
      - Machine output must remain valid [explicit] refs 1:3

      Open questions
      - Should prompt JSON include session ids? [inferred] refs 4:1

      Next actions
      - Run the full suite [explicit] refs 4:2

      Warnings
      - reader warning
      - summary warning
    TEXT

    rendered = Agent::SessionContext::Renderers::Text.new.call(full_snapshot)

    assert_equal expected, rendered
    refute_predicate rendered, :end_with?, "\n"
  end

  def test_markdown_renderer_formats_snapshot_in_deterministic_section_order
    expected = <<~MARKDOWN.chomp
      ## Session
      - UID: `codex:session-123`
      - Agent: `codex`
      - Project path: `/tmp/project`
      - Captured at: `2026-08-27T13:00:00Z`
      - Message count: `4`
      - Summary metadata: `backend=codex, chunks=2, injected_parts_filtered=1`

      ## Goal
      - Ship deterministic renderers `[explicit]` refs `1:1, 2:1`

      ## Files
      - README.md (`action=read, bytes=128`) `[observed]` refs `2:1`

      ## Documents
      - docs/spec.md (`action=read, format=markdown`) `[observed]` refs `2:2`

      ## Tool activity
      - apply_patch (`call_id=call-7, path=lib/agent/context/renderers/text.rb`) `[observed]` refs `3:1`

      ## Decisions
      - Use one shared serializer `[inferred]` refs `3:2`

      ## Terminology
      - snapshot: One captured session view `[explicit]` refs `1:2`

      ## Constraints
      - Machine output must remain valid `[explicit]` refs `1:3`

      ## Open questions
      - Should prompt JSON include session ids? `[inferred]` refs `4:1`

      ## Next actions
      - Run the full suite `[explicit]` refs `4:2`

      ## Warnings
      - reader warning
      - summary warning
    MARKDOWN

    rendered = Agent::SessionContext::Renderers::Markdown.new.call(full_snapshot)

    assert_equal expected, rendered
    refute_predicate rendered, :end_with?, "\n"
  end

  def test_snapshot_renderers_place_prompts_and_injected_context_before_observed_evidence
    injected_text = "# AGENTS.md instructions\n## forged heading\n```ruby\nputs 1\n```\n\e[31m"
    snapshot = Agent::SessionContext::Snapshot.new(
      session_uid: "codex:session-123",
      agent: :codex,
      project_path: "/tmp/project",
      captured_at: Time.utc(2026, 8, 28, 8, 0, 0),
      message_count: 3,
      prompts: [
        Agent::SessionContext::Prompt.new(
          index: 1,
          at: nil,
          text: "Exact prompt",
          source_refs: [ref(1, 1)]
        )
      ],
      injected_context: [
        Agent::SessionContext::InjectedContext.new(
          kind: :agents_instructions,
          bytes: injected_text.bytesize,
          occurrences: 2,
          source_refs: [ref(2, 1), ref(3, 1)],
          text: injected_text
        )
      ],
      files: [
        Agent::SessionContext::Item.new(
          kind: :file,
          label: "README.md",
          evidence: :observed,
          source_refs: [ref(3, 2)]
        )
      ]
    )

    text = Agent::SessionContext::Renderers::Text.new.call(snapshot)
    markdown = Agent::SessionContext::Renderers::Markdown.new.call(snapshot)

    assert_includes text, "User prompts"
    assert_includes text, "Injected context"
    assert_operator text.index("User prompts"), :<, text.index("Injected context")
    assert_operator text.index("Injected context"), :<, text.index("Files")
    assert_includes text, "Prompt 1"
    assert_includes text, "- Bytes: #{injected_text.bytesize}"
    assert_includes text, "- Occurrences: 2"
    assert_includes text, "- Refs: 2:1, 3:1"
    assert_includes text, "| \\e[31m"

    assert_includes markdown, "## User prompts"
    assert_includes markdown, "## Injected context"
    assert_operator markdown.index("## User prompts"), :<, markdown.index("## Injected context")
    assert_operator markdown.index("## Injected context"), :<, markdown.index("## Files")
    assert_includes markdown, "### Prompt 1"
    assert_includes markdown, "### Injected `agents_instructions`"
    assert_includes markdown, Agent::SessionContext::Renderers::HumanDisplay.markdown_block(injected_text)
  end

  def test_human_renderers_omit_empty_categories_but_keep_session_section
    snapshot = Agent::SessionContext::Snapshot.new(
      session_uid: "codex:empty",
      agent: :codex,
      project_path: nil,
      captured_at: Time.utc(2026, 8, 27, 13, 30, 0),
      message_count: 0,
      summary_metadata: {}
    )

    text = Agent::SessionContext::Renderers::Text.new.call(snapshot)
    markdown = Agent::SessionContext::Renderers::Markdown.new.call(snapshot)

    refute_includes text, "User prompts"
    refute_includes text, "Injected context"
    refute_includes markdown, "## User prompts"
    refute_includes markdown, "## Injected context"

    assert_equal <<~TEXT.chomp, text
      Session
      - UID: codex:empty
      - Agent: codex
      - Captured at: 2026-08-27T13:30:00Z
      - Message count: 0
    TEXT

    assert_equal <<~MARKDOWN.chomp, markdown
      ## Session
      - UID: `codex:empty`
      - Agent: `codex`
      - Captured at: `2026-08-27T13:30:00Z`
      - Message count: `0`
    MARKDOWN
  end

  def test_json_renderer_round_trips_full_snapshot_with_deterministic_keys
    rendered = Agent::SessionContext::Renderers::JSON.new.call(full_snapshot)
    parsed = ::JSON.parse(rendered)

    assert_equal(
      %w[
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
      parsed.keys
    )
    assert_equal "2026-08-27T13:00:00Z", parsed.fetch("captured_at")
    assert_equal "explicit", parsed.fetch("goals").first.fetch("evidence")
    assert_equal({ "session_uid" => "codex:session-123", "message_index" => 1, "part_index" => 1 },
                 parsed.fetch("goals").first.fetch("source_refs").first)
    assert_equal %w[action bytes], parsed.fetch("files").first.fetch("attributes").keys
    assert_equal({ "backend" => "codex", "chunks" => 2, "injected_parts_filtered" => 1 },
                 parsed.fetch("summary_metadata"))
    refute_predicate rendered, :end_with?, "\n"
  end

  def test_json_renderer_preserves_empty_arrays_for_empty_snapshot_categories
    rendered = Agent::SessionContext::Renderers::JSON.new.call(
      Agent::SessionContext::Snapshot.new(
        session_uid: "codex:empty",
        agent: :codex,
        project_path: nil,
        captured_at: Time.utc(2026, 8, 27, 13, 30, 0),
        message_count: 0
      )
    )
    parsed = ::JSON.parse(rendered)

    assert_equal [], parsed.fetch("files")
    assert_equal [], parsed.fetch("documents")
    assert_equal [], parsed.fetch("tool_activity")
    assert_equal [], parsed.fetch("goals")
    assert_equal [], parsed.fetch("decisions")
    assert_equal [], parsed.fetch("terms")
    assert_equal [], parsed.fetch("constraints")
    assert_equal [], parsed.fetch("open_questions")
    assert_equal [], parsed.fetch("next_actions")
    assert_equal [], parsed.fetch("warnings")
    assert_equal({}, parsed.fetch("summary_metadata"))
  end

  def test_json_renderer_serializes_prompts_and_injected_context
    snapshot = Agent::SessionContext::Snapshot.new(
      session_uid: "codex:session-123",
      agent: :codex,
      project_path: "/tmp/project",
      captured_at: Time.utc(2026, 8, 28, 8, 0, 0),
      message_count: 2,
      prompts: sample_prompts,
      injected_context: [
        Agent::SessionContext::InjectedContext.new(
          kind: :environment_context,
          bytes: 31,
          occurrences: 1,
          source_refs: [ref(1, 4)]
        )
      ]
    )
    parsed = ::JSON.parse(Agent::SessionContext::Renderers::JSON.new.call(snapshot))

    assert_equal "First prompt", parsed.fetch("prompts").first.fetch("text")
    assert_equal(
      {
        "kind" => "environment_context",
        "bytes" => 31,
        "occurrences" => 1,
        "source_refs" => [
          { "session_uid" => "codex:session-123", "message_index" => 1, "part_index" => 4 }
        ],
        "text" => nil
      },
      parsed.fetch("injected_context").first
    )
  end

  def test_json_lines_renderer_emits_one_parseable_prompt_object_per_line
    rendered = Agent::SessionContext::Renderers::JSONLines.new.call(sample_prompts)
    lines = rendered.split("\n")

    assert_equal 2, lines.length
    assert_equal(
      {
        "index" => 1,
        "at" => "2026-08-27T12:00:00Z",
        "text" => "First prompt",
        "source_refs" => [{ "session_uid" => "codex:session-123", "message_index" => 1, "part_index" => 1 }]
      },
      ::JSON.parse(lines[0])
    )
    assert_equal(
      {
        "index" => 2,
        "at" => nil,
        "text" => "Second prompt",
        "source_refs" => [{ "session_uid" => "codex:session-123", "message_index" => 2, "part_index" => 1 }]
      },
      ::JSON.parse(lines[1])
    )
    refute_predicate rendered, :end_with?, "\n"
  end

  def test_prompt_collection_renderers_keep_exact_machine_text_and_frozen_inputs
    prompts = machine_prompts
    original_text = prompts.map(&:text)

    text = Agent::SessionContext::Renderers::Text.new.call(prompts)
    markdown = Agent::SessionContext::Renderers::Markdown.new.call(prompts)
    json = ::JSON.parse(Agent::SessionContext::Renderers::JSON.new.call(prompts))
    jsonl = Agent::SessionContext::Renderers::JSONLines.new.call(prompts).split("\n").map { |line| ::JSON.parse(line) }

    assert_equal <<~TEXT.chomp, text
      Prompt 1
      - At: 2026-08-27 12:00 local\\tzone
      - Refs: 1:1
      | First line
      | ## Forged heading
      | ```ruby
      | puts 1
      | ```
      | \\e]8;;https://evil.example\\u0007owned\\e]8;;\\u0007

      Prompt 2
      - Refs: 2:1
      | exact machine text
    TEXT

    assert_equal <<~MARKDOWN.chomp, markdown
      ## Prompt 1
      - At: `2026-08-27 12:00 local\\tzone`
      - Refs: `1:1`

      ````text
      First line
      ## Forged heading
      ```ruby
      puts 1
      ```
      \\e]8;;https://evil.example\\u0007owned\\e]8;;\\u0007
      ````

      ## Prompt 2
      - Refs: `2:1`

      ```text
      exact machine text
      ```
    MARKDOWN

    assert_equal machine_prompts_json, json
    assert_equal machine_prompts_json, jsonl
    assert_equal original_text, prompts.map(&:text)
    assert_predicate prompts, :frozen?
    refute_predicate text, :end_with?, "\n"
    refute_predicate markdown, :end_with?, "\n"
  end

  def test_markdown_literal_uses_commonmark_safe_code_spans_for_edge_cases
    assert_equal "<code></code>", Agent::SessionContext::Renderers::HumanDisplay.markdown_literal("")
    assert_equal "<code> </code>", Agent::SessionContext::Renderers::HumanDisplay.markdown_literal(" ")
    assert_equal "<code>   </code>", Agent::SessionContext::Renderers::HumanDisplay.markdown_literal("   ")
    assert_equal "` leading`", Agent::SessionContext::Renderers::HumanDisplay.markdown_literal(" leading")
    assert_equal "`trailing `", Agent::SessionContext::Renderers::HumanDisplay.markdown_literal("trailing ")
    assert_equal "`  both  `", Agent::SessionContext::Renderers::HumanDisplay.markdown_literal(" both ")
    assert_equal "`` ` ``", Agent::SessionContext::Renderers::HumanDisplay.markdown_literal("`")
    assert_equal "```` ``` ````", Agent::SessionContext::Renderers::HumanDisplay.markdown_literal("```")
  end

  def test_sanitize_string_appends_ordinary_codepoints_without_integer_chr
    result = nil

    with_integer_chr_stub do
      result = Agent::SessionContext::Renderers::HumanDisplay.sanitize_string("plain text", preserve_newlines: false)
    end

    assert_equal "plain text", result
  end

  def test_human_renderers_make_untrusted_inline_fields_safe_and_visible
    text = Agent::SessionContext::Renderers::Text.new.call(adversarial_snapshot)
    markdown = Agent::SessionContext::Renderers::Markdown.new.call(adversarial_snapshot)

    assert_equal <<~TEXT.chomp, text
      Session
      - UID: codex:evil\\r\\n## Warnings
      - Agent: codex
      - Project path: /tmp/\\e]8;;https://evil.example\\u0007owned\\e]8;;\\u0007\\tpath
      - Captured at: 2026-08-27 local\\n## Goal
      - Message count: 2
      - Summary metadata: backend\\nWarnings=codex, note=uses\\ttab

      Goal
      - Ship\\n## Fake heading [explicit] refs 1:1

      Decisions
      - Use `ticks` and _stars_ [inferred] refs 1:2

      Terminology
      - term#1: Definition\\n- forged bullet [explicit] refs 1:3

      Warnings
      - warning\\e[31mred\\u0007
    TEXT

    assert_equal <<~MARKDOWN.chomp, markdown
      ## Session
      - UID: `codex:evil\\r\\n## Warnings`
      - Agent: `codex`
      - Project path: `/tmp/\\e]8;;https://evil.example\\u0007owned\\e]8;;\\u0007\\tpath`
      - Captured at: `2026-08-27 local\\n## Goal`
      - Message count: `2`
      - Summary metadata: `backend\\nWarnings=codex, note=uses\\ttab`

      ## Goal
      - Ship\\\\n\\#\\# Fake heading `[explicit]` refs `1:1`

      ## Decisions
      - Use \\`ticks\\` and \\_stars\\_ `[inferred]` refs `1:2`

      ## Terminology
      - term\\#1: Definition\\\\n\\- forged bullet `[explicit]` refs `1:3`

      ## Warnings
      - warning\\\\e\\[31mred\\\\u0007
    MARKDOWN

    refute_includes text, "\e"
    refute_includes markdown, "\e"
    assert_equal 1, text.scan(/^Warnings$/).length
    assert_equal 1, markdown.scan(/^## Warnings$/).length
  end

  def test_markdown_renderer_escapes_raw_html_autolinks_and_ampersands_in_prose
    snapshot = Agent::SessionContext::Snapshot.new(
      session_uid: "codex:html",
      agent: :codex,
      project_path: nil,
      captured_at: Time.utc(2026, 8, 27, 14, 0, 0),
      message_count: 1,
      goals: [
        Agent::SessionContext::Item.new(
          kind: :goal,
          label: "<h1>Ship & verify</h1>",
          evidence: :explicit,
          source_refs: [ref(1, 1)]
        )
      ],
      decisions: [
        Agent::SessionContext::Item.new(
          kind: :decision,
          label: "<script>alert(1)</script>",
          evidence: :inferred,
          source_refs: [ref(1, 2)]
        )
      ],
      terms: [
        Agent::SessionContext::Item.new(
          kind: :term,
          label: "link",
          detail: "<https://evil.example?a=1&b=2>",
          evidence: :explicit,
          source_refs: [ref(1, 3)]
        )
      ],
      warnings: ["<b>warning & watch</b>"]
    )

    rendered = Agent::SessionContext::Renderers::Markdown.new.call(snapshot)

    assert_includes rendered, "- &lt;h1&gt;Ship &amp; verify&lt;/h1&gt; `[explicit]` refs `1:1`"
    assert_includes rendered, "- &lt;script&gt;alert(1)&lt;/script&gt; `[inferred]` refs `1:2`"
    assert_includes rendered, "- link: &lt;https://evil.example?a=1&amp;b=2&gt; `[explicit]` refs `1:3`"
    assert_includes rendered, "- &lt;b&gt;warning &amp; watch&lt;/b&gt;"
    refute_includes rendered, "<script>"
    refute_includes rendered, "<https://evil.example?a=1&b=2>"
  end

  def test_json_renderer_rejects_duplicate_normalized_hash_keys_without_mutating_inputs
    payload = { foo: 1, "foo" => 2 }

    error = assert_raises(ArgumentError) do
      Agent::SessionContext::Renderers::JSON.new.call(payload)
    end

    assert_equal 'duplicate serialized key: "foo"', error.message
    assert_equal({ foo: 1, "foo" => 2 }, payload)
  end

  def test_json_renderer_rejects_nested_duplicate_keys_after_utf8_scrubbing
    invalid_key = String.new("dup\xFF".b, encoding: Encoding::BINARY)
    nested = { "dup�" => 1, invalid_key => 2 }
    payload = { "outer" => nested }

    error = assert_raises(ArgumentError) do
      Agent::SessionContext::Renderers::JSON.new.call(payload)
    end

    assert_equal 'duplicate serialized key: "dup\uFFFD"', error.message
    assert_equal({ "dup�" => 1, invalid_key => 2 }, nested)
    assert_equal({ "outer" => nested }, payload)
  end

  def test_serializer_detects_first_collision_deterministically_before_serializing_values
    explosive = Class.new do
      def to_s
        raise "should not serialize exploding value first"
      end
    end

    payload = {
      "z" => explosive.new,
      :z => 2,
      "a\n" => 1,
      :"a\n" => explosive.new
    }
    reversed = payload.to_a.reverse.to_h
    nested = { "outer" => reversed }

    [payload, reversed, nested].each do |value|
      error = assert_raises(ArgumentError) do
        Agent::SessionContext::Renderers::JSON.new.call(value)
      end

      assert_equal 'duplicate serialized key: "a\n"', error.message
    end
  end

  def test_human_display_attributes_reject_duplicate_normalized_keys_and_sort_nested_hashes
    error = assert_raises(ArgumentError) do
      Agent::SessionContext::Renderers::HumanDisplay.attributes({ foo: 1, "foo" => 2 }, inline_formatter: Agent::SessionContext::Renderers::HumanDisplay.method(:text_inline))
    end

    assert_equal 'duplicate serialized key: "foo"', error.message
    assert_equal(
      "alpha=1, nested={a=1, b=2}, zed=3",
      Agent::SessionContext::Renderers::HumanDisplay.attributes(
        { zed: 3, nested: { "b" => 2, a: 1 }, alpha: 1 },
        inline_formatter: Agent::SessionContext::Renderers::HumanDisplay.method(:text_inline)
      )
    )
  end

  def test_human_display_attributes_do_not_double_convert_nested_scalars
    tracker = scalar_tracker("value")

    rendered = Agent::SessionContext::Renderers::HumanDisplay.attributes(
      { nested: { value: tracker } },
      inline_formatter: Agent::SessionContext::Renderers::HumanDisplay.method(:text_inline)
    )

    assert_equal "nested={value=value}", rendered
    assert_equal 1, tracker.calls
  end

  def test_renderers_format_string_timestamps_consistently_with_machine_output
    prompt = Agent::SessionContext::Prompt.new(
      index: 1,
      at: "2026-08-27 12:00 local\tzone",
      text: "Timestamp prompt",
      source_refs: [ref(1, 1)]
    )
    snapshot = Agent::SessionContext::Snapshot.new(
      session_uid: "codex:string-time",
      agent: :codex,
      project_path: nil,
      captured_at: "2026-08-27 13:00 local\tzone",
      message_count: 1
    )

    text_prompt = Agent::SessionContext::Renderers::Text.new.call([prompt])
    markdown_prompt = Agent::SessionContext::Renderers::Markdown.new.call([prompt])
    json_prompt = ::JSON.parse(Agent::SessionContext::Renderers::JSON.new.call([prompt]))
    jsonl_prompt = ::JSON.parse(Agent::SessionContext::Renderers::JSONLines.new.call([prompt]))
    text_snapshot = Agent::SessionContext::Renderers::Text.new.call(snapshot)
    markdown_snapshot = Agent::SessionContext::Renderers::Markdown.new.call(snapshot)
    json_snapshot = ::JSON.parse(Agent::SessionContext::Renderers::JSON.new.call(snapshot))

    assert_includes text_prompt, "- At: 2026-08-27 12:00 local\\tzone"
    assert_includes markdown_prompt, "- At: `2026-08-27 12:00 local\\tzone`"
    assert_equal "2026-08-27 12:00 local\tzone", json_prompt.first.fetch("at")
    assert_equal "2026-08-27 12:00 local\tzone", jsonl_prompt.fetch("at")
    assert_includes text_snapshot, "- Captured at: 2026-08-27 13:00 local\\tzone"
    assert_includes markdown_snapshot, "- Captured at: `2026-08-27 13:00 local\\tzone`"
    assert_equal "2026-08-27 13:00 local\tzone", json_snapshot.fetch("captured_at")
  end

  def test_renderers_reject_unsupported_timestamp_values_and_non_finite_numbers
    prompt_with_nan = Agent::SessionContext::Prompt.new(
      index: 1,
      at: Float::NAN,
      text: "bad timestamp",
      source_refs: [ref(1, 1)]
    )
    prompt_with_infinity = Agent::SessionContext::Prompt.new(
      index: 1,
      at: Float::INFINITY,
      text: "bad timestamp",
      source_refs: [ref(1, 1)]
    )
    snapshot_with_number_timestamp = Agent::SessionContext::Snapshot.new(
      session_uid: "codex:bad-time",
      agent: :codex,
      project_path: nil,
      captured_at: 12.5,
      message_count: 1
    )
    payload_with_infinite_number = { ratio: Float::INFINITY }

    [prompt_with_nan, prompt_with_infinity].each do |prompt|
      [Agent::SessionContext::Renderers::Text.new, Agent::SessionContext::Renderers::Markdown.new].each do |renderer|
        error = assert_raises(ArgumentError) { renderer.call([prompt]) }
        assert_equal "unsupported timestamp value: Float", error.message
      end

      error = assert_raises(ArgumentError) { Agent::SessionContext::Renderers::JSON.new.call([prompt]) }
      assert_equal "unsupported timestamp value: Float", error.message

      error = assert_raises(ArgumentError) { Agent::SessionContext::Renderers::JSONLines.new.call([prompt]) }
      assert_equal "unsupported timestamp value: Float", error.message
    end

    [Agent::SessionContext::Renderers::Text.new, Agent::SessionContext::Renderers::Markdown.new].each do |renderer|
      error = assert_raises(ArgumentError) { renderer.call(snapshot_with_number_timestamp) }
      assert_equal "unsupported timestamp value: Float", error.message
    end

    error = assert_raises(ArgumentError) { Agent::SessionContext::Renderers::JSON.new.call(snapshot_with_number_timestamp) }
    assert_equal "unsupported timestamp value: Float", error.message

    error = assert_raises(ArgumentError) { Agent::SessionContext::Renderers::JSON.new.call(payload_with_infinite_number) }
    assert_equal "unsupported numeric value: Float", error.message
  end

  def test_timestamp_errors_use_stable_class_names_without_controls_or_object_ids
    hostile_value = Class.new do
      def inspect
        "\e]8;;https://evil.example\u0007owned\e]8;;\u0007\n0xBAD"
      end

      def to_s
        inspect
      end
    end.new

    prompt = Agent::SessionContext::Prompt.new(
      index: 1,
      at: hostile_value,
      text: "bad timestamp",
      source_refs: [ref(1, 1)]
    )
    snapshot = Agent::SessionContext::Snapshot.new(
      session_uid: "codex:hostile-time",
      agent: :codex,
      project_path: nil,
      captured_at: hostile_value,
      message_count: 1
    )

    [
      -> { Agent::SessionContext::Renderers::Text.new.call([prompt]) },
      -> { Agent::SessionContext::Renderers::Markdown.new.call([prompt]) },
      -> { Agent::SessionContext::Renderers::JSON.new.call([prompt]) },
      -> { Agent::SessionContext::Renderers::JSONLines.new.call([prompt]) },
      -> { Agent::SessionContext::Renderers::Text.new.call(snapshot) },
      -> { Agent::SessionContext::Renderers::Markdown.new.call(snapshot) },
      -> { Agent::SessionContext::Renderers::JSON.new.call(snapshot) }
    ].each do |callable|
      error = assert_raises(ArgumentError, &callable)
      assert_equal "unsupported timestamp value: (anonymous class)", error.message
      refute_match(/\e/, error.message)
      refute_match(/\n/, error.message)
      refute_match(/0x[0-9A-F]+/i, error.message)
    end
  end

  def test_json_renderers_replace_invalid_utf8_instead_of_crashing
    invalid_text = String.new("bad\xFFtext".b, encoding: Encoding::BINARY)
    invalid_prompt = Agent::SessionContext::Prompt.new(
      index: 1,
      at: Time.utc(2026, 8, 27, 12, 0, 0),
      text: invalid_text,
      source_refs: [ref(1, 1)]
    )
    invalid_snapshot = Agent::SessionContext::Snapshot.new(
      session_uid: "codex:invalid",
      agent: :codex,
      project_path: invalid_text,
      captured_at: Time.utc(2026, 8, 27, 13, 45, 0),
      message_count: 1,
      files: [
        Agent::SessionContext::Item.new(
          kind: :file,
          label: invalid_text,
          detail: invalid_text,
          evidence: :observed,
          source_refs: [ref(1, 1)]
        )
      ],
      warnings: [invalid_text],
      summary_metadata: { backend: :codex }
    )

    snapshot_json = ::JSON.parse(Agent::SessionContext::Renderers::JSON.new.call(invalid_snapshot))
    prompt_jsonl = Agent::SessionContext::Renderers::JSONLines.new.call([invalid_prompt])

    assert_equal "bad\ufffdtext", snapshot_json.fetch("project_path")
    assert_equal "bad\ufffdtext", snapshot_json.fetch("files").first.fetch("label")
    assert_equal "bad\ufffdtext", snapshot_json.fetch("files").first.fetch("detail")
    assert_equal ["bad\ufffdtext"], snapshot_json.fetch("warnings")
    assert_equal "bad\ufffdtext", ::JSON.parse(prompt_jsonl).fetch("text")
  end

  private

  def full_snapshot
    Agent::SessionContext::Snapshot.new(
      session_uid: "codex:session-123",
      agent: :codex,
      project_path: "/tmp/project",
      captured_at: Time.utc(2026, 8, 27, 13, 0, 0),
      message_count: 4,
      files: [
        Agent::SessionContext::Item.new(
          kind: :file,
          label: "README.md",
          evidence: :observed,
          source_refs: [ref(2, 1)],
          attributes: { action: :read, bytes: 128 }
        )
      ],
      documents: [
        Agent::SessionContext::Item.new(
          kind: :file,
          label: "docs/spec.md",
          evidence: :observed,
          source_refs: [ref(2, 2)],
          attributes: { action: :read, format: :markdown }
        )
      ],
      tool_activity: [
        Agent::SessionContext::Item.new(
          kind: :tool,
          label: "apply_patch",
          evidence: :observed,
          source_refs: [ref(3, 1)],
          attributes: { call_id: "call-7", path: "lib/agent/context/renderers/text.rb" }
        )
      ],
      goals: [
        Agent::SessionContext::Item.new(
          kind: :goal,
          label: "Ship deterministic renderers",
          evidence: :explicit,
          source_refs: [ref(1, 1), ref(2, 1)]
        )
      ],
      decisions: [
        Agent::SessionContext::Item.new(
          kind: :decision,
          label: "Use one shared serializer",
          evidence: :inferred,
          source_refs: [ref(3, 2)]
        )
      ],
      terms: [
        Agent::SessionContext::Item.new(
          kind: :term,
          label: "snapshot",
          detail: "One captured session view",
          evidence: :explicit,
          source_refs: [ref(1, 2)]
        )
      ],
      constraints: [
        Agent::SessionContext::Item.new(
          kind: :constraint,
          label: "Machine output must remain valid",
          evidence: :explicit,
          source_refs: [ref(1, 3)]
        )
      ],
      open_questions: [
        Agent::SessionContext::Item.new(
          kind: :open_question,
          label: "Should prompt JSON include session ids?",
          evidence: :inferred,
          source_refs: [ref(4, 1)]
        )
      ],
      next_actions: [
        Agent::SessionContext::Item.new(
          kind: :next_action,
          label: "Run the full suite",
          evidence: :explicit,
          source_refs: [ref(4, 2)]
        )
      ],
      warnings: ["reader warning", "summary warning"],
      summary_metadata: { backend: :codex, chunks: 2, injected_parts_filtered: 1 }
    )
  end

  def sample_prompts
    [
      Agent::SessionContext::Prompt.new(
        index: 1,
        at: Time.utc(2026, 8, 27, 12, 0, 0),
        text: "First prompt",
        source_refs: [ref(1, 1)]
      ),
      Agent::SessionContext::Prompt.new(
        index: 2,
        at: nil,
        text: "Second prompt",
        source_refs: [ref(2, 1)]
      )
    ]
  end

  def machine_prompts
    [
      Agent::SessionContext::Prompt.new(
        index: 1,
        at: "2026-08-27 12:00 local\tzone",
        text: "First line\n## Forged heading\n```ruby\nputs 1\n```\n\e]8;;https://evil.example\u0007owned\e]8;;\u0007",
        source_refs: [ref(1, 1)]
      ),
      Agent::SessionContext::Prompt.new(
        index: 2,
        at: nil,
        text: "exact machine text",
        source_refs: [ref(2, 1)]
      )
    ].freeze
  end

  def machine_prompts_json
    [
      {
        "index" => 1,
        "at" => "2026-08-27 12:00 local\tzone",
        "text" => "First line\n## Forged heading\n```ruby\nputs 1\n```\n\e]8;;https://evil.example\u0007owned\e]8;;\u0007",
        "source_refs" => [{ "session_uid" => "codex:session-123", "message_index" => 1, "part_index" => 1 }]
      },
      {
        "index" => 2,
        "at" => nil,
        "text" => "exact machine text",
        "source_refs" => [{ "session_uid" => "codex:session-123", "message_index" => 2, "part_index" => 1 }]
      }
    ]
  end

  def adversarial_snapshot
    Agent::SessionContext::Snapshot.new(
      session_uid: "codex:evil\r\n## Warnings",
      agent: :codex,
      project_path: "/tmp/\e]8;;https://evil.example\u0007owned\e]8;;\u0007\tpath",
      captured_at: "2026-08-27 local\n## Goal",
      message_count: 2,
      goals: [
        Agent::SessionContext::Item.new(
          kind: :goal,
          label: "Ship\n## Fake heading",
          evidence: :explicit,
          source_refs: [ref(1, 1)]
        )
      ],
      decisions: [
        Agent::SessionContext::Item.new(
          kind: :decision,
          label: "Use `ticks` and _stars_",
          evidence: :inferred,
          source_refs: [ref(1, 2)]
        )
      ],
      terms: [
        Agent::SessionContext::Item.new(
          kind: :term,
          label: "term#1",
          detail: "Definition\n- forged bullet",
          evidence: :explicit,
          source_refs: [ref(1, 3)]
        )
      ],
      warnings: ["warning\e[31mred\u0007"],
      summary_metadata: { "backend\nWarnings" => :codex, note: "uses\ttab" }
    )
  end

  def ref(message_index, part_index)
    Agent::SessionContext::SourceRef.new(
      session_uid: "codex:session-123",
      message_index: message_index,
      part_index: part_index
    )
  end

  def scalar_tracker(text)
    Class.new do
      attr_reader :calls

      define_method(:initialize) do |value|
        @value = value
        @calls = 0
      end

      define_method(:to_s) do
        @calls += 1
        @value
      end
    end.new(text)
  end

  def with_integer_chr_stub
    integer = Integer
    integer.class_eval do
      alias_method :__renderers_test_original_chr, :chr
      define_method(:chr) do |*|
        raise "Integer#chr should not be called"
      end
    end

    yield
  ensure
    integer.class_eval do
      remove_method :chr
      alias_method :chr, :__renderers_test_original_chr
      remove_method :__renderers_test_original_chr
    end
  end
end
