# Current Session Disk Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-ruby:subagent-driven-development (recommended) or superpowers-ruby:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `--current` and `Agent::SessionContext.current` select the newest recorded session by metadata when no trusted current-session environment identifier exists.

**Architecture:** Keep environment resolution inside `SessionResolver` and add a metadata-only fallback there. Preserve the public return type by yielding only fallback selections to an optional block; the CLI uses that block to print a warning, while the Ruby module API stays silent. Use `Session#updated_at` across Claude and Codex, reject exact latest-time ties, and let `agent:` narrow only the fallback scan.

**Tech Stack:** Ruby 3.2+, Minitest, `agent_sessions`, OptionParser, Zeitwerk, Ruby standard library.

---

## File map

- Modify `test/support/fake_catalog.rb` so fake sessions carry `updated_at`.
- Modify `test/session_resolver_test.rb` to pin environment precedence, fallback selection, narrowing, empty stores, ties, and fallback notification.
- Modify `lib/agent/session_context/session_resolver.rb` to implement metadata-only fallback.
- Modify `lib/agent/session_context.rb` so `.current(agent:)` matches CLI resolution.
- Modify `test/builder_test.rb` to pin the public `.current(agent:)` keyword.
- Modify `test/cli_test.rb` to pin `--agent` forwarding and stderr fallback disclosure for all commands.
- Modify `lib/agent/session_context/cli.rb` to emit the fallback warning without polluting stdout.
- Modify `README.md`, `CHANGELOG.md`, and CLI help to document resolution precedence.
- Modify workspace-level `docs/agent-context-spec/00-requirements.md` and `docs/agent-context-spec/spec.md` to replace the deferred fallback with the implemented contract.

### Task 1: Resolver fallback contract

**Files:**
- Modify: `test/support/fake_catalog.rb:3-21`
- Modify: `test/session_resolver_test.rb:104-290`
- Modify: `lib/agent/session_context/session_resolver.rb:33-120`

- [ ] **Step 1: Extend fake sessions with recency metadata**

Change the fake value and constructor to:

```ruby
Session = Data.define(:agent, :id, :uid, :updated_at)

def build_session(agent, id:, uid: nil, updated_at: Time.utc(2026, 1, 1))
  agent = agent.to_sym
  Session.new(agent:, id: id.to_s, uid: uid || "#{agent}:#{id}", updated_at:)
end
```

Update the local `session` helper in `test/session_resolver_test.rb` the same way:

```ruby
def session(agent, id:, uid: nil, updated_at: Time.utc(2026, 1, 1))
  FakeCatalog::Session.new(
    agent: agent.to_sym,
    id: id.to_s,
    uid: uid || "#{agent}:#{id}",
    updated_at:
  )
end
```

- [ ] **Step 2: Write failing cross-agent fallback and precedence tests**

Add:

```ruby
def test_current_falls_back_to_latest_session_across_supported_agents
  catalog = FakeCatalog.new
    .add(:claude, session(:claude, id: "older", updated_at: Time.utc(2026, 8, 29, 8, 0)))
    .add(:codex, session(:codex, id: "latest", updated_at: Time.utc(2026, 8, 29, 9, 0)))
  yielded = []

  selected = build_resolver(catalog:, env: {}).current { |session| yielded << session }

  assert_equal "codex:latest", selected.uid
  assert_equal [selected], yielded
  assert_equal({claude: 1, codex: 1}, catalog.calls)
end

def test_current_environment_identity_still_beats_a_newer_disk_session
  catalog = FakeCatalog.new
    .add(:claude, session(:claude, id: "selected", updated_at: Time.utc(2026, 8, 29, 8, 0)))
    .add(:codex, session(:codex, id: "newer", updated_at: Time.utc(2026, 8, 29, 9, 0)))
  yielded = []
  resolver = build_resolver(catalog:, env: {"CLAUDE_CODE_SESSION_ID" => "selected"})

  selected = resolver.current { |session| yielded << session }

  assert_equal "claude:selected", selected.uid
  assert_empty yielded
  assert_equal({claude: 1}, catalog.calls)
end
```

