# Summarizer Runtime Limits Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-ruby:subagent-driven-development (recommended) or superpowers-ruby:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bound every built-in Claude and Codex provider process by streamed output limits and a configurable per-call wall-clock timeout.

**Architecture:** Add one immutable configuration loader and one shared subprocess runner. Resolve CLI/Ruby overrides over project and user YAML before backend construction; keep Claude and Codex responsible only for provider argv and provider-specific error translation.

**Tech Stack:** Ruby 3.2+, standard library (`open3`, `psych`, `pathname`, `io/wait`, `rbconfig`), Zeitwerk, Minitest.

---

## File Map

**Create:**

- `lib/agent/session_context/config.rb` — safe YAML paths, schema, precedence, and timeout validation.
- `lib/agent/session_context/subprocess_runner.rb` — concurrent bounded IO, monotonic deadlines, termination, and child reaping.
- `test/config_test.rb` — configuration path, merge, schema, and validation contract.
- `test/subprocess_runner_test.rb` — real subprocess time/output/cleanup contract.

**Modify:**

- `lib/agent/session_context/errors.rb` — add `ConfigurationError`.
- `lib/agent/session_context.rb` — expose `timeout:` for built-in summarizers without changing the five-function surface.
- `lib/agent/session_context/summarizers.rb` — pass `timeout_seconds:` into adapters.
- `lib/agent/session_context/summarizers/claude.rb` — use the shared runner and translate bounded-runner failures.
- `lib/agent/session_context/summarizers/codex.rb` — use the shared runner and translate bounded-runner failures.
- `lib/agent/session_context/cli.rb` — parse `--timeout`, load config after resolving the session, and announce the effective value.
- `test/load_test.rb` — load the new error and eager-loaded objects.
- `test/builder_test.rb` — cover Ruby API timeout forwarding and custom-callable rejection.
- `test/claude_summarizer_test.rb` — cover timeout wiring and provider-attributed failures.
- `test/codex_summarizer_test.rb` — cover timeout wiring and provider-attributed failures.
- `test/cli_test.rb` — cover option scope, precedence, announcements, and config errors.
- `README.md` — document configuration, precedence, and per-call semantics; replace resolved residual risks.
- `CHANGELOG.md` — include runtime limits in the unpublished 0.1.0 entry.

## Task 1: Safe Layered Timeout Configuration

**Files:**

- Create: `test/config_test.rb`
- Create: `lib/agent/session_context/config.rb`
- Modify: `lib/agent/session_context/errors.rb`
- Modify: `test/load_test.rb`

- [ ] **Step 1: Write failing error and default/precedence tests**

Create tests around a session value with `project_path` and temporary HOME/XDG/project directories. The first cases must express the intended API and precedence:

```ruby
class ConfigTest < Minitest::Test
  Session = Data.define(:project_path)

  def test_default_timeout_is_five_minutes
    config = Agent::SessionContext::Config.load(session: Session.new(project_path: nil), env: {})

    assert_equal 300, config.timeout_seconds
    assert_predicate config, :frozen?
  end

  def test_explicit_value_overrides_project_and_user_files
    with_config_tree(user: 120, project: 45) do |session, env|
      config = Agent::SessionContext::Config.load(session:, env:, timeout: 15)

      assert_equal 15, config.timeout_seconds
    end
  end

  def test_project_file_overrides_user_file
    with_config_tree(user: 120, project: 45) do |session, env|
      assert_equal 45, Agent::SessionContext::Config.load(session:, env:).timeout_seconds
    end
  end
end
```

Add `ConfigurationError` to `test/load_test.rb` before defining it.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```text
/Users/luciang/.rubies/ruby-4.0.1/bin/ruby -S bundle exec /Users/luciang/.rubies/ruby-4.0.1/bin/ruby -Itest test/config_test.rb test/load_test.rb
```

Expected: failures naming missing `Agent::SessionContext::Config` and `ConfigurationError`.

- [ ] **Step 3: Implement the immutable loader and error**

Add the error:

```ruby
class ConfigurationError < Error; end
```

Implement this public shape in `config.rb`:

```ruby
require "pathname"
require "psych"

module Agent
  module Context
    Config = Data.define(:timeout_seconds) do
      DEFAULT_TIMEOUT_SECONDS = 300
      MIN_TIMEOUT_SECONDS = 1
      MAX_TIMEOUT_SECONDS = 3600

      class << self
        def load(session:, env: ENV, timeout: nil)
          user = load_file(user_path(env))
          project = load_file(project_path(session))
          selected = if timeout.nil?
            project.nil? ? (user.nil? ? DEFAULT_TIMEOUT_SECONDS : user) : project
          else
            timeout
          end
          new(timeout_seconds: validate_timeout!(selected, source: timeout.nil? ? "configuration" : "timeout"))
        end

        # user_path chooses exactly one XDG-or-HOME location.
        # project_path accepts only an absolute recorded project path.
        # load_file returns nil for a missing file, validates regular files,
        # safe-loads YAML, rejects unknown keys, and returns timeout_seconds.
      end
    end
  end
end
```

Keep helpers private. `validate_timeout!` accepts only finite `Numeric` values in `1..3600`, retains integers as integers, and raises `ConfigurationError` with the source/path but never file content. Rescue `Psych::Exception`, `SystemCallError`, and encoding errors into `ConfigurationError`.

- [ ] **Step 4: Add the complete schema/path boundary matrix**

Extend `test/config_test.rb` with explicit cases for:

```ruby
[
  nil,
  "",
  "---\n",
  "summarize: {}\n"
]
```

and failure cases for:

```ruby
[
  "unknown: true\n",
  "summarize: 300\n",
  "summarize:\n  unknown: 300\n",
  "summarize:\n  timeout_seconds: false\n",
  "summarize:\n  timeout_seconds: .inf\n",
  "--- &defaults\nsummarize: *defaults\n",
  "--- !ruby/object:Object {}\n"
]
```

Also cover 1 and 3600 as valid, values immediately outside as invalid, an
explicit `false` override as invalid, an absolute XDG path winning over HOME
even when its file is missing, a relative XDG path falling back to an absolute
HOME, a relative HOME being ignored, a relative session project path being
ignored, a project path independent of `Dir.pwd`, and a config path that is a
directory.

- [ ] **Step 5: Run focused tests and verify GREEN**

Run the Task 1 command again.

Expected: all config/load tests pass with zero warnings under `RUBYOPT=-w`.

- [ ] **Step 6: Commit Task 1**

Commit with Lore intent `Make provider duration policy deterministic across environments`, recording safe YAML and the project-over-user requirement in trailers.

## Task 2: Streaming Bounded Subprocess Runner

**Files:**

- Create: `test/subprocess_runner_test.rb`
- Create: `lib/agent/session_context/subprocess_runner.rb`
- Modify: `test/load_test.rb`

- [ ] **Step 1: Write failing success, timeout, and output-bound tests**

Drive real children through `RbConfig.ruby`, not a mock. Express the interface first:

```ruby
runner = Agent::SessionContext::SubprocessRunner.new(
  timeout_seconds: 1,
  max_output_bytes: 32
)

stdout, stderr, status = runner.call(
  env: {},
  argv: [RbConfig.ruby, "-e", "STDOUT.write(STDIN.read.upcase); STDERR.write('note')"],
  stdin_data: "hello"
)

assert_equal "HELLO", stdout
assert_equal "note", stderr
assert_predicate status, :success?
```

Add a timeout case using a child that writes its PID to stdout, flushes, then sleeps. Assert `SubprocessRunner::TimeoutError`, an upper elapsed-time bound, and that `Process.kill(0, pid)` raises `Errno::ESRCH` after the call returns. Add stdout and stderr cases where exactly 32 bytes succeeds and 33 bytes raises `OutputLimitError` naming only the stream and bound.

- [ ] **Step 2: Run the focused runner test and verify RED**

Run:

```text
RUBYOPT=-w /Users/luciang/.rubies/ruby-4.0.1/bin/ruby -S bundle exec /Users/luciang/.rubies/ruby-4.0.1/bin/ruby -Itest test/subprocess_runner_test.rb
```

Expected: failure naming missing `Agent::SessionContext::SubprocessRunner`.

- [ ] **Step 3: Implement runner types and normal capture**

Define internal failures carrying metadata rather than output:

```ruby
class TimeoutError < StandardError
  attr_reader :timeout_seconds
end

class OutputLimitError < StandardError
  attr_reader :stream, :max_output_bytes
end
```

The runner constructor validates positive timeout/output limits and accepts default test seams:

```ruby
def initialize(
  timeout_seconds:,
  max_output_bytes:,
  clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
  termination_grace_seconds: 0.5
)
```

Use `Open3.popen3(env, *argv, unsetenv_others: true, **process_group_options)`. Put stdin writing on one thread, use `IO.select` plus `read_nonblock` to drain stdout and stderr in the controlling thread, and retain no more than `max_output_bytes` per stream. The loop ends only when the child has exited, both output streams reached EOF, and the stdin writer has finished.

- [ ] **Step 4: Implement deadline and cleanup guarantees**

Calculate one monotonic deadline before spawn. Every loop iteration uses the remaining duration as the maximum `IO.select` wait. On timeout or overflow:

```ruby
terminate_process_group(wait_thread.pid, wait_thread)
raise TimeoutError.new(timeout_seconds)
```

Termination sends `TERM`, waits the fixed grace period, sends `KILL` if the wait thread remains alive, then reads `wait_thread.value` to reap. Close all pipes and join the stdin writer in `ensure`; ignore only expected `Errno::EPIPE`/closed-IO writer failures caused by child termination. On POSIX signal `-pid`; use direct-child best effort on Windows.

- [ ] **Step 5: Add concurrency and process-group regressions**

Add tests proving:

- a child can write more than a pipe buffer to both stdout and stderr without deadlock when the configured limit is larger;
- a child that never reads a large stdin still times out;
- output errors contain no emitted secret bytes;
- on POSIX, a child-spawned sleeping grandchild is gone after timeout;
- the child is reaped after output overflow as well as timeout.

Use polling with a monotonic deadline for process-disappearance assertions rather than fixed sleeps.

- [ ] **Step 6: Run runner and eager-load tests on Ruby 3.2 and 4.0**

Run `test/subprocess_runner_test.rb test/load_test.rb` under both configured Rubies.

Expected: all pass; only the POSIX descendant assertion may be skipped on Windows.

- [ ] **Step 7: Commit Task 2**

Commit with Lore intent `Stop provider processes at the resource boundary`, recording POSIX group cleanup and the Windows limitation.

## Task 3: Route Claude and Codex Through the Shared Runner

**Files:**

- Modify: `test/claude_summarizer_test.rb`
- Modify: `test/codex_summarizer_test.rb`
- Modify: `lib/agent/session_context/summarizers/claude.rb`
- Modify: `lib/agent/session_context/summarizers/codex.rb`
- Modify: `lib/agent/session_context/summarizers.rb`
- Modify: `test/builder_test.rb`

- [ ] **Step 1: Write failing adapter construction and translation tests**

For both adapters, inject a fake runner object and keep the current callable contract unchanged. Add a separate fake `SubprocessRunner` constructor seam or stub `.new` to assert:

```ruby
Agent::SessionContext::Summarizers::Codex.new(timeout_seconds: 42)
Agent::SessionContext::Summarizers::Claude.new(timeout_seconds: 42)
```

construct their default runner with `timeout_seconds: 42` and the adapter's existing `MAX_OUTPUT_BYTES`.

Raise `SubprocessRunner::TimeoutError` and `OutputLimitError` from injected runners and assert provider-attributed `SummarizerFailed` messages contain the timeout/stream/bound but not prompt or output fragments.

Update the factory tests to require:

```ruby
Agent::SessionContext::Summarizers.for(:codex, timeout_seconds: 42)
Agent::SessionContext::Summarizers.for(:claude, timeout_seconds: 42)
```

- [ ] **Step 2: Run adapter/factory tests and verify RED**

Run Claude, Codex, and builder tests together.

Expected: keyword-argument and missing failure-translation failures.

- [ ] **Step 3: Wire the default runner without changing injected runners**

Change each initializer to:

```ruby
def initialize(runner: nil, timeout_seconds: Config::DEFAULT_TIMEOUT_SECONDS)
  @runner = runner || SubprocessRunner.new(
    timeout_seconds:,
    max_output_bytes: MAX_OUTPUT_BYTES
  )
end
```

