## [Unreleased]

## [1.0.0] - 2026-09-10

- **BREAKING**: the gem is now distributed as `agent_session_context`. The
  namespace, require path, and executable are unchanged; users change only
  the Gemfile line.

## [0.1.0] - 2026-09-01

- Use the `agent-session_context` distribution, `Agent::SessionContext`
  namespace, and `agent-session-context` executable to avoid collisions with
  the existing `agent-context` gem and `Agent::Context` namespace.
- Let `--current` choose the uniquely latest session metadata timestamp only
  when no supported session environment identifier is present. Present
  identifiers keep their validation and errors; `--agent` narrows disk
  fallback, empty stores raise `CurrentSessionUnavailable`, the CLI warns with
  the selected UID, and exact ties refuse with explicit-session guidance.
- Make `show` include exact user prompts and a deduplicated injected-context
  inventory, with explicit `--include-injected`/`include_injected: true` access
  to full injected text and documented raw-transcript exclusions.
- Add real Claude Code and Codex CLI JSONL fixtures for the public `show`,
  `prompts`, and `summarize` contract.
- Verify prompt filtering against injected environment, AGENTS, slash-command,
  and tool-result records while keeping observed file/tool evidence grounded to
  source refs.
- Bound summarizer subprocess stdout/stderr streaming to independent `1 MiB`
  caps, add per-call timeout controls across config/API/CLI, and package the
  shared subprocess/config support.
- Verify the Codex summarization backend against a live recorded session.
- Document the recorded-evidence model, CLI/API surface, privacy boundaries,
  and provider boundaries.
- Include source, changelog, and issue-tracker links for the public GitHub
  repository in the gem metadata.