- [ ] **Step 3: Run the resolver tests and verify RED**

Run:

```bash
bundle exec ruby -Itest test/session_resolver_test.rb
```

Expected: the fallback test raises `CurrentSessionUnavailable` because no environment identifier exists.

- [ ] **Step 4: Write failing narrowing, empty-store, and tie tests**

Add:

```ruby
def test_current_agent_restricts_only_the_disk_fallback
  catalog = FakeCatalog.new
    .add(:claude, session(:claude, id: "claude", updated_at: Time.utc(2026, 8, 29, 8, 0)))
    .add(:codex, session(:codex, id: "codex", updated_at: Time.utc(2026, 8, 29, 9, 0)))

  selected = build_resolver(catalog:, env: {}).current(agent: :claude)

  assert_equal "claude:claude", selected.uid
  assert_equal({claude: 1}, catalog.calls)
end

def test_current_raises_when_disk_fallback_finds_no_sessions
  error = assert_raises(Agent::SessionContext::CurrentSessionUnavailable) do
    build_resolver(catalog: FakeCatalog.new, env: {}).current
  end

  assert_includes error.message, "No recorded sessions"
  assert_includes error.message, "claude or codex"
end

def test_current_raises_when_latest_timestamp_is_tied
  timestamp = Time.utc(2026, 8, 29, 9, 0)
  catalog = FakeCatalog.new
    .add(:claude, session(:claude, id: "z", updated_at: timestamp))
    .add(:codex, session(:codex, id: "a", updated_at: timestamp))

  error = assert_raises(Agent::SessionContext::AmbiguousSession) do
    build_resolver(catalog:, env: {}).current
  end

  assert_includes error.message, timestamp.iso8601
  assert_match(/codex:a.*claude:z|claude:z.*codex:a/, error.message)
  assert_includes error.message, "explicit SESSION"
end
```

Retain the existing test proving that a present environment identifier missing from disk raises `SessionNotFound`; do not change it to expect fallback.

- [ ] **Step 5: Implement the minimal resolver fallback**

Change the signature and final branch:

```ruby
def current(agent: nil)
  # existing environment resolution stays unchanged
  return resolve(claude_identifier, agent: :claude) if present?(claude_identifier)
  return resolve(codex_identifier, agent: :codex) if present?(codex_identifier)

  session = latest_session(agent:)
  yield session if block_given?
  session
end
```

Add private helpers:

```ruby
def latest_session(agent:)
  agents = agent ? [normalize_agent(agent, source: "agent")] : SUPPORTED
  sessions = agents.flat_map { |candidate| @catalog.sessions(candidate, env: @env).force }

  if sessions.empty?
    scope = agent ? agents.first.to_s : "claude or codex"
    fail CurrentSessionUnavailable, "No recorded sessions were found for #{scope}."
  end

  latest_at = sessions.map(&:updated_at).max
  latest = sessions.select { |session| session.updated_at == latest_at }
  return latest.first if latest.one?

  uids = latest.map(&:uid).sort.join(", ")
  fail AmbiguousSession,
    "Latest session is ambiguous at #{latest_at.iso8601}: #{uids}. Pass an explicit SESSION."
end
```

Do not access `project_path`, `path`, or transcript readers.

- [ ] **Step 6: Run focused tests and verify GREEN**

Run:

```bash
bundle exec ruby -Itest test/session_resolver_test.rb
```

Expected: all resolver tests pass with zero failures and errors.

- [ ] **Step 7: Commit the resolver unit**

Stage only the three task files and commit with a Lore message whose intent is that current lookup works without shell integration. Record the focused test command in `Tested:`.

### Task 2: Public API and CLI disclosure

**Files:**
- Modify: `lib/agent/session_context.rb:22-24`
- Modify: `lib/agent/session_context/cli.rb:120-146,206-212`
- Modify: `test/builder_test.rb:278-310`
- Modify: `test/cli_test.rb:15-40,132-148,365-399`