Remove direct `Open3.capture3` usage and its `require "open3"`; keep `run!` calling
`@runner.call(env:, argv:, stdin_data:)`. Rescue the runner's typed failures in
`run!` and translate them using provider-specific, content-free messages. Keep
`validate_runner_response!` and post-return bounds so arbitrary injected runners
remain defensive.

Change the factory to:

```ruby
def for(name, timeout_seconds: Config::DEFAULT_TIMEOUT_SECONDS)
  case normalize_name(name)
  when :codex then Codex.new(timeout_seconds:)
  when :claude then Claude.new(timeout_seconds:)
  else raise unsupported_summarizer(name)
  end
end
```

- [ ] **Step 4: Run adapter/factory tests and verify GREEN**

Expected: all existing argv, environment, tempfile, JSON, error, and new timeout tests pass.

- [ ] **Step 5: Commit Task 3**

Commit with Lore intent `Apply one execution boundary to both provider adapters`.

## Task 4: Expose Effective Timeout Through Ruby and CLI

**Files:**

- Modify: `test/builder_test.rb`
- Modify: `test/cli_test.rb`
- Modify: `lib/agent/session_context.rb`
- Modify: `lib/agent/session_context/cli.rb`

- [ ] **Step 1: Write failing Ruby API tests**

Stub or inject a config loader and factory so the test observes behavior rather than real files. Cover:

```ruby
Agent::SessionContext.summarize(session, using: :codex, timeout: 12, catalog:)
```

forwarding `timeout_seconds: 12` to `Summarizers.for`, configuration loading when no explicit value is present, and:

```ruby
assert_raises(ArgumentError) do
  Agent::SessionContext.summarize(session, summarizer: custom, timeout: 12)
end
```

Also prove `summarizer: custom` without timeout does not read configuration.

- [ ] **Step 2: Write failing CLI option/precedence/error tests**

Extend the fake backend factory to record hashes:

```ruby
def for(name, timeout_seconds:)
  @calls << {name: name.to_sym, timeout_seconds:}
  @backends.fetch(name.to_sym)
end
```

Add a fake config loader returning `Config.new(timeout_seconds: ...)`. Test:

- default/config timeout reaches the factory;
- `--timeout 12.5` overrides loader layers;
- announcement is `summarizing with codex (timeout: 12.5s)`;
- `--timeout` is rejected for `show` and `prompts`;
- missing, nonnumeric, NaN, below-range, and above-range CLI values fail;
- a `ConfigurationError` after session resolution uses the existing text and JSON paths and never calls the factory;
- help documents the option, range, and per-call meaning;
- POSIXLY_CORRECT does not change parsing.

- [ ] **Step 3: Run API/CLI tests and verify RED**

Run `test/builder_test.rb test/cli_test.rb` under Ruby 4.

Expected: missing keyword forwarding, option, loader, and announcement failures.

- [ ] **Step 4: Implement Ruby API resolution**

Use explicit keywords while preserving the five module functions:

```ruby
def summarize(
  session,
  using: nil,
  summarizer: nil,
  timeout: nil,
  env: ENV,
  config_loader: Config,
  backend_factory: Summarizers,
  **options
)
  if summarizer && !timeout.nil?
    fail ArgumentError, "timeout applies only to built-in summarizers"
  end

  backend = summarizer || begin
    config = config_loader.load(session:, env:, timeout:)
    backend_factory.for(using || session.agent, timeout_seconds: config.timeout_seconds)
  end

  Builder.new(**options).summarize(session, summarizer: backend)
end
```

- [ ] **Step 5: Implement CLI parsing and construction**

Add `--timeout` only to `LONG_OPTION_RULES[:summarize]`, parse it with `OptionParser` numeric conversion, and include `timeout: nil` in selection. Add `config_loader: Config` to the CLI constructor.

After resolving the session:

```ruby
config = @config_loader.load(session:, env: @env, timeout: selection.fetch(:timeout))
timeout_seconds = config.timeout_seconds
@stderr.puts "summarizing with #{safe_text(backend_name)} (timeout: #{format_timeout(timeout_seconds)}s)"
summarizer = @backend_factory.for(backend_name, timeout_seconds:)
```

