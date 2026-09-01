# Current Session Disk Fallback

**Status:** Approved
**Date:** 2026-08-29

## Context

`agent-session-context COMMAND --current` currently works only when the invoking shell
exports a supported current-session identifier. Codex App and other shells may
have readable session files without exporting one of those variables, so the
command fails even though the most recently updated recorded session can be
discovered locally.

`agent_sessions` exposes `Session#updated_at` from store metadata or file
metadata. Enumerating sessions does not read transcript bodies or force lazy
project-path resolution. A local measurement on 2026-08-29 enumerated 236
Claude sessions in 0.11 seconds and 943 Codex sessions in 0.65 seconds. This is
not a performance guarantee, but it supports a metadata-only fallback for an
explicit `--current` request.

## Goals

- Make `--current` useful when no current-session environment identifier is
  available.
- Preserve all existing environment-variable precedence and validation.
- Let `--agent claude|codex` narrow only the disk fallback.
- Keep CLI and Ruby resolution behavior aligned.
- Tell CLI users exactly which session the fallback selected.
- Refuse an exact recency tie instead of choosing arbitrarily.
- Avoid transcript reads, project-path reads, configuration, and new
  dependencies during discovery.

## Non-goals

- Do not fall back when an environment identifier is present but malformed,
  conflicting, unsupported, or absent from disk.
- Do not infer the current project from the working directory.
- Do not inspect transcript contents to break ties.
- Do not add fuzzy recency windows, persisted preferences, or configuration.
- Do not change explicit `SESSION` resolution.
- Do not publish, push, tag, or release the gem as part of this work.

## Public Interface

The Ruby API becomes:

```ruby
Agent::SessionContext.current(agent: nil, env: ENV, catalog: Agent::Sessions)
```

It still returns one `Agent::Sessions::Session`. The optional `agent` keyword
restricts disk fallback discovery. It does not override a valid environment
identity, because environment identity remains the highest-priority source.

The CLI remains:

```text
agent-session-context COMMAND --current [--agent claude|codex]
```

This applies uniformly to `show`, `prompts`, and `summarize`.

## Resolution Order

`SessionResolver#current(agent: nil)` follows this order:

1. If `AGENT_SESSION_ID` is present, require `AGENT_NAME` and resolve that
   exact identity.
2. Otherwise read `CLAUDE_CODE_SESSION_ID`, `CODEX_SESSION_ID`, and
   `CODEX_THREAD_ID` with the existing precedence and conflict checks.
3. If one provider identity is present, resolve it exactly.
4. Only when no supported identity variable is present, enumerate session
   metadata for the requested agent or for Claude and Codex.
5. Select the one session with the greatest `updated_at`.

An environment identifier that does not resolve still raises
`SessionNotFound`. The fallback must not hide stale or incorrect identity
variables by silently selecting an unrelated session.

## Disk Fallback

The unrestricted fallback enumerates Claude first and Codex second, then
compares all returned `updated_at` values. An agent-restricted fallback calls
only that agent's catalog. Enumeration must not call `project_path`, read a
transcript, or instantiate a `Builder`.

If no sessions exist, raise `CurrentSessionUnavailable` and name the searched
agent scope. If several sessions share the exact greatest `updated_at`, raise
`AmbiguousSession`, name the timestamp and sorted session UIDs, and ask for an
explicit `SESSION`. Ordering never breaks a timestamp tie.

## CLI Warning

On successful disk fallback, every CLI command writes this warning to stderr
before command-specific status or privacy messages:

```text
warning: --current found no session environment identifier; using latest session on disk: codex:SESSION_ID
```

Explicit session selection and environment-based `--current` emit no fallback
warning. JSON and JSONL stdout remain valid because the warning never goes to
stdout.

The resolver continues returning a session, not a wrapper result. Its internal
`current` method yields the selected session to an optional block only when the
disk fallback succeeds. The CLI uses that block for the warning; the module API
does not print.

## Errors

- Partial generic identity (`AGENT_SESSION_ID` without `AGENT_NAME`) keeps the
  existing `CurrentSessionUnavailable` error.
- Conflicting Claude and Codex variables keep the existing
  `CurrentSessionUnavailable` error.
- Unsupported agent names keep the existing `UnsupportedAgent` error.
- Environment identities missing from disk keep `SessionNotFound`.
- An empty disk search raises `CurrentSessionUnavailable`.
- A greatest-timestamp tie raises `AmbiguousSession`.

## Testing

Implementation proceeds test-first and covers:

- Environment identities still beat newer disk sessions.
- Missing environment identities select the newest session across both agents.
- `agent:` and CLI `--agent` restrict fallback enumeration to one agent.
- Empty restricted and unrestricted searches fail clearly.
- Exact greatest-timestamp ties fail with stable sorted UIDs.
- The fallback block runs exactly once only for disk fallback.
- The public Ruby API forwards `agent:` and remains silent.
- All three CLI commands emit the fallback warning on stderr.
- Environment-based `--current` and explicit `SESSION` do not warn.
- JSON and JSONL stdout remain machine-readable when the fallback warns.
- Discovery never reads a transcript or resolves a project path.

Focused resolver and CLI tests run red first, then green. The complete suite
runs on Ruby 3.2 and Ruby 4.0 before completion.

## Documentation

Update CLI help, README session-resolution rules, changelog, and the canonical
requirements/spec. The documentation must distinguish trusted environment
identity from the visible recency fallback and must not call the selected
session the live model context.

## Decisions

1. **Environment identity remains authoritative.** A present but bad identity
   fails rather than falling through to a different session.
2. **Recency is used only after explicit `--current` or Ruby `.current`.** No
   command silently selects a session when neither an identifier nor current
   mode was requested.
3. **Session metadata is the only fallback input.** Directory timestamps and
   transcript inspection are less precise or more expensive.
4. **The public return type remains a session.** A callback for the internal
   fallback event avoids a breaking wrapper type and avoids duplicating
   environment logic in the CLI.
5. **Ties are errors.** UID ordering is deterministic but is not evidence that
   one tied session is more current.
6. **The warning is CLI-only.** Libraries choose how to communicate selection;
   command-line users need an immediate disclosure before sharing output.
