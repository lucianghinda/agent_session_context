# Summarizer Runtime Limits Design

**Status:** Approved
**Date:** 2026-08-27
**Repository:** `agent_context`
**Base:** `main` at `9db0410`

## Summary

`agent-session-context summarize` currently delegates each semantic extraction and
reduction call to Claude or Codex through `Open3.capture3`. The call has no
wall-clock limit, and stdout and stderr are checked against their 1 MiB limits
only after the provider exits. A hung provider can therefore stall the command,
and a noisy provider can consume unbounded memory before the existing checks run.

This change introduces one shared, standard-library subprocess runner that
enforces time and output limits while the provider is running. It also exposes
the timeout through the Ruby API, the CLI, a project configuration file, and a
user configuration file. The deterministic `show` and `prompts` paths remain
unchanged and never load configuration.

## Goals

- Bound every built-in Claude and Codex provider subprocess by elapsed time.
- Bound stdout and stderr independently while they are being read.
- Terminate and reap the provider after a timeout or output-limit violation.
- Let each analyzed project override the user's default timeout.
- Preserve the current adapter runner seam and provider isolation flags.
- Keep all diagnostics free of prompt and provider-output content.
- Add no runtime dependency beyond the Ruby standard library.

## Non-goals

- A timeout for the entire multi-chunk semantic pipeline.
- Retry, backoff, cancellation UI, or progress reporting.
- Backend-specific timeout values.
- Configuration for output limits, models, credentials, or provider commands.
- Enforcing execution controls for custom summarizer callables.
- Loading configuration for `show` or `prompts`.

## Configuration Contract

Both configuration files use the same strict schema:

```yaml
summarize:
  timeout_seconds: 300
```

The effective value is selected in this order, from highest to lowest priority:

1. CLI `--timeout SECONDS` or Ruby `timeout:` keyword.
2. `<session.project_path>/.agent-context.yml`.
3. One user config: `$XDG_CONFIG_HOME/agent_context/config.yml` when
   `XDG_CONFIG_HOME` is an absolute path, otherwise
   `~/.config/agent_context/config.yml` when `HOME` is available.
4. The built-in default of 300 seconds.

The project layer is anchored to the analyzed session's recorded absolute
`project_path`, not the invoking shell's current directory. The loader does not
walk parent directories. A nil, empty, or relative project path removes the
project layer rather than interpreting it relative to the invoking shell.
A relative or unset `XDG_CONFIG_HOME` falls back to an absolute `HOME`; a
missing, empty, or relative `HOME` removes the user layer. When an absolute
`XDG_CONFIG_HOME` is set, its path is the sole user-config location even if the
file is missing.

`timeout_seconds` accepts a finite integer or float from 1 through 3600,
inclusive. It cannot disable the limit. CLI input uses the same numeric and
range rules. Project configuration overrides the user value only when it
defines `summarize.timeout_seconds`; an empty project file leaves the user value
in place.

YAML is parsed with `Psych.safe_load`, no permitted classes or symbols, and
aliases disabled. An empty document is an empty mapping. Every non-empty
document must be a mapping containing only the `summarize` key, whose value must
be a mapping containing only `timeout_seconds`. Unknown keys, unsafe tags,
aliases, invalid shapes, invalid numbers, unreadable paths, and paths that exist
but are not regular files raise `Agent::SessionContext::ConfigurationError`.

Project configuration is intentionally trusted to choose a duration because
project override was an explicit product requirement. Its influence is limited
to a bounded numeric value: it cannot alter commands, arguments, environment,
credentials, output limits, or isolation flags. The 3600-second ceiling keeps a
project from disabling the safety boundary in practice.

## Public Interfaces

The CLI gains one summarize-only option:

```text
agent-session-context summarize SESSION --timeout SECONDS
```

Using `--timeout` with `show` or `prompts` remains an option error. Help output
documents the range and states that the timeout applies to each provider call.
The existing stderr backend announcement includes the effective value, for
example `summarizing with codex (timeout: 300s)`. Machine-readable stdout remains
untouched.

The Ruby entry point gains an optional keyword:

```ruby
Agent::SessionContext.summarize(session, using: :codex, timeout: 120)
```

When no custom `summarizer:` is supplied, the method resolves configuration and
constructs the built-in backend with the effective timeout. Supplying both a
custom `summarizer:` and `timeout:` raises `ArgumentError`, because silently
ignoring the limit would imply a guarantee the library cannot provide. A custom
summarizer without `timeout:` continues to work unchanged and owns its execution
controls.

`Agent::SessionContext::Summarizers.for` accepts `timeout_seconds:` and passes it to the
Claude or Codex adapter. Each adapter initializer also accepts
`timeout_seconds:` for advanced Ruby callers and tests. Existing injected runner
callables retain the exact contract:

```ruby
call(env:, argv:, stdin_data:) -> [stdout, stderr, status]
```

The new `ConfigurationError` joins the existing `Agent::SessionContext::Error` family,
so the CLI's current text and JSON error paths handle it without a separate
rescue branch.

## Components

### `Agent::SessionContext::Config`

An immutable value object owns the built-in default, range validation, path
selection, safe YAML parsing, layer merging, and explicit override. Its result
contains the effective `timeout_seconds`. It accepts `env:` and filesystem/path
inputs as test seams but keeps no global state or memoized file contents.

Configuration is loaded after session resolution because only the selected
session establishes the project path. It is loaded before backend construction,
so invalid configuration cannot start a provider.

### `Agent::SessionContext::SubprocessRunner`