Keep formatting deterministic: integers render without `.0`; fractional values use their concise decimal representation. Config validation remains the single range/finite-value authority.

- [ ] **Step 6: Run API/CLI tests and verify GREEN**

Run the focused tests with and without `POSIXLY_CORRECT=1` on Ruby 3.2 and 4.0.

Expected: all pass and machine output remains valid.

- [ ] **Step 7: Commit Task 4**

Commit with Lore intent `Let each analyzed project bound its provider calls`.

## Task 5: Documentation, Regression Matrix, and Package Verification

**Files:**

- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Modify: tests if final integration gaps are found

- [ ] **Step 1: Update README and changelog**

Add a `Configuration` section showing both file locations and:

```yaml
summarize:
  timeout_seconds: 300
```

Document precedence, the 1–3600 bound, project resolution from recorded
`project_path`, per-provider-call semantics, `--timeout`, Ruby `timeout:`, and
custom summarizer ownership. Remove the resolved `capture3` buffering/no-timeout
risks. Retain the Windows descendant-tree limitation and the possibility that a
remote request already left the machine before local termination.

Add a 0.1.0 changelog bullet because the version remains unpublished.

- [ ] **Step 2: Run warning-enabled full suites**

Run:

```text
RUBYOPT=-w /Users/luciang/.rubies/ruby-3.2.0/bin/ruby -S bundle exec rake
RUBYOPT=-w /Users/luciang/.rubies/ruby-4.0.1/bin/ruby -S bundle exec rake
```

Expected: zero failures, errors, skips attributable to the project, or project warnings.

- [ ] **Step 3: Run syntax, eager-load, and diff checks**

Use a temporary stdlib-only Ruby script to compile every `lib/**/*.rb` and
`test/**/*.rb` file under both Rubies. Run `Zeitwerk::Loader.eager_load_all` under
both Rubies, `git diff --check`, and the CLI test with `POSIXLY_CORRECT=1`.

Expected: all exit zero.

- [ ] **Step 4: Build and inspect the gem**

Run `gem build agent-session_context.gemspec`. Inspect the resulting package with a
temporary stdlib-only Ruby script using `Gem::Package`: verify version 0.1.0,
the two runtime dependencies, executable mode, all new library files, README,
changelog, license, and public repository metadata. Confirm no tests, lockfile,
generated gem, or absolute host path is packaged.

- [ ] **Step 5: Install the built artifact in isolation**

Using `Dir.mktmpdir`, install the built gem and published dependencies into an
isolated `GEM_HOME` under Ruby 3.2 and 4.0. Run `require "agent/session_context"`,
`agent-session-context version`, and `agent-session-context help`; verify the timeout option is
present in installed help.

- [ ] **Step 6: Clean generated artifacts and inspect the branch**

Delete only the generated `.gem`, untracked `Gemfile.lock`, and temporary
scripts. Verify `git status --short`, `git diff --check`, and the commit diff.

- [ ] **Step 7: Commit Task 5**

Commit with Lore intent `Document and package bounded provider execution`, with
full verification and explicit live-provider gaps in trailers.

- [ ] **Step 8: Request independent review and address findings**

Run one whole-branch code review focused on process cleanup, deadlocks, config
trust boundaries, secret leakage, Ruby 3.2 compatibility, and package contract.
Fix Critical and Important findings through new red-green tests, rerun the full
matrix, and record any accepted Minor residual risk.

## Completion Criteria

- Built-in Claude and Codex calls cannot exceed the configured per-call timeout.
- Retained stdout and stderr buffers cannot exceed 1 MiB before failure; only
  one bounded read chunk per active stream may exist transiently.
- Timed-out or noisy provider children are terminated and reaped.
- CLI, project YAML, user YAML, and built-in precedence matches the approved design.
- `show` and `prompts` neither read config nor accept `--timeout`.
- Custom summarizer behavior is explicit and unchanged unless paired with the rejected `timeout:` keyword.
- Ruby 3.2 and 4.0 suites, eager loading, syntax, package inspection, and isolated install all pass.
- No push, tag, RubyGems publication, or live provider call occurs without separate authorization.
