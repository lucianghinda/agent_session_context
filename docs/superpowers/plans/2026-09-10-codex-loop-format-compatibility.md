# Codex Loop Format Compatibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-ruby:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Recognize Codex token-usage metadata, remove duplicate CLI diagnostics, and stop presenting individual Codex records as proven model round trips or exits.

**Architecture:** Fix format recognition in the existing `agent_sessions` reader dependency. Keep loop presentation and completion inference in `agent_session_context`. Preserve unknown-record warnings for genuinely unsupported types, existing call-ID pairing, and the public JSON grouping structure. Do not infer response membership from adjacency or a user-turn identifier.

**Tech Stack:** Ruby, existing Minitest and RuboCop tooling; no new dependencies.

## Implementation status — 2026-09-10

The upstream work shipped as `agent_sessions` 0.4.1. Consumer changes are implemented
on `fix/codex-loop-compatibility`, requiring `~> 0.4, >= 0.4.1`.
The CLI renders a copy of the immutable Loop with empty warnings for human formats;
this avoids adding warning options to public renderers and preserves standalone/JSON warnings.
The development lockfile is ignored by Git and has been refreshed locally.
All 355 tests passed (2,771 assertions). A frozen original-session snapshot against the
installed 0.4.1 gem verified 87 entries, all 31 tool pairs, zero warnings and CLI status 0.
Publication and installation of the updated `agent_session_context` are outside this implementation.

## Investigation and evidence

The installed `agent_sessions` 0.4.0 reader and sibling checkout both omit `token_usage_record` from `Readers::Codex::NON_MESSAGE_TYPES`. `message_for` therefore emits a warning and an unknown message. `Readers::Base#each_round_trip` gives each such message an assumed round trip. `LoopView` displays it as an unrecognized record.

A temporary snapshot ending at the final tool result in the reported output (source line 212) reproduces exactly:

| Measurement | Existing reader | Temporary subclass skipping usage records |
| --- | --- | --- |
| Entries | 119 | 87 |
| Reader warnings | 32 | 0 |
| Tool calls | 31 | 31 |
| Ending | `not_a_model_record` | `not_a_model_record` |

The original snapshot ends on a tool result, so its ending is independent of the metadata warnings. The live source continued growing during investigation; use deterministic fixtures for tests, not live-file counts.

The new record payload contains `usage`, `turn_token_usage`, and `thread_token_usage`, plus response/turn/thread identifiers. Legacy `event_msg/token_count` records coexist in this file and already provide session usage through the current reader. Do not sum both representations.

Nine assistant reasoning records in the original snapshot have empty summaries. `reasoning_message` produces no visible parts; `LoopView#ascii_model` nevertheless prints `no tool_use: exit`. Assistant messages in this local file use `payload.phase` values `commentary` and `final_answer`; their `channel` is absent. The reader preserves those fields in `Message#raw`.

The source also contains `task_started`, `task_complete`, and `turn_aborted` events. Existing comments claiming no on-disk format records completion are too broad. A task completion event is still not proof that an entire session can never resume.

`CLI#loop_command` emits every warning to stderr, then `LoopView#ascii` or `#markdown` repeats it in stdout. Warnings also cause exit status 1.

`SessionResolver#current` deliberately falls back to the latest `updated_at` across supported agents when its supported environment identifiers are absent. The fallback warning in this report is expected behavior, documented and tested. It does not prove that the selected session belongs to the invoking terminal.

Baseline verification: `bundle exec rake test` passed with 344 runs, 2,670 assertions, zero failures/errors/skips, using `/Users/luciang/.rubies/ruby-4.0.1/bin/ruby`. The default tool shell selected system Ruby 2.6; explicitly selecting the matching Ruby resolved the diagnostic environment issue.

## Task 1: Recognize token-usage bookkeeping upstream

**Files in sibling `agent_sessions/gems/agent_sessions`:**
- Modify: `lib/agent/sessions/readers/codex.rb`
- Test: `test/codex_reader_test.rb`
- Modify: `CHANGELOG.md`

- [ ] Add a reader regression using the existing `with_session` and `assistant_message` helpers:

