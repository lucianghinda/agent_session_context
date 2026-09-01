# frozen_string_literal: true

require "test_helper"

class PromptExtractorTest < Minitest::Test
  FakeReader = Struct.new(:messages, :warnings) do
    def each_message(&block)
      return enum_for(:each_message) unless block_given?

      messages.each(&block)
    end
  end

  def test_call_keeps_only_user_text_and_preserves_exact_text
    prompts = extract_prompts(
      agent: :codex,
      messages: [
        build_message(role: :assistant, at: Time.utc(2026, 8, 27, 12, 0, 0),
                      parts: [build_part(type: :text, text: "ignored")]),
        build_message(role: :user, at: Time.utc(2026, 8, 27, 12, 1, 0),
                      parts: [build_part(type: :text, text: "Exact\nbytes")]),
        build_message(role: :system, at: Time.utc(2026, 8, 27, 12, 2, 0),
                      parts: [build_part(type: :text, text: "ignored too")])
      ]
    )

    assert_equal 1, prompts.length
    assert_equal "Exact\nbytes", prompts.first.text
    assert_equal Time.utc(2026, 8, 27, 12, 1, 0), prompts.first.at
  end

  def test_call_excludes_user_messages_without_non_injected_text
    prompts = extract_prompts(
      agent: :codex,
      messages: [
        build_message(role: :user, at: Time.utc(2026, 8, 27, 12, 0, 0),
                      parts: [build_part(type: :tool_result, text: "tool only")]),
        build_message(
          role: :user,
          at: Time.utc(2026, 8, 27, 12, 1, 0),
          parts: [build_part(type: :text, text: "<environment_context>meta only")]
        )
      ]
    )

    assert_equal [], prompts
  end

  def test_call_omits_empty_text_prompt_and_starts_later_nonempty_prompt_at_one
    prompts = extract_prompts(
      agent: :codex,
      messages: [
        build_message(role: :user, at: Time.utc(2026, 8, 27, 12, 0, 0), parts: [build_part(type: :text, text: "")]),
        build_message(role: :user, at: Time.utc(2026, 8, 27, 12, 1, 0),
                      parts: [build_part(type: :text, text: "Visible")])
      ]
    )

    assert_equal 1, prompts.length
    assert_equal 1, prompts.first.index
    assert_equal "Visible", prompts.first.text
  end

  def test_call_omits_prompt_when_contributing_text_parts_join_to_empty_string
    prompts = extract_prompts(
      agent: :codex,
      messages: [
        build_message(
          role: :user,
          at: Time.utc(2026, 8, 27, 12, 0, 0),
          parts: [
            build_part(type: :text, text: ""),
            build_part(type: :image),
            build_part(type: :text, text: "")
          ]
        )
      ]
    )

    assert_equal [], prompts
  end

  def test_call_keeps_text_parts_and_ignores_images_without_inserting_separators
    prompts = extract_prompts(
      agent: :codex,
      messages: [
        build_message(
          role: :user,
          at: Time.utc(2026, 8, 27, 12, 0, 0),
          parts: [
            build_part(type: :text, text: "alpha"),
            build_part(type: :image),
            build_part(type: :text, text: "beta")
          ]
        )
      ]
    )

    assert_equal 1, prompts.length
    assert_equal "alphabeta", prompts.first.text
  end

  def test_call_excludes_injected_user_text_and_keeps_only_human_text_from_mixed_messages
    prompts = extract_prompts(
      agent: :codex,
      messages: [
        build_message(
          role: :user,
          at: Time.utc(2026, 8, 27, 12, 0, 0),
          parts: [
            build_part(type: :text, text: "  <environment_context>hidden"),
            build_part(type: :text, text: "Visible")
          ]
        ),
        build_message(
          role: :user,
          at: Time.utc(2026, 8, 27, 12, 1, 0),
          raw: { "isMeta" => true },
          parts: [build_part(type: :text, text: "all injected")]
        )
      ]
    )

    assert_equal 1, prompts.length
    assert_equal "Visible", prompts.first.text
  end

  def test_call_assigns_prompt_ordinals_and_exact_source_refs_for_contributing_parts
    prompts = extract_prompts(
      agent: :claude,
      messages: [
        build_message(
          role: :user,
          at: Time.utc(2026, 8, 27, 12, 0, 0),
          parts: [
            build_part(type: :text, text: "First"),
            build_part(type: :tool_result, text: "ignored")
          ]
        ),
        build_message(
          role: :user,
          at: Time.utc(2026, 8, 27, 12, 1, 0),
          parts: [
            build_part(type: :text, text: "<command-message>hidden"),
            build_part(type: :text, text: "Second")
          ]
        )
      ]
    )

    assert_equal [1, 2], prompts.map(&:index)
    assert_equal %w[First Second], prompts.map(&:text)
    assert_equal(
      [Agent::SessionContext::SourceRef.new(session_uid: "claude:session-123", message_index: 1, part_index: 1)],
      prompts.first.source_refs
    )
    assert_equal(
      [Agent::SessionContext::SourceRef.new(session_uid: "claude:session-123", message_index: 2, part_index: 2)],
      prompts.last.source_refs
    )
    assert_predicate prompts, :frozen?
  end

  private

  def extract_prompts(agent:, messages:)
    session = build_session(agent: agent)
    transcript = Agent::SessionContext::Transcript.capture(
      session,
      reader: FakeReader.new(messages, []),
      now: Time.utc(2026, 8, 27, 12, 5, 0)
    )

    Agent::SessionContext::PromptExtractor.new.call(transcript)
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
