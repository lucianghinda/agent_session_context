# Agent Session Context

[![Build](https://github.com/lucianghinda/agent_session_context/actions/workflows/main.yml/badge.svg)](https://github.com/lucianghinda/agent_session_context/actions/workflows/main.yml)
[![Ruby](https://img.shields.io/badge/ruby-%3E%3D%203.2-red.svg)](https://www.ruby-lang.org/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE.txt)

Inspect and summarize recorded Claude Code and Codex sessions.

## Installation

Use Ruby 3.2 or newer.

Add this line to your application's **Gemfile**:

```ruby
gem "agent_session_context"
```

Then run:

```bash
bundle install
```

## Quick Start

Show the latest recorded session:

```bash
agent-session-context show --current
```

## Usage

### Basic Usage

Show an exact session:

```bash
agent-session-context show codex:SESSION_ID
```

Disambiguate a bare identifier:

```bash
agent-session-context show SESSION_ID --agent codex
```

List exact user prompts:

```bash
agent-session-context prompts --current
```

Render prompts as JSON Lines:

```bash
agent-session-context prompts --current --format jsonl
```

### Current Sessions

Use these variables for `--current`, in order:

1. `AGENT_SESSION_ID` with `AGENT_NAME`
2. `CLAUDE_CODE_SESSION_ID`
3. `CODEX_SESSION_ID`
4. `CODEX_THREAD_ID`

Without variables, let the command select the unique newest session metadata.

Pass `--agent` to restrict that disk search.

Keep present identifiers authoritative.

Never trigger fallback after validating a present identifier.

Clear conflicting Claude and Codex identifiers before retrying.

Expect missing targets, empty stores, and timestamp ties to fail.

Read the selected UID from the CLI warning.

Treat disk selection as recency, not live context.

### Local Context

Include deduplicated injected text explicitly:

```bash
agent-session-context show --current --include-injected
```

Review exact prompts and injected text before sharing them.

Expect `show` to exclude assistant messages, thinking, tool-result bodies, and raw envelopes.

Use `show` and `prompts` without starting a model.

### Summaries

Create a grounded summary:

```bash
agent-session-context summarize --current
```

Choose a backend and timeout:

```bash
agent-session-context summarize --current --using codex --timeout 45
```

Codex summarization was tested successfully against a live recorded session.

Expect summaries to cite recorded source references.

Expect summaries to exclude thinking, tool results, injected blocks, and raw records.

Treat Codex filesystem access as read-only, not hermetic.

### Ruby API

Resolve and inspect a session:

```ruby
require "agent/session_context"

session = Agent::SessionContext.resolve("codex:SESSION_ID")
snapshot = Agent::SessionContext.show(session)
```

Inspect the newest recorded Codex session:

```ruby
session = Agent::SessionContext.current(agent: :codex, env: {})
prompts = Agent::SessionContext.prompts(session)
```

Create a summary with built-in settings:

```ruby
summary = Agent::SessionContext.summarize(session, using: :codex, timeout: 45)
```

Use a custom summarizer:

```ruby
summary = Agent::SessionContext.summarize(
  session,
  summarizer: ->(prompt:, schema:) { call_your_model(prompt, schema) }
)
```

Replace `call_your_model` with your adapter.

Return a JSON string matching the provided schema.

Pass either `summarizer:` or `timeout:`, never both.

### Supported Public Ruby API

`Agent::SessionContext.resolve` and `Agent::SessionContext.current` return `Agent::Sessions::Session`.

`Agent::SessionContext.show` returns an `Agent::SessionContext::Snapshot` whose collections contain `Agent::SessionContext::Prompt`, `Agent::SessionContext::InjectedContext`, `Agent::SessionContext::Item`, and `Agent::SessionContext::SourceRef` values as applicable.

`Agent::SessionContext.prompts` returns an array of `Agent::SessionContext::Prompt` values.

`Agent::SessionContext.summarize` returns an `Agent::SessionContext::Snapshot` populated with summary `Agent::SessionContext::Item` values and summary metadata.

`Agent::SessionContext::Snapshot`, `Agent::SessionContext::Prompt`, `Agent::SessionContext::InjectedContext`, `Agent::SessionContext::Item`, and `Agent::SessionContext::SourceRef` are part of the supported public data model.

`Agent::SessionContext::VERSION` is public.

`Agent::SessionContext::CLI::FORMATS` is the supported frozen list of CLI output format names.

The public error classes listed in [Errors](#errors) are part of the compatibility contract.

### Internal Architecture

`resolve -> capture -> extract/collect -> optionally summarize -> build snapshot -> render`.

`show` can expose injected text only when you opt into `include_injected`, while `summarize` keeps injected blocks and tool-result bodies out of the model prompt.

Except for `Agent::SessionContext::CLI::FORMATS`, the CLI implementation, builders, collectors, parsers, runners, renderers, and built-in summarizer adapters are internal details without compatibility guarantees.

## Options

| Option | Description |
|---|---|
| `--current` | Use environment identity, then the newest disk metadata. |
| `--agent claude\|codex` | Restrict explicit lookup or disk fallback. |
| `--format FORMAT` | Choose text, Markdown, JSON, or JSON Lines when supported. |
| `--include-injected` | Include deduplicated injected text with `show`. |
| `--using BACKEND` | Choose `auto`, `claude`, or `codex` for summaries. |
| `--timeout SECONDS` | Set each provider call timeout from 1 through 3600 seconds. |

Run `agent-session-context help` for command details.

### Configuration

Expect only `summarize` to load configuration.

Configuration paths retain the original `agent-context` name for compatibility.

Create `.agent-context.yml` in the recorded project:

```yaml
summarize:
  timeout_seconds: 300
```

Set user defaults in `$XDG_CONFIG_HOME/agent_context/config.yml`.

Otherwise, use `$HOME/.config/agent_context/config.yml`.

Use `XDG_CONFIG_HOME` exclusively when it contains an absolute path.

Let project configuration override user defaults.

Pass `--timeout` to override both files.

Use finite numbers from `1` through `3600`.

Apply the timeout to each provider call.

### Output Formats

| Command | Formats |
|---|---|
| `show` | `text`, `markdown`, `json` |
| `prompts` | `text`, `markdown`, `json`, `jsonl` |
| `summarize` | `text`, `markdown`, `json` |

### Errors

Handle these public errors:

- `Agent::SessionContext::SessionNotFound`
- `Agent::SessionContext::AmbiguousSession`
- `Agent::SessionContext::CurrentSessionUnavailable`
- `Agent::SessionContext::UnsupportedAgent`
- `Agent::SessionContext::ConfigurationError`
- `Agent::SessionContext::SummarizerUnavailable`
- `Agent::SessionContext::SummarizerFailed`
- `Agent::SessionContext::InvalidSummary`

## Contributing

Fork the repository and create a branch.

Run the test suite:

```bash
bundle exec rake test
```

Open a pull request with tests and documentation.

Follow [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

Report bugs through [GitHub Issues](https://github.com/lucianghinda/agent_session_context/issues).

## License

Use the gem under the MIT License.

See [LICENSE.txt](LICENSE.txt).