```ruby
def test_token_usage_records_are_not_conversation_or_warnings
  record = {
    type: "token_usage_record", timestamp: STAMP,
    payload: {
      thread_id: UUID, session_id: UUID, turn_id: "turn_1",
      root_turn_id: "turn_1", response_id: "response_1",
      usage: { input_tokens: 100, cached_input_tokens: 40, output_tokens: 5 },
      turn_token_usage: { input_tokens: 100, cached_input_tokens: 40, output_tokens: 5 },
      thread_token_usage: { input_tokens: 100, cached_input_tokens: 40, output_tokens: 5 }
    }
  }
  [false, true].each do |include_events|
    with_session([assistant_message("done"), record], include_events:) do |reader|
      assert_equal [:assistant], reader.messages.map(&:role)
      assert_equal 1, reader.round_trips.size
      assert_empty reader.warnings
    end
  end
end
```

- [ ] Run `bundle exec ruby -Itest test/codex_reader_test.rb`; verify the new regression fails on message count/warnings.
- [ ] Add `token_usage_record` to `NON_MESSAGE_TYPES`. Keep its raw source on disk; it is not a normalized conversation message. Update the constant's explanation to mention token accounting.
- [ ] Run the reader suite again. Keep existing unknown-payload, encrypted-content, streaming, and legacy-usage tests passing. Add a top-level future-type regression to ensure the new classification does not suppress all unknown records.
- [ ] Record the compatibility fix in the dependency changelog. This small change is independently shippable and directly removes the reported warning flood.

## Task 2: Read session totals from either accounting representation

**Files in sibling `agent_sessions/gems/agent_sessions`:**
- Modify: `lib/agent/sessions/readers/codex.rb`
- Test: `test/codex_reader_test.rb`

- [ ] Add fixtures for new-only accounting, legacy-only accounting, and both formats interleaved. Use successive cumulative totals of input 100/cached 40/output 5 and input 180/cached 90/output 12. Expect normalized input 90, cache_read 90, output 12, not sums of cumulative records.
- [ ] Add regressions for a missing/non-Hash payload, absent totals, null/string-valued counts, and an all-invalid trailing totals object. Missing usable totals must remain nil; an invalid trailing record must not erase earlier usable totals.
- [ ] Extend the existing `usage` scan to select the latest usable cumulative totals in file order from either `event_msg` → `payload.info.total_token_usage` or `token_usage_record` → `payload.thread_token_usage`. Validate containers before descending. Reuse the existing count normalization, cache subtraction and nil semantics.
- [ ] Do not add `payload.usage` or `turn_token_usage` to session totals. Do not attach per-response usage to adjacent messages: these identifiers do not yet establish safe grouping across every record.
- [ ] Run `bundle exec ruby -Itest test/codex_reader_test.rb`, then the dependency's default Rake checks. Both the metadata classification and accounting extension must pass before the consumer requires the fixed release.

## Task 3: Make loop output describe the evidence available

**Files in this gem:**
- Modify: `lib/agent/session_context/loop_view.rb`
- Modify: `lib/agent/session_context/loop.rb`
- Test: `test/loop_view_test.rb`, `test/loop_test.rb`
- Create: `test/support/codex_fixtures.rb`

- [ ] Add a small synthetic Codex fixture helper following `test/support/claude_fixtures.rb`: temporary HOME, session metadata, JSONL under `.codex/sessions/YYYY/MM/DD`, and resolution through `Agent::Sessions.sessions(:codex, env:)`. Use fake IDs and text, never copy the user's private transcript.
- [ ] Cover commentary → empty-summary reasoning → tool call → token metadata → tool result → final-answer message → token metadata. Assert preserved ordering and call pairing, no unknown usage entries, and an answered ending after the final message.
- [ ] Replace ASCII's unconditional control-flow verdict with observational labels: `tool request recorded` when calls exist, and `no tool request in this record` otherwise. Label assumed groups as message entries; show the model-entry count separately from total entries. Keep public `round_trips` keys/indexes and `recorded` flags for compatibility. Apply equivalent count terminology to Markdown.
- [ ] When a Codex reasoning record has no readable parts, display `reasoning (no readable summary recorded)` using a fixed label. Do not decrypt, display, or count encrypted bytes as readable thought text. Keep the existing no-body-leak regressions across ASCII, Markdown and JSON.
- [ ] Add ending tests for a trailing tool result, a trailing unknown record, a trailing commentary message, an empty reasoning record, and a final-answer message. For Codex, treat `phase: final_answer` as evidence for the existing inferred `answered` ending; use a new `incomplete` ending when the final assistant record is explicitly commentary or reasoning. Preserve the legacy inferred behavior for assistant messages with no phase, since older fixtures/stores lack it. Keep user/tool/unknown tails as `not_a_model_record` and explain that this means the last recorded entry is not an assistant answer, not that execution is proven stopped.
- [ ] Update `Loop::ENDINGS` and comments to distinguish a snapshot's last record from a recorded termination reason. Keep `ending_inferred?` true for this bounded patch. Full lifecycle-event normalization and response grouping are separate work.
- [ ] Run `bundle exec ruby -Itest test/loop_test.rb` and `bundle exec ruby -Itest test/loop_view_test.rb`; preserve Claude grouping and tool-pairing tests.

