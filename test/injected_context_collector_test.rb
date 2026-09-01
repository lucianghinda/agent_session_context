# frozen_string_literal: true

require "test_helper"

class InjectedContextCollectorTest < Minitest::Test
  Session = Data.define(:agent)

  def setup
    Agent::SessionContext.const_get(:Transcript)
  end

  def test_groups_exact_duplicates_in_first_seen_order_without_text_by_default
    agents_text = "# AGENTS.md instructions\nUse Ruby"
    environment_text = "<environment_context>\n<cwd>/tmp/project</cwd>"
    transcript = transcript_with(
      part(1, agents_text, injected: true),
      part(2, environment_text, injected: true),
      part(3, agents_text, injected: true),
      part(4, "ordinary prompt", injected: false),
      part(5, "opaque provider metadata", injected: true)
    )

    inventory = Agent::SessionContext::InjectedContextCollector.new.call(transcript)

    assert_equal %i[agents_instructions environment_context provider_meta], inventory.map(&:kind)
    assert_equal [agents_text.bytesize, environment_text.bytesize, 24], inventory.map(&:bytes)
    assert_equal [2, 1, 1], inventory.map(&:occurrences)
    assert_equal [[ref(1), ref(3)], [ref(2)], [ref(5)]], inventory.map(&:source_refs)
    assert_equal [nil, nil, nil], inventory.map(&:text)
    assert_predicate inventory, :frozen?
  end

  def test_includes_one_copy_of_each_unique_text_when_requested
    text = "<environment_context>\n<cwd>/tmp/project</cwd>"
    transcript = transcript_with(part(1, text, injected: true), part(2, text, injected: true))

    inventory = Agent::SessionContext::InjectedContextCollector.new.call(transcript, include_text: true)

    assert_equal [text], inventory.map(&:text)
    assert_equal [2], inventory.map(&:occurrences)
  end

  def test_keeps_similar_but_nonidentical_text_in_separate_first_seen_groups
    first_text = "# AGENTS.md instructions\nUse Ruby"
    second_text = "# AGENTS.md instructions\nUse Ruby "
    transcript = transcript_with(
      part(1, first_text, injected: true),
      part(2, second_text, injected: true),
      part(3, first_text, injected: true)
    )

    inventory = Agent::SessionContext::InjectedContextCollector.new.call(transcript, include_text: true)

    assert_equal [first_text, second_text], inventory.map(&:text)
    assert_equal [2, 1], inventory.map(&:occurrences)
    assert_equal [[ref(1), ref(3)], [ref(2)]], inventory.map(&:source_refs)
  end

  def test_collects_malformed_raw_meta_and_marker_text_without_changing_bytes
    raw_meta_text = "\xFFopaque provider metadata".b.force_encoding(Encoding::UTF_8)
    marker_text = " \t<system-reminder>payload\xFF".b.force_encoding(Encoding::UTF_8)
    transcript = transcript_with(
      part(1, raw_meta_text, injected: true),
      part(2, marker_text, injected: true),
      agent: :claude
    )

    inventory = Agent::SessionContext::InjectedContextCollector.new.call(transcript)
    inventory_with_text = Agent::SessionContext::InjectedContextCollector.new.call(transcript, include_text: true)

    assert_equal %i[provider_meta system_reminder], inventory.map(&:kind)
    assert_equal [raw_meta_text.bytesize, marker_text.bytesize], inventory.map(&:bytes)
    assert_equal [nil, nil], inventory.map(&:text)
    assert_equal([raw_meta_text.bytes, marker_text.bytes], inventory_with_text.map { |context| context.text.bytes })
    assert_equal([Encoding::UTF_8, Encoding::UTF_8], inventory_with_text.map { |context| context.text.encoding })
  end

  def test_rejects_injected_parts_without_text_explicitly
    transcript = transcript_with(part(1, nil, injected: true))

    error = assert_raises(TypeError) do
      Agent::SessionContext::InjectedContextCollector.new.call(transcript)
    end

    assert_equal "injected parts must contain text", error.message
  end

  def test_requires_include_text_to_be_literal_boolean
    transcript = transcript_with(part(1, "metadata", injected: true))

    [nil, 0, "false"].each do |value|
      error = assert_raises(ArgumentError) do
        Agent::SessionContext::InjectedContextCollector.new.call(transcript, include_text: value)
      end

      assert_equal "include_text must be true or false", error.message
    end
  end

  private

  def transcript_with(*parts, agent: :codex)
    Agent::SessionContext::Transcript.new(
      session: Session.new(agent:),
      captured_at: Time.utc(2026, 8, 28, 8, 0, 0),
      entries: [
        Agent::SessionContext::TranscriptEntry.new(
          index: 1,
          role: :user,
          at: Time.utc(2026, 8, 28, 7, 59, 0),
          parts:
        )
      ],
      warnings: []
    )
  end

  def part(index, text, injected:)
    Agent::SessionContext::TranscriptPart.new(
      index:,
      type: :text,
      text:,
      injected:,
      source_ref: ref(index)
    )
  end

  def ref(part_index)
    Agent::SessionContext::SourceRef.new(
      session_uid: "codex:session-123",
      message_index: 1,
      part_index:
    )
  end
end
