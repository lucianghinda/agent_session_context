# frozen_string_literal: true

require "test_helper"
require_relative "support/claude_fixtures"
require_relative "support/codex_fixtures"

class LoopTest < Minitest::Test
  include ClaudeFixtures
  include CodexFixtures

  # Pairing must go by call id: two calls can be in flight at once, and
  # pairing by position would match the wrong call to the wrong result.
  def test_a_call_is_paired_with_the_result_that_answered_it
    call = { type: "tool_use", id: "toolu_1", name: "Read", input: { file_path: "/tmp/x" } }
    result = { type: "tool_result", tool_use_id: "toolu_1", content: "file contents" }

    with_session([assistant_parts([call]), user_parts([result])]) do |reader|
      loop = Agent::SessionContext::Loop.for(reader)

      assert_equal 1, loop.tool_calls.size
      tool_call = loop.tool_calls.first
      assert_equal "Read", tool_call.name
      assert_equal "toolu_1", tool_call.call_id
      assert tool_call.answered?
      assert_equal "file contents".bytesize, tool_call.result_bytes
      assert_operator tool_call.answered_in, :>, tool_call.asked_in
    end
  end

  # A call nothing answered must report NO result, never a 0-byte one — 0 would
  # claim an empty answer was recorded when nothing was recorded at all.
  def test_a_call_nothing_answered_reports_no_result_rather_than_an_empty_one
    call = { type: "tool_use", id: "toolu_9", name: "Bash", input: { command: "ls" } }

    with_session([assistant_parts([call])]) do |reader|
      loop = Agent::SessionContext::Loop.for(reader)
      tool_call = loop.tool_calls.first

      refute tool_call.answered?
      assert_nil tool_call.result_bytes
      assert_nil tool_call.answered_in
    end
  end

  def test_a_result_answering_no_call_is_reported_and_rendered_nowhere
    result = { type: "tool_result", tool_use_id: "toolu_x", content: "orphan" }

    with_session([user_parts([result])]) do |reader|
      loop = Agent::SessionContext::Loop.for(reader)

      assert_empty loop.tool_calls
      assert(loop.warnings.any? { |w| w.include?("toolu_x") })
    end
  end

  def test_the_ending_says_the_session_stopped_inside_the_loop
    call = { type: "tool_use", id: "toolu_1", name: "Read", input: { file_path: "/tmp/x" } }
    with_session([user_turn("read the file"), assistant_parts([call])]) do |reader|
      loop = Agent::SessionContext::Loop.for(reader)

      assert_equal :stopped_in_the_loop, loop.ending
      assert loop.ending_inferred?
      assert_equal "a tool was asked for and nothing answered it", loop.ending_detail
    end
  end

  def test_the_ending_says_the_model_answered
    with_session([user_turn("hi"), assistant_turn("hello there")]) do |reader|
      loop = Agent::SessionContext::Loop.for(reader)

      assert_equal :answered, loop.ending
      assert_equal "the model answered without asking for a tool", loop.ending_detail
    end
  end

  def test_the_ending_describes_the_last_record_without_claiming_the_session_stopped
    with_session([assistant_turn("hello there"), user_turn("thanks")]) do |reader|
      loop = Agent::SessionContext::Loop.for(reader)

      assert_equal :not_a_model_record, loop.ending
      assert_equal "the last recorded entry is not an assistant answer", loop.ending_detail
    end
  end

  def test_codex_commentary_and_reasoning_are_incomplete
    [codex_message("Working on it", phase: "commentary"), codex_reasoning,
     codex_reasoning(summary: [{ type: "summary_text", text: "Considering options" }])].each do |record|
      with_codex_session([record]) do |reader|
        loop = Agent::SessionContext::Loop.for(reader)

        assert_equal :incomplete, loop.ending
        assert loop.ending_inferred?
        assert_equal "the last assistant record is commentary or reasoning, not a final answer", loop.ending_detail
      end
    end
  end

  def test_codex_final_answer_and_legacy_messages_remain_inferred_answers
    [codex_message("Done", phase: "final_answer"), codex_message("Legacy answer")].each do |record|
      with_codex_session([codex_reasoning, record]) do |reader|
        loop = Agent::SessionContext::Loop.for(reader)

        assert_equal :answered, loop.ending
        assert loop.ending_inferred?
      end
    end
  end

  def test_codex_non_assistant_tails_remain_not_a_model_record
    [codex_tool_result, codex_message("Thanks", role: "user"),
     codex_record({ type: "future_record" })].each do |record|
      with_codex_session([codex_tool_call, record]) do |reader|
        loop = Agent::SessionContext::Loop.for(reader)

        assert_equal :not_a_model_record, loop.ending
        assert loop.ending_inferred?
      end
    end
  end

  def test_codex_tool_call_ending_is_unchanged
    with_codex_session([codex_tool_call]) do |reader|
      assert_equal :stopped_in_the_loop, Agent::SessionContext::Loop.for(reader).ending
    end
  end

  def test_codex_ending_guards_raw_shapes_and_other_agents
    with_codex_session([codex_message("Legacy answer")]) do |reader|
      trip = reader.round_trips.last
      [nil, [], "raw", {}, { "type" => "response_item", "payload" => [] },
       { "type" => "other", "payload" => { "type" => "reasoning" } }].each do |raw|
        modified = trip.with(messages: [trip.messages.last.with(raw: raw)])
        snapshot = Struct.new(:session, :round_trips, :warnings).new(reader.session, [modified], [])

        assert_equal :answered, Agent::SessionContext::Loop.for(snapshot).ending
      end
    end

    with_session([assistant_turn("Claude answer")]) do |reader|
      trip = reader.round_trips.last
      raw = { "type" => "response_item", "payload" => { "type" => "reasoning" } }
      modified = trip.with(messages: [trip.messages.last.with(raw: raw)])
      snapshot = Struct.new(:session, :round_trips, :warnings).new(reader.session, [modified], [])

      assert_equal :answered, Agent::SessionContext::Loop.for(snapshot).ending
    end
  end

  def test_a_broken_store_renders_empty_and_warns
    conformance_broken do |reader|
      loop = Agent::SessionContext::Loop.for(reader)

      assert_empty loop.round_trips
      assert_equal :empty, loop.ending
      refute loop.recorded
      refute_empty loop.warnings
    end
  end

  # Choosing the speaker from the first part alone would call this a person's
  # prompt, because Claude files a tool result as a `user` message. This shape
  # was NOT observed in the real corpus — 0 of 3,933 real user records with
  # array content mix a tool_result with another part type (measured
  # 2026-09-09) — so it is specified as reported-but-not-observed, not an
  # ordinary case.
  def test_a_record_mixing_a_tool_result_with_other_parts_is_harness_output_and_is_reported
    mixed = [{ type: "tool_result", tool_use_id: "toolu_1", content: "file contents" },
             { type: "text", text: "here you go" }]

    with_session([user_parts(mixed)]) do |reader|
      loop = Agent::SessionContext::Loop.for(reader)
      round_trip = loop.round_trips.first

      assert_equal :harness, loop.speakers[round_trip.index]
      assert(loop.warnings.any? { |w| w.include?("round trip #{round_trip.index}") })
    end
  end

  # Pins T1 rows 2 and 3, the distinction the whole table exists for: a plain
  # prompt is a person, and a message carrying only a tool result is the
  # harness, even though both are filed under the `user` role.
  def test_the_speaker_is_read_from_the_parts_not_the_role
    result = { type: "tool_result", tool_use_id: "toolu_1", content: "file contents" }

    with_session([user_turn("hello"), user_parts([result])]) do |reader|
      loop = Agent::SessionContext::Loop.for(reader)
      prompt_round_trip, result_round_trip = loop.round_trips

      assert_equal :person, loop.speakers[prompt_round_trip.index]
      assert_equal :harness, loop.speakers[result_round_trip.index]
    end
  end

  def test_an_empty_session_is_not_marked_recorded
    with_home do |home, env|
      write("", home, ".claude", "projects", PROJECT, "#{SESSION}.jsonl")
      loop = Agent::SessionContext::Loop.for(read_session(env))

      assert_equal :empty, loop.ending
      refute loop.recorded
    end
  end

  private

  def conformance_broken
    with_home do |home, env|
      write("not json at all\n", home, ".claude", "projects", PROJECT, "#{SESSION}.jsonl")
      yield read_session(env)
    end
  end
end