The shared runner accepts `timeout_seconds:` and `max_output_bytes:` at
construction and implements the existing runner call contract. It uses
`Open3.popen3` with an isolated process group, writes stdin without placing the
prompt in argv, drains stdout and stderr concurrently in bounded chunks, and
measures the deadline with `Process.clock_gettime(Process::CLOCK_MONOTONIC)`.

Each output stream owns a retained buffer capped at `max_output_bytes`. The exact
limit is valid. A bounded read chunk may exist transiently while detecting the
first byte over the limit; that chunk is never added beyond the retained cap.
Overflow records which stream exceeded the bound, stops further accumulation,
and starts termination. The runner never includes captured bytes in its
exceptions.

On timeout or output overflow, the runner sends `TERM` to the POSIX process
group, allows a short fixed grace period, sends `KILL` if needed, closes its IO,
joins reader and writer threads, and reaps the child before returning or
raising. `EPIPE` while writing stdin is treated as the child closing input, not
as prompt-worthy diagnostic content. On Windows, where the standard library
cannot reliably kill an arbitrary descendant tree, the runner uses a new
process group when supported and guarantees direct-child termination and
reaping; descendant cleanup remains best effort and is documented as a platform
limit.

The runner raises internal typed failures for timeout and output overflow. Each
adapter translates them to provider-attributed `SummarizerFailed` messages such
as `codex summarizer exceeded its 300-second timeout` or `claude summarizer
stdout exceeded 1048576 bytes`. Existing post-run response validation remains
in place for injected runners.

## Runtime Flow

For CLI summarization:

1. Parse selection, format, backend, and an optional `--timeout` value.
2. Resolve the session by explicit identifier or current-session environment.
3. Load user configuration, overlay project configuration, then overlay the
   CLI value.
4. Resolve `--using auto` from the session agent.
5. Announce the backend and effective per-call timeout on stderr.
6. Construct the backend and run the existing semantic pipeline.
7. Apply a fresh deadline to every extraction and reduction subprocess.
8. Render the completed snapshot, or route a configuration/provider failure
   through the existing error envelope and nonzero exit.

A session with multiple evidence chunks may take longer than one timeout period
overall because every provider invocation gets its own budget. This is
intentional: the limit detects a stuck child, while whole-command cancellation
remains out of scope.

## Failure Semantics

- Missing config files are normal and silent.
- Invalid or unreadable config fails before provider startup.
- Timeout and output overflow terminate the active provider and fail the entire
  semantic pipeline atomically; no partial summary is returned.
- Error messages identify the config path, backend, timeout, or stream as
  applicable, but never include prompt text or captured provider bytes.
- Failure continues to produce one actionable stderr line for human formats or
  the existing stable JSON error envelope for JSON output.
- Provider nonzero status, missing executable, malformed JSON, and invalid
  grounded output keep their current behavior.

## Testing

`Config` unit tests cover all four precedence layers, project resolution from
the session path rather than current directory, XDG fallback, missing paths,
empty documents, unsafe tags, aliases, unknown keys, invalid mappings,
unreadable/non-file paths, non-finite values, and both range boundaries.

`SubprocessRunner` tests use short Ruby child processes from `RbConfig.ruby` to
prove stdin delivery, concurrent stdout/stderr capture, exact byte boundaries,
early overflow termination, monotonic timeout enforcement, child reaping, and
POSIX process-group cleanup. Timing assertions use generous upper bounds and a
small configurable test timeout rather than equality. Platform-specific group
cleanup assertions are skipped only where the underlying process-group contract
is unavailable; direct-child cleanup is always asserted.

Adapter tests prove both providers pass their configured limits to the shared
runner while preserving current argv, environment allowlists, tempfiles, JSON
normalization, and injected-runner behavior. CLI and public API tests cover
option validation, effective precedence, announcements, JSON errors, and the
custom-callable rule.

Final verification runs the full warning-enabled suite on Ruby 3.2 and 4.0,
syntax checks, Zeitwerk eager loading, gem build/package inspection, and an
isolated installed-gem CLI/library smoke test. Live provider calls remain
optional because they depend on credentials and quota.

## Documentation and Release Notes

The README gains a configuration section with both file locations, the YAML
schema, exact precedence, bounds, and per-provider-call semantics. It explains
that custom summarizers own their own limits and that project configuration can
override the user default. The current residual-risk statements about
`capture3` buffering and missing timeouts are removed. Windows descendant-tree
cleanup is recorded as the remaining platform limitation.

Because version 0.1.0 has not been published, the change is recorded under its
existing 0.1.0 changelog entry rather than creating a later version section.

## Rejected Approaches

- Wrapping `Open3.capture3` in `Timeout.timeout`: it does not enforce streaming
  output bounds and cannot reliably guarantee child-process cleanup.
- Prefixing commands with an operating-system `timeout` executable: it is not
  available by default on macOS and would add platform-dependent behavior.
- A project-local configuration discovered from the invoking current directory:
  explicit session analysis can run from anywhere, so that would apply settings
  from the wrong project.
- Disabling timeout with zero or `false`: it defeats the safety guarantee and
  lets project configuration silently restore the original unbounded behavior.
- Backend-specific settings in the first configuration schema: both providers
  have the same operational contract, and separate values add complexity without
  an observed need.

## Remaining Risks

- Total summarize duration is still proportional to the number of semantic
  chunks because the timeout applies per provider invocation.
- Termination cannot make a provider's remote request disappear if it already
  reached the provider service.
- Descendant-tree termination is best effort on Windows using only the standard
  library; POSIX process-group cleanup is the verified contract.
- Real provider behavior under forced termination remains an optional manual
  smoke test.
