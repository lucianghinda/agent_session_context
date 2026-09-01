# frozen_string_literal: true

require "test_helper"

class TranscriptTest < Minitest::Test
  CLAUDE_MARKER_KINDS = {
    "<command-name>" => :command_name,
    "<command-message>" => :command_message,
    "<command-args>" => :command_args,
    "<local-command-stdout>" => :local_command_stdout,
    "<local-command-stderr>" => :local_command_stderr,
    "<system-reminder>" => :system_reminder
  }.freeze

  CODEX_MARKER_KINDS = {
    "<environment_context>" => :environment_context,
    "<user_instructions>" => :user_instructions,
    "# AGENTS.md instructions" => :agents_instructions
  }.freeze

  CLAUDE_MARKERS = CLAUDE_MARKER_KINDS.keys.freeze
  CODEX_MARKERS = CODEX_MARKER_KINDS.keys.freeze

  FakeReader = Struct.new(:messages, :warnings, :after_enumeration) do
    def each_message(&block)
      return enum_for(:each_message) unless block_given?

      messages.each(&block)
      after_enumeration&.call(self)
    end
  end

  def test_capture_preserves_message_order_indexes_and_source_refs
    session = build_session(agent: :codex)
    reader = FakeReader.new(
      [
        build_message(
          role: :user,
          at: Time.utc(2026, 8, 27, 12, 0, 0),
          parts: [
            build_part(type: :text, text: "First prompt"),
            build_part(type: :image)
          ]
        ),
        build_message(
          role: :assistant,
          at: Time.utc(2026, 8, 27, 12, 1, 0),
          parts: [
            build_part(type: :tool_use, name: "search", call_id: "call-1"),
            build_part(type: :text, text: "Answer")
          ]
        )
      ],
      []
    )
    now = Time.utc(2026, 8, 27, 12, 5, 0)

    transcript = Agent::SessionContext::Transcript.capture(session, reader: reader, now: now)

    assert_same now, transcript.captured_at
    assert_same session, transcript.session
    assert_equal [1, 2], transcript.entries.map(&:index)
    assert_equal %i[user assistant], transcript.entries.map(&:role)
    assert_equal [1, 2], transcript.entries.first.parts.map(&:index)
    assert_equal [1, 2], transcript.entries.last.parts.map(&:index)
    assert_equal "First prompt", transcript.entries.first.parts.first.text
    assert_nil transcript.entries.first.parts.last.text
    assert_equal "search", transcript.entries.last.parts.first.name
    assert_equal "call-1", transcript.entries.last.parts.first.call_id
    assert_equal(
      Agent::SessionContext::SourceRef.new(session_uid: session.uid, message_index: 2, part_index: 2),
      transcript.entries.last.parts.last.source_ref
    )
    refute_includes transcript.entries.first.to_h.keys, :raw
    assert_predicate transcript.entries, :frozen?
    assert_predicate transcript.entries.first.parts, :frozen?
  end

  def test_capture_marks_raw_meta_user_text_parts_as_injected
    transcript = Agent::SessionContext::Transcript.capture(
      build_session(agent: :codex),
      reader: FakeReader.new(
        [
          build_message(
            role: :user,
            at: Time.utc(2026, 8, 27, 12, 0, 0),
            raw: { "isMeta" => true },
            parts: [
              build_part(type: :text, text: "meta"),
              build_part(type: :tool_result, text: "tool output")
            ]
          )
        ],
        []
      ),
      now: Time.utc(2026, 8, 27, 12, 5, 0)
    )

    assert_equal true, transcript.entries.first.parts.first.injected
    assert_equal false, transcript.entries.first.parts.last.injected
  end

  def test_capture_detects_malformed_raw_meta_and_marker_text_without_changing_bytes
    raw_meta_text = "\xFFopaque provider metadata".b.force_encoding(Encoding::UTF_8)
    marker_text = " \t<system-reminder>payload\xFF".b.force_encoding(Encoding::UTF_8)
    transcript = Agent::SessionContext::Transcript.capture(
      build_session(agent: :claude),
      reader: FakeReader.new(
        [
          build_message(
            role: :user,
            at: Time.utc(2026, 8, 27, 12, 0, 0),
            raw: { "isMeta" => true },
            parts: [build_part(type: :text, text: raw_meta_text)]
          ),
          build_message(
            role: :user,
            at: Time.utc(2026, 8, 27, 12, 1, 0),
            parts: [build_part(type: :text, text: marker_text)]
          )
        ],
        []
      ),
      now: Time.utc(2026, 8, 27, 12, 5, 0)
    )

    captured_parts = transcript.entries.map { |entry| entry.parts.first }
    assert_equal [true, true], captured_parts.map(&:injected)
    assert_equal([raw_meta_text.bytes, marker_text.bytes], captured_parts.map { |part| part.text.bytes })
    assert_equal([Encoding::UTF_8, Encoding::UTF_8], captured_parts.map { |part| part.text.encoding })
  end

  def test_capture_applies_all_claude_markers_and_rejects_codex_markers_for_claude
    assert_marker_matrix(
      agent: :claude,
      injected_markers: CLAUDE_MARKERS,
      non_injected_markers: CODEX_MARKERS
    )
  end

  def test_capture_applies_all_codex_markers_and_rejects_claude_markers_for_codex
    assert_marker_matrix(
      agent: :codex,
      injected_markers: CODEX_MARKERS,
      non_injected_markers: CLAUDE_MARKERS
    )
  end

  def test_marker_constants_are_owned_by_transcript_not_session_context
    Agent::SessionContext.const_get(:Transcript)

    refute Agent::SessionContext.const_defined?(:CLAUDE_INJECTION_MARKERS, false)
    refute Agent::SessionContext.const_defined?(:CODEX_INJECTION_MARKERS, false)
    assert_equal(
      {
        claude: CLAUDE_MARKER_KINDS,
        codex: CODEX_MARKER_KINDS
      },
      Agent::SessionContext::Transcript::INJECTION_MARKERS
    )
  end

  def test_capture_keeps_non_text_and_ordinary_user_text_parts_non_injected
    transcript = Agent::SessionContext::Transcript.capture(
      build_session(agent: :claude),
      reader: FakeReader.new(
        [
          build_message(
            role: :user,
            at: Time.utc(2026, 8, 27, 12, 0, 0),
            parts: [
              build_part(type: :text, text: "Plain user text"),
              build_part(type: :image),
              build_part(type: :tool_result, text: "tool output")
            ]
          )
        ],
        []
      ),
      now: Time.utc(2026, 8, 27, 12, 5, 0)
    )

    assert_equal [false, false, false], transcript.entries.first.parts.map(&:injected)
  end

  def test_capture_copies_warnings_after_enumeration_and_detaches_from_reader_mutations
    warning = String.new("reader warning")
    reader = FakeReader.new(
      [
        build_message(
          role: :user,
          at: Time.utc(2026, 8, 27, 12, 0, 0),
          parts: [build_part(type: :text, text: "Prompt")]
        )
      ],
      [warning],
      ->(fake_reader) { fake_reader.warnings << String.new("late warning") }
    )

    transcript = Agent::SessionContext::Transcript.capture(
      build_session(agent: :codex),
      reader: reader,
      now: Time.utc(2026, 8, 27, 12, 5, 0)
    )

    warning.replace("mutated")
    reader.warnings << "later mutation"

    assert_equal ["reader warning", "late warning"], transcript.warnings
    assert_predicate transcript.warnings, :frozen?
    assert_predicate transcript.warnings.first, :frozen?
  end

  def test_capture_is_stable_after_message_part_and_warning_inputs_mutate
    text = String.new("Original text")
    name = String.new("search")
    call_id = String.new("call-1")
    part = build_part(type: :text, text: text)
    tool_part = build_part(type: :tool_use, name: name, call_id: call_id)
    parts = [part, tool_part]
    message = build_message(role: :user, at: Time.utc(2026, 8, 27, 12, 0, 0), parts: parts)
    warnings = [String.new("stable warning")]
    reader = FakeReader.new([message], warnings)

    transcript = Agent::SessionContext::Transcript.capture(
      build_session(agent: :codex),
      reader: reader,
      now: Time.utc(2026, 8, 27, 12, 5, 0)
    )

    text.replace("Mutated text")
    name.replace("mutated-name")
    call_id.replace("mutated-call")
    parts << build_part(type: :image)
    warnings.first.replace("mutated warning")

    assert_equal "Original text", transcript.entries.first.parts.first.text
    assert_equal "search", transcript.entries.first.parts.last.name
    assert_equal "call-1", transcript.entries.first.parts.last.call_id
    assert_equal 2, transcript.entries.first.parts.length
    assert_equal ["stable warning"], transcript.warnings
  end

  def test_direct_transcript_initializer_copies_and_freezes_warning_strings
    warning = String.new("initial warning")
    transcript = Agent::SessionContext::Transcript.new(
      session: build_session(agent: :codex),
      captured_at: Time.utc(2026, 8, 27, 12, 5, 0),
      entries: [],
      warnings: [warning]
    )

    warning.replace("mutated warning")

    assert_equal ["initial warning"], transcript.warnings
    assert_predicate transcript.warnings, :frozen?
    assert_predicate transcript.warnings.first, :frozen?
  end

  def test_direct_transcript_initializer_rejects_non_transcript_entries
    Agent::SessionContext.const_get(:Transcript)

    error = assert_raises(TypeError) do
      Agent::SessionContext::Transcript.new(
        session: build_session(agent: :codex),
        captured_at: Time.utc(2026, 8, 27, 12, 5, 0),
        entries: [
          build_message(
            role: :user,
            at: Time.utc(2026, 8, 27, 12, 0, 0),
            parts: [build_part(type: :text, text: "not captured")]
          )
        ],
        warnings: []
      )
    end

    assert_match(/TranscriptEntry/, error.message)
  end

  def test_transcript_entry_rejects_non_transcript_parts
    Agent::SessionContext.const_get(:Transcript)

    error = assert_raises(TypeError) do
      Agent::SessionContext::TranscriptEntry.new(
        index: 1,
        role: :user,
        at: Time.utc(2026, 8, 27, 12, 5, 0),
        parts: [build_part(type: :text, text: "upstream part")]
      )
    end

    assert_match(/TranscriptPart/, error.message)
  end

  def test_transcript_part_allows_nil_text_and_copies_non_nil_strings
    Agent::SessionContext.const_get(:Transcript)

    text = String.new("visible text")
    name = String.new("tool name")
    call_id = String.new("tool-call")
    source_ref = Agent::SessionContext::SourceRef.new(session_uid: "codex:session-123", message_index: 1, part_index: 1)

    populated_part = Agent::SessionContext::TranscriptPart.new(
      index: 1,
      type: :text,
      text: text,
      name: name,
      call_id: call_id,
      injected: false,
      source_ref: source_ref
    )
    empty_part = Agent::SessionContext::TranscriptPart.new(
      index: 2,
      type: :image,
      text: nil,
      name: nil,
      call_id: nil,
      injected: false,
      source_ref: Agent::SessionContext::SourceRef.new(session_uid: "codex:session-123", message_index: 1,
                                                       part_index: 2)
    )

    text.replace("mutated text")
    name.replace("mutated name")
    call_id.replace("mutated call")

    assert_equal "visible text", populated_part.text
    assert_equal "tool name", populated_part.name
    assert_equal "tool-call", populated_part.call_id
    assert_nil empty_part.text
    assert_nil empty_part.name
    assert_nil empty_part.call_id
    assert_predicate populated_part.text, :frozen?
    assert_predicate populated_part.name, :frozen?
    assert_predicate populated_part.call_id, :frozen?
  end

  private

  def assert_marker_matrix(agent:, injected_markers:, non_injected_markers:)
    messages = []

    injected_markers.each_with_index do |marker, index|
      messages << build_message(
        role: :user,
        at: Time.utc(2026, 8, 27, 12, index, 0),
        parts: [build_part(type: :text, text: "  #{marker}payload")]
      )
    end

    non_injected_markers.each_with_index do |marker, index|
      messages << build_message(
        role: :user,
        at: Time.utc(2026, 8, 27, 13, index, 0),
        parts: [build_part(type: :text, text: "  #{marker}payload")]
      )
    end

    transcript = Agent::SessionContext::Transcript.capture(
      build_session(agent: agent, id: agent.to_s),
      reader: FakeReader.new(messages, []),
      now: Time.utc(2026, 8, 27, 12, 5, 0)
    )

    assert_equal(
      injected_markers.map { true } + non_injected_markers.map { false },
      transcript.entries.map { |entry| entry.parts.first.injected }
    )
  end

  def build_session(agent:, id: "session-123")
    Agent::Sessions::Session.new(
      agent: agent,
      id: id,
      path: "/tmp/#{id}.jsonl",
      started_at: Time.utc(2026, 8, 27, 11, 0, 0),
      updated_at: Time.utc(2026, 8, 27, 12, 0, 0),
      bytes: 128,
      format: :jsonl,
      fidelity: :full,
      project_path: "/tmp/project"
    )
  end

  def build_message(role:, at:, parts:, raw: {}, usage: nil, model: nil)
    Agent::Sessions::Message.new(role: role, at: at, parts: parts, raw: raw, usage: usage, model: model)
  end

  def build_part(type:, text: nil, name: nil, call_id: nil)
    Agent::Sessions::Part.new(type: type, text: text, name: name, call_id: call_id)
  end
end
