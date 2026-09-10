# frozen_string_literal: true

require "test_helper"
require_relative "support/claude_fixtures"
require_relative "support/codex_fixtures"

class LoopViewTest < Minitest::Test
  include ClaudeFixtures
  include CodexFixtures

  # A renderer that drops the round-trip count from one format disagrees with
  # the other two about the same underlying Loop — the three outputs describe
  # one object and must not contradict each other on a fact this basic.
  def test_one_session_renders_three_ways
    call = { type: "tool_use", id: "toolu_1", name: "Read", input: { file_path: "/tmp/x" } }
    result = { type: "tool_result", tool_use_id: "toolu_1", content: "file contents" }

    with_session([user_turn("hi"), assistant_parts([call]), user_parts([result]),
                  assistant_turn("done")]) do |reader|
      view = view_for(reader)
      ascii = view.ascii
      markdown = view.markdown
      hash = view.to_h

      refute_empty ascii
      refute_empty markdown
      refute_empty hash

      count = hash.fetch(:round_trips).size
      assert_equal 4, count
      assert_includes ascii, count.to_s
      assert_includes markdown, count.to_s
    end
  end

  # This view infers the ending from the last entry rather than normalizing
  # lifecycle events, so every rendering must label it inferred.
  def test_every_rendering_marks_the_ending_inferred
    call = { type: "tool_use", id: "toolu_1", name: "Read", input: { file_path: "/tmp/x" } }

    with_session([user_turn("read the file"), assistant_parts([call])]) do |reader|
      view = view_for(reader)
      ascii = view.ascii
      markdown = view.markdown
      hash = view.to_h

      assert_includes ascii, "inferred"
      assert_includes ascii, "a tool was asked for and nothing answered it"
      assert_includes markdown, "inferred"
      assert_includes markdown, "a tool was asked for and nothing answered it"
      assert hash.dig(:ending, :inferred)
      assert_equal :stopped_in_the_loop, hash.dig(:ending, :name)
    end
  end

  # Printing local times differs between two zones, and printing the path
  # differs between two homes — both would make one recorded file render
  # differently depending on which machine reads it, which R8 forbids.
  def test_rendering_is_deterministic_and_the_machine_cannot_change_it
    call = { type: "tool_use", id: "toolu_1", name: "Read", input: { file_path: "/tmp/x" } }
    records = [user_turn("hi"), assistant_parts([call])]

    first_ascii = first_markdown = first_hash = nil
    with_session(records) do |reader|
      view = view_for(reader)
      first_ascii = view.ascii
      first_markdown = view.markdown
      first_hash = view.to_h
    end

    original_tz = ENV.fetch("TZ", nil)
    begin
      ENV["TZ"] = "Pacific/Kiritimati" # about as far from UTC as a real zone gets
      with_session(records) do |reader| # a fresh, different throwaway HOME
        view = view_for(reader)
        assert_equal first_ascii, view.ascii
        assert_equal first_markdown, view.markdown
        assert_equal first_hash, view.to_h
      end
    ensure
      ENV["TZ"] = original_tz
    end
  end

  # A preview of the first forty characters would print both the token and
  # the password just as surely as printing the whole body would — the only
  # safe thing to print is a count, never a fragment of the content itself.
  def test_no_body_reaches_the_output
    call = { type: "tool_use", id: "toolu_1", name: "Bash", input: { command: "echo SECRET-TOKEN-123" } }
    result = { type: "tool_result", tool_use_id: "toolu_1", content: "SECRET-TOKEN-123" }
    prompt_text = "my password is hunter2"

    with_session([user_turn(prompt_text), assistant_parts([call]), user_parts([result])]) do |reader|
      view = view_for(reader)
      ascii = view.ascii
      markdown = view.markdown
      hash_dump = view.to_h.inspect

      [ascii, markdown, hash_dump].each do |rendering|
        refute_includes rendering, "SECRET-TOKEN-123"
        refute_includes rendering, "hunter2"
        refute_includes rendering, "password"
      end

      assert_includes ascii, "SECRET-TOKEN-123".bytesize.to_s
      assert_includes ascii, prompt_text.bytesize.to_s
    end
  end

  def test_events_appear_only_when_they_are_asked_for
    event = { type: "attachment", timestamp: STAMP, uuid: "u_event", attachment: { type: "hook_success" } }
    records = [user_turn("hi"), event]

    with_session(records, include_events: true) do |reader|
      assert_includes view_for(reader).ascii, "hook_success"
    end

    with_session(records) do |reader|
      refute_includes view_for(reader).ascii, "hook_success"
    end
  end

  # The label field is a free String, not a controlled vocabulary — R9 must
  # hold even the day a format starts putting a sentence there instead of a
  # short record-type name like hook_success.
  def test_a_free_text_event_label_is_not_printed_as_a_label
    sentence = "this hook's own explanation happens to leak hunter2 right here in its prose"
    event = { type: "attachment", timestamp: STAMP, uuid: "u_event", attachment: { type: sentence } }

    with_session([user_turn("hi"), event], include_events: true) do |reader|
      view = view_for(reader)
      ascii = view.ascii
      markdown = view.markdown
      hash_dump = view.to_h.inspect

      [ascii, markdown, hash_dump].each do |rendering|
        refute_includes rendering, "hunter2"
        refute_includes rendering, sentence
      end
      assert_includes ascii, "unknown" # falls back to the part's type name
    end
  end

  def test_an_unanswered_call_is_shown_as_no_answer_recorded_not_zero_bytes
    call = { type: "tool_use", id: "toolu_9", name: "Bash", input: { command: "ls" } }

    with_session([assistant_parts([call])]) do |reader|
      markdown = view_for(reader).markdown
      assert_includes markdown, "no answer recorded"
      refute_includes markdown, "0 B"
    end
  end

  # Loop#recorded is round_trips.all?(&:recorded), so one assumed group makes
  # the whole session read false — and on Claude, the one format that names its
  # groups, every user and harness turn has no message.id and is assumed by
  # construction. Printing that as the bare word "assumed" would tell a reader
  # Claude records no grouping at all, which is the confusion this gem's
  # standing rule forbids in both directions. So the line carries counts.
  def test_the_grouping_line_says_how_many_groups_the_store_named
    named = assistant_turn("ok")
    named[:message][:id] = "msg_1"

    with_session([user_turn("hi"), named]) do |reader|
      view = view_for(reader)
      assert reader.round_trips_recorded?, "Claude does record a round-trip id"
      assert_includes view.ascii, "1 of 2 named by the store"
      assert_includes view.markdown, "1 of 2 named by the store"
      refute_includes view.ascii, "(grouping: assumed)",
                      "a format that names groups must never read as naming none"
    end
  end

  # The other side of the same line: a session where the store named nothing
  # has to say so in words a reader cannot mistake for "there were none".
  def test_the_grouping_line_says_when_the_store_named_nothing
    with_session([user_turn("hi"), assistant_turn("ok")]) do |reader|
      view = view_for(reader)
      assert_includes view.ascii, "none named by the store"
      assert_includes view.ascii, "one entry per message"
    end
  end

  def test_assumed_entries_do_not_claim_model_round_trips_or_exits
    call = { type: "tool_use", id: "toolu_1", name: "Read", input: {} }
    with_session([user_turn("hi"), assistant_turn("checking"), assistant_parts([call])]) do |reader|
      view = view_for(reader)
      assert_includes view.ascii, "entries: 3"
      assert_includes view.ascii, "model entries: 2"
      assert_includes view.ascii, "== message ==>"
      assert_includes view.ascii, "no tool request in this record"
      assert_includes view.ascii, "tool request recorded"
      refute_includes view.ascii, "no tool_use: exit"
      assert_includes view.markdown, "entries: 3"
      assert_includes view.markdown, "model entries: 2"
    end
  end

  def test_standalone_views_keep_warnings_by_default
    with_session([user_parts([{ type: "tool_result", tool_use_id: "orphan", content: "x" }])]) do |reader|
      view = view_for(reader)
      assert_includes view.ascii, "tool result orphan answers no call"
      assert_includes view.markdown, "tool result orphan answers no call"
    end
  end

  def test_codex_reasoning_without_a_summary_is_visible_without_leaking_content
    record = codex_reasoning
    record[:payload][:encrypted_content] = "PRIVATE-REASONING"
    with_codex_session([record]) do |reader|
      view = view_for(reader)
      [view.ascii, view.markdown].each do |rendering|
        assert_includes rendering, "reasoning (no readable summary recorded)"
        refute_includes rendering, "PRIVATE-REASONING"
      end
      refute_includes view.to_h.inspect, "PRIVATE-REASONING"
    end
  end

  private

  def view_for(reader) = Agent::SessionContext::LoopView.new(Agent::SessionContext::Loop.for(reader))
end
