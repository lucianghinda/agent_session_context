# frozen_string_literal: true

require "test_helper"

class EvidencePacketTest < Minitest::Test
  StringLikeRef = Data.define(:value) do
    def to_s = value
  end

  def setup
    Agent::SessionContext.const_get(:Transcript)
  end

  def test_public_contract_exposes_max_bytes_and_result_members
    assert_equal 65_536, Agent::SessionContext::EvidencePacket::MAX_BYTES
    assert_equal %i[chunks warnings source_refs], Agent::SessionContext::EvidencePacket::Result.members
    assert_equal [%i[keyreq transcript], %i[keyreq observed]], Agent::SessionContext::EvidencePacket.instance_method(:call).parameters
  end

  def test_call_serializes_transcript_lines_before_observed_items_and_skips_excluded_parts
    transcript = transcript(
      [
        entry(
          index: 1,
          role: :user,
          parts: [
            text_part("Need a grounded summary"),
            plain_part(type: :thinking, text: "private chain of thought"),
            plain_part(type: :text, text: "<environment_context>\nSECRET=1", injected: true)
          ]
        ),
        entry(
          index: 2,
          role: :assistant,
          parts: [
            tool_use_part(index: 1, name: "Read", input: %({"path":"README.md"})),
            plain_part(type: :tool_result, text: "README contents", entry_index: 2, part_index: 2),
            plain_part(type: :image, text: "binary", entry_index: 2, part_index: 3),
            text_part("I checked the readme", entry_index: 2, part_index: 4)
          ]
        ),
        entry(
          index: 3,
          role: :system,
          parts: [
            text_part("System guidance", entry_index: 3)
          ]
        )
      ]
    )

    file_item = observed_item(kind: :file, label: "README.md", refs: [ref(2, 1)], attributes: { action: :read })
    document_item = observed_item(kind: :file, label: "docs/guide.md", refs: [ref(2, 1)], attributes: { action: :read })

    result = packet.call(
      transcript: transcript,
      observed: observed_result(
        files: [file_item, document_item]
      )
    )

    assert_equal 1, result.chunks.length
    assert_equal [], result.warnings
    assert_equal [ref(1, 1), ref(2, 1), ref(2, 4), ref(3, 1)], result.source_refs

    lines = result.chunks.first.split("\n")

    assert_equal([
                   [ref(1, 1).to_s, { "kind" => "message", "role" => "user", "text" => "Need a grounded summary" }],
                   [ref(2, 1).to_s,
                    { "kind" => "tool_use", "role" => "assistant", "name" => "Read",
                      "input" => %({"path":"README.md"}) }],
                   [ref(2, 4).to_s, { "kind" => "message", "role" => "assistant", "text" => "I checked the readme" }],
                   [ref(3, 1).to_s, { "kind" => "message", "role" => "system", "text" => "System guidance" }],
                   [ref(2, 1).to_s,
                    { "kind" => "observed", "classifications" => %w[document file], "label" => "README.md",
                      "action" => "read" }],
                   [ref(2, 1).to_s,
                    { "kind" => "observed", "classifications" => %w[document file], "label" => "docs/guide.md",
                      "action" => "read" }]
                 ], lines.map { |line| decode_line(line) })

    refute_match(/private chain of thought/, result.chunks.first)
    refute_match(/README contents/, result.chunks.first)
    refute_match(/SECRET=1/, result.chunks.first)
    refute_match(/binary/, result.chunks.first)
  end

  def test_call_keeps_fitting_lines_whole_at_exact_chunk_boundary
    first = text_part("alpha")
    first_line = expected_line(first.source_ref, "kind" => "message", "role" => "user", "text" => "alpha")
    second_ref = ref(1, 2)
    second_bytes = Agent::SessionContext::EvidencePacket::MAX_BYTES - first_line.bytesize - 1
    second_text = "b" * (second_bytes - empty_message_line_bytes(second_ref))
    second = text_part(second_text, part_index: 2)

    result = packet.call(
      transcript: transcript_with_parts(role: :user, parts: [first, second]),
      observed: observed_result
    )

    assert_equal 1, result.chunks.length
    assert_equal Agent::SessionContext::EvidencePacket::MAX_BYTES, result.chunks.first.bytesize
    expected_lines = [
      first_line,
      expected_line(second.source_ref, "kind" => "message", "role" => "user", "text" => second_text)
    ]
    assert_equal expected_lines.join("\n"), result.chunks.first
  end

  def test_call_starts_new_chunk_instead_of_splitting_a_fitting_line
    first_text = "a" * (Agent::SessionContext::EvidencePacket::MAX_BYTES - empty_message_line_bytes(ref(1, 1)))
    second_text = "z"
    first = text_part(first_text)
    second = text_part(second_text, part_index: 2)

    result = packet.call(
      transcript: transcript_with_parts(role: :user, parts: [first, second]),
      observed: observed_result
    )

    assert_equal 2, result.chunks.length
    assert_equal expected_line(first.source_ref, "kind" => "message", "role" => "user", "text" => first_text),
                 result.chunks[0]
    assert_equal expected_line(second.source_ref, "kind" => "message", "role" => "user", "text" => second_text),
                 result.chunks[1]
    assert_operator result.chunks[0].bytesize, :<=, Agent::SessionContext::EvidencePacket::MAX_BYTES
    assert_operator result.chunks[1].bytesize, :<=, Agent::SessionContext::EvidencePacket::MAX_BYTES
  end

  def test_call_truncates_oversized_utf8_lines_on_a_valid_boundary_and_warns
    text = "🙂" * Agent::SessionContext::EvidencePacket::MAX_BYTES
    oversized = text_part(text)

    result = packet.call(
      transcript: transcript_with_parts(role: :user, parts: [oversized]),
      observed: observed_result
    )

    assert_equal 1, result.chunks.length
    assert_equal 1, result.warnings.length
    assert_match(/truncated/i, result.warnings.first)
    assert_match(/\A#{Regexp.escape(oversized.source_ref.to_s)} /, result.chunks.first)
    assert_operator result.chunks.first.bytesize, :<=, Agent::SessionContext::EvidencePacket::MAX_BYTES
    assert_predicate result.chunks.first, :valid_encoding?
  end

  def test_call_truncates_oversized_lines_without_breaking_json_for_multibyte_and_escape_heavy_text
    text = %(line 1 "quoted"\nline 2 \\ slash 🙂 ) * 10_000
    oversized = text_part(text)

    result = packet.call(
      transcript: transcript_with_parts(role: :user, parts: [oversized]),
      observed: observed_result
    )

    assert_equal 1, result.chunks.length
    assert_equal 1, result.warnings.length
    prefix, payload = split_line(result.chunks.first)

    assert_equal oversized.source_ref.to_s, prefix
    assert_operator result.chunks.first.bytesize, :<=, Agent::SessionContext::EvidencePacket::MAX_BYTES
    assert_equal(
      {
        "kind" => "message",
        "role" => "user",
        "text" => JSON.parse(payload).fetch("text")
      },
      JSON.parse(payload)
    )
    assert_predicate JSON.parse(payload).fetch("text"), :valid_encoding?
  end

  def test_call_emits_observed_evidence_for_every_carried_source_ref
    shared_item = observed_item(
      kind: :file,
      label: "README.md",
      refs: [ref(2, 1), ref(2, 2)],
      attributes: { action: :read }
    )

    result = packet.call(
      transcript: transcript_with_parts(role: :assistant,
                                        parts: [tool_use_part(index: 1,
                                                              name: "Read",
                                                              input: %({"path":"README.md"}),
                                                              entry_index: 2)]),
      observed: observed_result(files: [shared_item])
    )

    lines = result.chunks.join("\n").split("\n")
    observed_lines = lines.select { |line| JSON.parse(split_line(line).last).fetch("kind") == "observed" }

    assert_equal [ref(2, 1), ref(2, 2)], result.source_refs
    assert_equal([ref(2, 1).to_s, ref(2, 2).to_s], observed_lines.map { |line| split_line(line).first })
    assert_equal 2, observed_lines.length
    assert_equal([
                   { "kind" => "observed", "classifications" => %w[document file], "label" => "README.md",
                     "action" => "read" },
                   { "kind" => "observed", "classifications" => %w[document file], "label" => "README.md",
                     "action" => "read" }
                 ], observed_lines.map { |line| JSON.parse(split_line(line).last) })
  end

  def test_call_raises_when_prefix_and_fixed_payload_overhead_cannot_fit
    long_session_uid = "s" * Agent::SessionContext::EvidencePacket::MAX_BYTES
    impossible_ref = Agent::SessionContext::SourceRef.new(session_uid: long_session_uid, message_index: 1,
                                                          part_index: 1)
    impossible_part = Agent::SessionContext::TranscriptPart.new(
      index: 1,
      type: :text,
      text: "",
      name: nil,
      call_id: nil,
      injected: false,
      source_ref: impossible_ref
    )

    error = assert_raises(ArgumentError) do
      packet.call(
        transcript: transcript(
          [entry(index: 1, role: :user, parts: [impossible_part], session_uid: long_session_uid)]
        ),
        observed: observed_result
      )
    end

    assert_match(/cannot fit/i, error.message)
    assert_match(/source ref/i, error.message)
  end

  def test_call_is_stateless_across_multiple_calls_on_the_same_instance
    first = packet.call(
      transcript: transcript_with_parts(role: :user, parts: [text_part("first request")]),
      observed: observed_result(files: [observed_item(kind: :file, label: "README.md", refs: [ref(1, 1)],
                                                      attributes: { action: :read })])
    )

    second = packet.call(
      transcript: transcript_with_parts(role: :assistant, parts: [text_part("second response")]),
      observed: observed_result
    )

    assert_match(/first request/, first.chunks.join("\n"))
    refute_match(/README.md/, second.chunks.join("\n"))
    refute_match(/first request/, second.chunks.join("\n"))
    assert_match(/second response/, second.chunks.join("\n"))
  end

  def test_call_supports_keyword_invocation_in_integration_shape
    result = packet.call(
      transcript: transcript_with_parts(role: :user, parts: [text_part("integrate me")]),
      observed: observed_result
    )

    assert_equal 1, result.chunks.length
    assert_match(/integrate me/, result.chunks.first)
  end

  def test_result_source_refs_for_returns_only_refs_represented_by_each_chunk
    chunk_one_text = "a" * (Agent::SessionContext::EvidencePacket::MAX_BYTES - empty_message_line_bytes(ref(1, 1)))
    chunk_two_text = "b"
    result = packet.call(
      transcript: transcript_with_parts(
        role: :user,
        parts: [
          text_part(chunk_one_text, entry_index: 1, part_index: 1),
          text_part(chunk_two_text, entry_index: 1, part_index: 2)
        ]
      ),
      observed: observed_result
    )

    assert_equal 2, result.chunks.length
    assert_equal [ref(1, 1)], result.source_refs_for(result.chunks[0])
    assert_equal [ref(1, 2)], result.source_refs_for(result.chunks[1])
    assert_predicate result.source_refs_for(result.chunks[0]), :frozen?
    assert_predicate result.source_refs_for(result.chunks[1]), :frozen?
    assert_equal [ref(1, 1), ref(1, 2)], result.source_refs
  end

  def test_result_source_refs_for_enforces_per_chunk_grounding_for_parser
    chunk_one_text = "a" * (Agent::SessionContext::EvidencePacket::MAX_BYTES - empty_message_line_bytes(ref(1, 1)))
    result = packet.call(
      transcript: transcript_with_parts(
        role: :user,
        parts: [
          text_part(chunk_one_text, entry_index: 1, part_index: 1),
          text_part("second chunk", entry_index: 1, part_index: 2)
        ]
      ),
      observed: observed_result
    )

    summary = full_payload(
      "goals" => [{ "text" => "Illicit citation", "evidence" => "explicit", "source_refs" => [ref(1, 2).to_s] }]
    )

    parsed = Agent::SessionContext::SummaryParser.new.call(
      JSON.generate(summary),
      allowed_refs: result.source_refs_for(result.chunks[0])
    )

    assert_equal [], parsed.items
    assert_equal 1, parsed.warnings.length
    assert_match(/unknown source ref/i, parsed.warnings.first)
  end

  def test_call_rejects_source_refs_with_spaces_tabs_or_newlines_in_canonical_text
    ["bad uid", "bad\tuid", "bad\nuid"].each do |session_uid|
      error = assert_raises(ArgumentError) do
        packet.call(
          transcript: transcript_with_parts(role: :user,
                                            parts: [text_part("unsafe", entry_index: 1, part_index: 1,
                                                                        session_uid:)],
                                            session_uid:),
          observed: observed_result
        )
      end

      assert_match(/source ref/i, error.message)
    end
  end

  def test_call_rejects_source_refs_with_invalid_utf8_and_accepts_valid_unicode_without_spaces
    invalid_session_uid = String.new("bad\xFF".b, encoding: Encoding::UTF_8)

    error = assert_raises(ArgumentError) do
      packet.call(
        transcript: transcript_with_parts(role: :user, parts: [text_part("unsafe", session_uid: invalid_session_uid)],
                                          session_uid: invalid_session_uid),
        observed: observed_result
      )
    end

    assert_match(/utf-8/i, error.message)

    valid_session_uid = "codex:zăpadă-☃"
    result = packet.call(
      transcript: transcript_with_parts(role: :user, parts: [text_part("safe", session_uid: valid_session_uid)],
                                        session_uid: valid_session_uid),
      observed: observed_result
    )

    assert_equal [ref(1, 1, session_uid: valid_session_uid)], result.source_refs
    assert_match(%r{\Acodex:zăpadă-☃/message:000001/part:000001 }, result.chunks.first)
  end

  def test_call_rejects_binary_and_latin1_non_ascii_source_refs_without_encoding_errors
    invalid_binary_session_uid = "codex:\xFF".b
    latin1_session_uid = String.new("codex:\xE9".b, encoding: Encoding::ISO_8859_1)

    [invalid_binary_session_uid, latin1_session_uid].each do |session_uid|
      error = assert_raises(ArgumentError) do
        packet.call(
          transcript: transcript_with_parts(role: :user, parts: [text_part("unsafe", session_uid: session_uid)],
                                            session_uid: session_uid),
          observed: observed_result
        )
      end

      assert_match(/utf-8|ascii/i, error.message)
    end
  end

  def test_call_accepts_ascii_only_source_refs_from_non_utf8_encodings
    ascii_binary_session_uid = "codex:ascii-only".b
    ascii_latin1_session_uid = String.new("codex:latin1-ascii".b, encoding: Encoding::ISO_8859_1)

    [ascii_binary_session_uid, ascii_latin1_session_uid].each do |session_uid|
      result = packet.call(
        transcript: transcript_with_parts(role: :user, parts: [text_part("safe", session_uid: session_uid)],
                                          session_uid: session_uid),
        observed: observed_result
      )

      assert_equal [ref(1, 1, session_uid: session_uid)], result.source_refs
      assert_match(/\Acodex:/, result.chunks.first)
      assert_predicate result.chunks.first, :valid_encoding?
    end
  end

  def test_safe_ref_text_rejects_non_ascii_bytes_from_binary_and_latin1
    invalid_binary_ref = StringLikeRef.new(value: "codex:\xFF/message:000001/part:000001".b)
    latin1_ref = StringLikeRef.new(
      value: String.new("codex:\xE9/message:000001/part:000001".b, encoding: Encoding::ISO_8859_1)
    )

    [invalid_binary_ref, latin1_ref].each do |source_ref|
      error = assert_raises(ArgumentError) { Agent::SessionContext::EvidencePacket.safe_ref_text(source_ref) }

      assert_match(/utf-8|ascii/i, error.message)
    end
  end

  def test_safe_ref_text_rejects_invalid_utf8_bytes_and_accepts_utf8_or_ascii_only_alternate_encodings
    invalid_utf8_ref = StringLikeRef.new(
      value: String.new("codex:\xFF/message:000001/part:000001".b, encoding: Encoding::UTF_8)
    )
    ascii_binary_ref = StringLikeRef.new(value: "codex:ascii/message:000001/part:000001".b)
    ascii_latin1_ref = StringLikeRef.new(
      value: String.new("codex:latin/message:000001/part:000001".b, encoding: Encoding::ISO_8859_1)
    )
    utf8_ref = StringLikeRef.new(value: "codex:zăpadă/message:000001/part:000001")
    utf8_binary_ref = StringLikeRef.new(value: "codex:z\xC4\x83pad\xC4\x83/message:000001/part:000001".b)
    utf8_latin1_tagged_ref = StringLikeRef.new(
      value: String.new(
        "codex:z\xC4\x83pad\xC4\x83/message:000001/part:000001".b,
        encoding: Encoding::ISO_8859_1
      )
    )

    error = assert_raises(ArgumentError) { Agent::SessionContext::EvidencePacket.safe_ref_text(invalid_utf8_ref) }
    assert_match(/utf-8/i, error.message)
    refute_match(/#<struct/i, error.message)
    refute_match(/\\xFF/, error.message)

    assert_equal "codex:ascii/message:000001/part:000001", Agent::SessionContext::EvidencePacket.safe_ref_text(ascii_binary_ref)
    assert_equal "codex:latin/message:000001/part:000001", Agent::SessionContext::EvidencePacket.safe_ref_text(ascii_latin1_ref)
    assert_equal "codex:zăpadă/message:000001/part:000001", Agent::SessionContext::EvidencePacket.safe_ref_text(utf8_ref)
    assert_equal "codex:zăpadă/message:000001/part:000001", Agent::SessionContext::EvidencePacket.safe_ref_text(utf8_binary_ref)
    assert_equal "codex:zăpadă/message:000001/part:000001", Agent::SessionContext::EvidencePacket.safe_ref_text(utf8_latin1_tagged_ref)
  end

  private

  def packet
    @packet ||= Agent::SessionContext::EvidencePacket.new
  end

  def decode_line(line)
    prefix, json = line.split(" ", 2)
    [prefix, JSON.parse(json)]
  end

  def split_line(line)
    line.split(" ", 2)
  end

  def expected_line(source_ref, payload)
    "#{source_ref} #{JSON.generate(payload)}"
  end

  def empty_message_line_bytes(source_ref)
    expected_line(source_ref, "kind" => "message", "role" => "user", "text" => "").bytesize
  end

  def observed_result(files: [], tool_activity: [])
    Agent::SessionContext::EvidenceCollector::Result.new(
      files: files.freeze,
      tool_activity: tool_activity.freeze
    )
  end

  def observed_item(kind:, label:, refs:, attributes: {})
    Agent::SessionContext::Item.new(
      kind: kind,
      label: label,
      evidence: :observed,
      source_refs: refs,
      attributes: attributes
    )
  end

  def transcript(entries, session_uid: "codex:session-123")
    session = Struct.new(:uid).new(session_uid)
    Agent::SessionContext::Transcript.new(
      session: session,
      captured_at: Time.utc(2026, 8, 27, 12, 0, 0),
      entries: entries,
      warnings: []
    )
  end

  def transcript_with_parts(role:, parts:, session_uid: "codex:session-123")
    transcript([entry(index: 1, role: role, parts: parts, session_uid: session_uid)], session_uid: session_uid)
  end

  def entry(index:, role:, parts:, session_uid: "codex:session-123")
    parts = parts.each_with_index.map do |part, offset|
      next part if part.source_ref.session_uid == session_uid

      part.with(source_ref: ref(index, offset + 1, session_uid: session_uid))
    end

    Agent::SessionContext::TranscriptEntry.new(index: index, role: role, at: Time.utc(2026, 8, 27, 12, index, 0),
                                               parts: parts)
  end

  def text_part(text, entry_index: 1, part_index: 1, session_uid: "codex:session-123")
    plain_part(type: :text, text: text, entry_index: entry_index, part_index: part_index, session_uid: session_uid)
  end

  def tool_use_part(name:, input:, index: 1, entry_index: 2, session_uid: "codex:session-123")
    Agent::SessionContext::TranscriptPart.new(
      index: index,
      type: :tool_use,
      text: input,
      name: name,
      call_id: "call-#{entry_index}-#{index}",
      injected: false,
      source_ref: ref(entry_index, index, session_uid: session_uid)
    )
  end

  def plain_part(type:, text:, entry_index: 1, part_index: 1, injected: false, session_uid: "codex:session-123")
    Agent::SessionContext::TranscriptPart.new(
      index: part_index,
      type: type,
      text: text,
      name: nil,
      call_id: nil,
      injected: injected,
      source_ref: ref(entry_index, part_index, session_uid: session_uid)
    )
  end

  def ref(message_index, part_index, session_uid: "codex:session-123")
    Agent::SessionContext::SourceRef.new(
      session_uid: session_uid,
      message_index: message_index,
      part_index: part_index
    )
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
end
