# Complete Local Context in `show`

**Status:** Final
**Date:** 2026-08-28

## Context

`agent-session-context show` currently returns session metadata plus observed files,
documents, and tool activity. Exact user prompts are available only through the
separate `prompts` command, while injected user-role blocks are counted but not
represented. This makes `show` read like a partial view even though users
naturally understand it as the command that shows all supported local context.

The current Codex session demonstrates why injected text needs two levels of
detail: five injected blocks occupy about 60 KB, including two identical 28 KB
AGENTS instruction blocks. Full inclusion by default would obscure the useful
context and repeat content without adding information.

## Goals

- Make `show` the complete local view of supported session context.
- Include exact user-authored prompts by default.
- Include a compact inventory of injected context by default.
- Allow explicit opt-in to full injected text without repeating identical
  blocks.
- Keep CLI and Ruby API behavior aligned.
- State the deliberately excluded content clearly.
- Preserve the local-only, deterministic, model-free behavior of `show`.

## Non-goals

- Do not include assistant messages, thinking, tool-result bodies, or raw
  provider envelopes.
- Do not change semantic summarization input or output.
- Do not add fuzzy deduplication, secret detection, configuration, or new
  dependencies.
- Do not publish, push, tag, or release the gem as part of this work.

## Public Interface

The Ruby API becomes:

```ruby
Agent::SessionContext.show(session, include_injected: false, **builder_options)
```

`include_injected` accepts only `true` or `false`. Any other value raises
`ArgumentError`; this avoids accidentally exposing content through Ruby
truthiness.

The CLI becomes:

```text
agent-session-context show SESSION [--include-injected] [--format text|markdown|json]
```

`--include-injected` is valid only for `show`. Existing strict option handling
rejects it for `prompts`, `summarize`, and other commands.

The focused prompt interface remains unchanged:

```ruby
Agent::SessionContext.prompts(session)
```

```text
agent-session-context prompts SESSION [--format text|markdown|json|jsonl]
```

## Data Model

`Agent::SessionContext::Snapshot` gains two frozen collections after
`message_count`:

```ruby
:prompts
:injected_context
```

Both default to empty arrays. A `show` snapshot populates both collections. A
`summarize` snapshot leaves them empty, just as a `show` snapshot leaves the six
semantic collections empty.

Injected inventory entries use a dedicated immutable value object:

```ruby
Agent::SessionContext::InjectedContext.new(
  kind:,
  bytes:,
  occurrences:,
  source_refs:,
  text: nil
)
```

- `kind` is derived from the exact marker that already caused the part to be
  classified as injected. An injected raw meta message without a known marker
  uses `provider_meta`. Marker kinds are `command_name`, `command_message`,
  `command_args`, `local_command_stdout`, `local_command_stderr`,
  `system_reminder`, `environment_context`, `user_instructions`, and
  `agents_instructions`. This introduces no new heuristic classification.
- `bytes` is the byte size of the unique recorded text.
- `occurrences` is the number of byte-identical parts represented by the
  entry.
- `source_refs` contains every occurrence in transcript order.
- `text` is `nil` by default and contains one immutable copy of the recorded
  text when full inclusion is requested.

Entries are ordered by first occurrence. Deduplication uses exact string
equality only. Similar but non-identical blocks remain separate.

## Data Flow

`Builder#show(session, include_injected: false)` performs one transcript read:

1. Capture the normalized transcript through `agent_sessions`.
2. Extract exact prompts with the existing `PromptExtractor`.
3. Collect injected parts into the deduplicated inventory.
4. Collect observed files, documents, and tool activity with the existing
   `EvidenceCollector`.
5. Construct one `Snapshot` containing all supported local context.

Neither `show` mode loads configuration, starts a semantic pipeline, invokes a
provider, or modifies the recorded session.

The module-level `Agent::SessionContext.show` and CLI `show` call the same builder
path. The CLI does not combine separately captured results, which prevents
duplicate reads and keeps library output identical to CLI output.