- [ ] **Step 1: Write a failing public API forwarding test**

Extend the API test with a newer Codex session and assert:

```ruby
assert_same session, Agent::SessionContext.current(agent: :codex, env: {}, catalog:)
```

Use a catalog containing both agents so the assertion fails unless `agent:` reaches the resolver.

- [ ] **Step 2: Write failing CLI forwarding and warning tests**

Update `FakeResolver` to accept but record the desired future interface:

```ruby
def initialize(
  resolve_result: nil,
  current_result: nil,
  resolve_error: nil,
  current_error: nil,
  current_fallback: false
)
  @resolve_result = resolve_result
  @current_result = current_result
  @resolve_error = resolve_error
  @current_error = current_error
  @current_fallback = current_fallback
  @resolve_calls = []
  @current_calls = []
end

def current(agent: nil)
  @current_calls << {agent:}
  raise @current_error if @current_error
  yield @current_result if @current_fallback && block_given?
  @current_result
end
```

Change existing current assertions from an integer to an array. Add a `show` test:

```ruby
def test_show_current_forwards_agent_and_warns_when_disk_fallback_was_used
  session = build_session(agent: :codex, id: "latest")
  resolver = FakeResolver.new(current_result: session, current_fallback: true)
  builder = FakeBuilder.new(show_result: build_snapshot(session))

  status, out, err = run_cli(
    "show", "--current", "--agent", "codex", "--format", "json",
    resolver:, builder:
  )

  assert_equal 0, status
  assert_equal [{agent: :codex}], resolver.current_calls
  assert_match(/using latest session on disk: codex:latest/, err)
  assert_equal session.uid, JSON.parse(out).fetch("session_uid")
end
```

Add equivalent `prompts --current --format jsonl` and `summarize --current --format json` cases. Assert that the warning precedes the prompt privacy warning or summarize status line and that stdout parses successfully.

- [ ] **Step 3: Run the API and CLI tests and verify RED**

Run:

```bash
bundle exec ruby -Itest test/builder_test.rb test/cli_test.rb
```

Expected: `.current` rejects `agent:` and the CLI either rejects the fake resolver keyword or omits the fallback warning.

- [ ] **Step 4: Implement public API forwarding**

Change:

```ruby
def current(agent: nil, env: ENV, catalog: Agent::Sessions)
  SessionResolver.new(catalog:, env: env).current(agent:)
end
```

- [ ] **Step 5: Implement CLI forwarding and warning**

Change `resolve_session`:

```ruby
def resolve_session(selection)
  if selection.fetch(:current)
    @resolver.current(agent: selection.fetch(:agent)) do |session|
      @stderr.puts "warning: --current found no session environment identifier; " \
        "using latest session on disk: #{safe_text(session.uid)}"
    end
  else
    @resolver.resolve(selection.fetch(:identifier), agent: selection.fetch(:agent))
  end
end
```

Update help under Common options:

```text
--current             Use environment identity, else latest on disk
--agent claude|codex  Narrow explicit lookup or --current disk fallback
```

- [ ] **Step 6: Run focused tests and verify GREEN**

Run:

```bash
bundle exec ruby -Itest test/builder_test.rb test/cli_test.rb
```

Expected: all API and CLI tests pass; JSON and JSONL assertions parse stdout while warnings remain on stderr.

- [ ] **Step 7: Commit the API/CLI unit**

Stage only the four task files and commit with a Lore message. Record both focused test files in `Tested:`.

### Task 3: User documentation and canonical contract

**Files:**
- Modify: `README.md:30-54`
- Modify: `CHANGELOG.md:1-20`
- Modify: `../../docs/agent-context-spec/00-requirements.md`
- Modify: `../../docs/agent-context-spec/spec.md`

- [ ] **Step 1: Update README resolution rules**

Document, in order:

```markdown
- `--current` first uses `AGENT_SESSION_ID` with `AGENT_NAME`,
  `CLAUDE_CODE_SESSION_ID`, `CODEX_SESSION_ID`, or `CODEX_THREAD_ID`.
- When none are present, `--current` selects the one session with the greatest
  `updated_at` and warns with the selected UID.
- `--agent claude|codex` narrows only that disk fallback.
- A missing environment identity target, an empty search, or an exact latest
  timestamp tie fails rather than silently selecting another session.
```

State that disk fallback reads session metadata, not transcript bodies, and is a recency heuristic rather than proof of the live model context.

- [ ] **Step 2: Update the changelog**

Add an Unreleased entry explaining that `--current` now falls back to the latest metadata timestamp, supports agent narrowing, warns with the selected UID, and refuses ties.

- [ ] **Step 3: Synchronize canonical requirements and decisions**

In both canonical requirement tables, replace R4 with the implemented environment-first fallback contract. In `spec.md`:

- remove the fallback from out-of-scope;
- update D3 from “does not guess” to visible environment-first recency fallback;
- replace T1's no-identifier error row with unrestricted/restricted fallback rows;
- add tests for newest selection, no sessions, ties, agent narrowing, and CLI warning;
- update the resolver pseudocode, scenario trace, build order, risk, rollout, and appendix;
- keep the warning that recency is a heuristic and not live-session identity.

- [ ] **Step 4: Run documentation checks**

Run:

```bash
ruby /Users/luciang/.agents/skills/change-spec/scripts/spec_check.rb ../../docs/agent-context-spec/spec.md
git diff --check
```

Expected: the spec checker reports no errors and `git diff --check` reports no whitespace errors.

- [ ] **Step 5: Commit repository documentation**

Stage only `README.md` and `CHANGELOG.md`, then commit with a Lore documentation message. The workspace-level canonical spec is outside the gem repository and remains a local uncommitted workspace artifact.

### Task 4: Full verification and final implementation commit

**Files:**
- Verify all modified repository files.
- Do not stage the pre-existing `Gemfile` or `Gemfile.lock` changes.

- [ ] **Step 1: Run the full suite on Ruby 4.0.1**

Run with the Ruby selected explicitly so Bundler does not execute through the macOS Ruby 2.6 shebang:

```bash
/Users/luciang/.rubies/ruby-4.0.1/bin/ruby \
  /Users/luciang/.gem/ruby/4.0.1/bin/bundle exec rake test
```

Expected: zero failures, zero errors, zero skips.

- [ ] **Step 2: Run the full suite on Ruby 3.2.3**

Run:

```bash
/bin/zsh -lc 'source /opt/homebrew/opt/chruby/share/chruby/chruby.sh; chruby ruby-3.2.3; bundle exec rake test'
```

Expected: zero failures, zero errors, zero skips. Record any environment-only Bundler warning separately.

- [ ] **Step 3: Build the gem**

Run:

```bash
/Users/luciang/.rubies/ruby-4.0.1/bin/ruby \
  /Users/luciang/.gem/ruby/4.0.1/bin/bundle exec gem build agent-session_context.gemspec
```

Expected: the gem builds successfully. Do not publish it.

- [ ] **Step 4: Run a real local CLI smoke test**

With the current-session environment variables removed for the command only, run default and agent-restricted `show --current --format json`. Verify:

- exit status 0;
- stderr names the selected fallback UID;
- stdout parses as JSON;
- the unrestricted result is the greatest `updated_at` across Claude and Codex;
- `--agent codex` selects the greatest Codex timestamp;
- no transcript is modified.

Use a temporary Ruby verification script for timestamp comparison and JSON parsing, then delete it.

- [ ] **Step 5: Inspect the final diff and status**

Run `git diff --check`, `git status --short`, and `git diff --stat`. Confirm only intended feature files are staged or modified and the user-owned `Gemfile` plus `Gemfile.lock` remain untouched.

- [ ] **Step 6: Commit any remaining implementation/docs integration**

If Tasks 1–3 left a coherent uncommitted integration diff, commit it with a Lore message including both Ruby test versions, the gem build, and the smoke test in `Tested:`. Do not push, tag, publish, or create a release.