## Task 4: Emit diagnostics once in CLI human output

**Files in this gem:**
- Modify: `lib/agent/session_context/cli.rb`
- Modify: `lib/agent/session_context/loop_view.rb`
- Test: `test/cli_test.rb`, `test/loop_view_test.rb`

- [ ] Add `include_warnings: true` to `LoopView#ascii` and `#markdown`, gating only their warning sections. Preserve standalone Ruby API behavior and structured `to_h[:warnings]`.
- [ ] In the CLI loop rendering path, pass `include_warnings: false` for human output while continuing to emit diagnostics on stderr. Inspect the shared renderer dispatch before editing; confine the option to loop output rather than changing show/prompts/summarize behavior.
- [ ] Test ASCII and Markdown stdout/stderr separately: one genuine unknown warning on stderr, no duplicate warnings section on stdout, and exit status 1. JSON retains structured warnings and existing stderr behavior. A known token-usage record produces no reader warning and exit status 0.
- [ ] Run `bundle exec ruby -Itest test/cli_test.rb` and `bundle exec ruby -Itest test/loop_view_test.rb`.

## Task 5: Integrate the dependency and document expected behavior

**Files in this gem:**
- Modify: `agent_session_context.gemspec`, development `Gemfile.lock` if tracked
- Modify: `README.md`, `CHANGELOG.md`
- Test: `test/session_resolver_test.rb`, `test/readme_contract_test.rb`, existing integration tests

- [ ] Require the first published compatible `agent_sessions` patch release containing Tasks 1–2. Determine its actual version from the release; do not invent an already-available release number. Keep the existing compatible upper bound. Verify both the sibling development checkout and the installed dependency, since Bundler currently chooses a local path whereas the CLI can load installed 0.4.0.
- [ ] Document message-entry versus response-count semantics, the additive `incomplete` ending, accounting compatibility, and the single human-output diagnostic location.
- [ ] Preserve `--current` selection and its warning. Document an explicit selector as the deterministic alternative:

```sh
agent-session-context loop codex:SESSION_ID
```

- [ ] Run resolver tests covering trusted environment selection, absent-environment fallback, ambiguous latest timestamps, and an explicit identifier missing on disk. Do not replace global-latest fallback with CWD matching or silently select a subagent session as the active terminal session.
- [ ] Run `bundle exec rake` in both gems (tests and RuboCop). No typecheck task is declared in this gem's Rakefile. Repeat the synthetic snapshot acceptance check: metadata removal changes 119 entries to 87 while preserving all 31 call/result pairs, with no warning for `token_usage_record`.
- [ ] Make separate reviewable commits for upstream compatibility and consumer presentation; use the workspace Lore intent/body/trailer protocol. Publishing/installing the upstream release is a delivery dependency, not something a consumer-only source edit can replace.

## Boundaries and remaining risks

- No implementation changes were made during the initial investigation; the temporary reader subclass was a diagnostic experiment only. See the implementation status above for subsequent work.
- The original 87 retained entries are still not 87 proven API requests. Accurate response grouping needs a separately validated mapping from response IDs to every relevant response item; turn IDs alone are insufficient.
- Adding `incomplete` is a public enum extension and must be called out for consumers with exhaustive switches.
- The upstream reader lives in the sibling repository, outside this workspace's current writable root. Plan execution must use an authorized writable checkout for that change.
- The new accounting form is observed locally, not assumed to be the only Codex format. Keep old-format fixtures and genuinely unknown-record reporting.