## Rendering

Human-readable `show` output uses this order:

1. Session metadata
2. User prompts
3. Injected context
4. Observed files
5. Observed documents
6. Observed tool activity
7. Warnings

Prompt and full injected text are rendered as literal blocks using the
existing display-safety rules. Recorded Markdown, terminal control bytes, or
heading-like text must not alter the surrounding output structure.

Default injected entries show kind, bytes, occurrences, and source references.
With full inclusion, each unique entry additionally renders its text once.

JSON adds stable `prompts` and `injected_context` arrays. The
`injected_context[*].text` key is always present: it is `null` by default and a
string with full inclusion. Because these fields belong to `Snapshot`, JSON
from `summarize` also contains both keys as empty arrays.

## Privacy and Exclusions

The CLI always warns that `show` contains exact prompts that may include
secrets. With `--include-injected`, the warning explicitly states that full
injected context is also present and should be reviewed before sharing.

CLI help and README documentation define `show` as all *supported local
context* and explicitly state that it excludes:

- assistant messages
- thinking content
- tool-result bodies
- raw provider envelopes

The documentation also distinguishes inventory metadata from full injected
text. `summarize` continues excluding injected content from provider input;
the new `show` flag never affects the semantic pipeline.

## Errors and Partial Captures

- Invalid CLI placement of `--include-injected` follows the existing clean
  `OptionParser` error envelope, including JSON-formatted errors.
- Invalid Ruby keyword values raise before transcript capture.
- Reader warnings continue to appear in the snapshot and on CLI stderr.
- A partial reader capture continues to return the existing nonzero CLI status.
- Empty prompt or injected collections render no empty human section while
  remaining explicit empty arrays in JSON.

## Testing

Implementation proceeds test-first and covers:

- `InjectedContext` validation, immutability, and defensive copying.
- The expanded `Snapshot` member order and frozen defaults.
- Exact prompt inclusion in `show` without a second transcript read.
- Marker-derived injected kinds and the `provider_meta` fallback.
- Exact deduplication, first-seen ordering, byte counts, occurrence counts, and
  complete source-reference preservation.
- Default omission and opt-in inclusion of injected text.
- Strict boolean validation in the Ruby API.
- CLI/Ruby parity and strict command-specific flag handling.
- Default and full-content privacy warnings.
- Safe text, Markdown, and JSON rendering, including hostile-looking recorded
  content.
- Updated Claude and Codex integration fixtures and machine-output schemas.
- Confirmation that `show` invokes no summarizer and leaves session bytes and
  modification times unchanged.
- Confirmation that semantic provider input still excludes injected context.

Focused tests run first, followed by formatting/static checks and the complete
suite on Ruby 3.2 and Ruby 4.0.

## Documentation

Update the README command synopsis, local-only/privacy sections,
deterministic-versus-semantic explanation, Ruby API examples, output schema,
and residual-risk notes. Update CLI help and the changelog with the same
inclusion and exclusion contract.

## Decisions

1. **`show` is the complete supported local view.** It includes prompts and an
   injected inventory while preserving intentional exclusions.
2. **Prompts are included by default.** Requiring another flag would retain the
   ambiguity that motivated the change.
3. **Full injected text is opt-in.** Real injected blocks are large and often
   duplicated; default inventory preserves visibility without overwhelming the
   result.
4. **Exact duplicates are represented once.** All source references remain, so
   deduplication does not erase provenance.
5. **`Snapshot` is extended directly.** A wrapper or CLI-only composite would
   make the library and CLI disagree. The gem is unpublished, so this is the
   right time to establish the coherent schema.
6. **Exclusions stay strict and explicit.** Assistant messages, thinking,
   tool-result bodies, and raw envelopes remain outside `show`; documentation
   and help prevent “everything” from overstating the contract.
7. **Summarization remains unchanged.** Local visibility of injected context
   must not silently widen data sent to semantic providers.
