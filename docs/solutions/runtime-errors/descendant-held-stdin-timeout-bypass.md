---
title: SubprocessRunner deadline escaped when a descendant retained stdin
date: "2026-08-28"
category: runtime-errors
problem_type: runtime_error
component: Agent::SessionContext::SubprocessRunner
severity: high
symptoms:
  - A provider call could return or hang after its configured timeout.
  - The direct child had exited while a descendant still held inherited stdin.
root_cause: async_timing
tags:
  - subprocess-runner
  - stdin-inheritance
  - descendant-process
  - deadline-enforcement
ruby_versions:
  - 3.2.3
  - 4.0.1
relevant_commits:
  base: 68a5071
  fix: 0b7248b
relevant_files:
  - lib/agent/session_context/subprocess_runner.rb
  - test/subprocess_runner_test.rb
---

# Descendant-held stdin bypassed the subprocess deadline

## Problem

The runner treated a call as complete when the direct child had exited and
stdout and stderr had reached EOF. It then joined the stdin writer thread
outside the monitored deadline.

A direct child could spawn a descendant that inherited stdin, redirect the
descendant's output elsewhere, and exit. With a prompt larger than the pipe
capacity, the writer remained blocked on the descendant even though the direct
child and both observed output streams appeared complete. The configured
timeout no longer governed that final join.

## Root cause

The completion predicate covered only two boundaries:

```ruby
break if status && streams.empty?
```

It omitted a third boundary owned by the runner: the stdin writer thread. The
existing large-stdin test kept the direct child alive, so it never exercised
the false-success state where only a descendant retained stdin.

## Fix

Successful completion now requires all three conditions:

1. the direct child has a final status;
2. stdout and stderr have reached EOF;
3. the stdin writer has finished without an unexpected error.

```ruby
stdin_writer_finished = stdin_writer_finished?(stdin_thread)
break if status && streams.empty? && stdin_writer_finished
```

When no output streams remain, child and writer joins spend from one shared,
bounded polling interval. The loop therefore continues checking the same
monotonic deadline instead of stacking waits or falling through to an
unbounded join.

On timeout, the existing cleanup path terminates the POSIX process group,
closes stdin, joins the writer, and reaps the direct child before raising. This
matters because the process that owns the blocking pipe may be a descendant,
not the original child.

## Regression proof

`test_descendant_holding_stdin_still_times_out` creates the exact process shape:

- the runner writes a payload larger than pipe capacity;
- the child spawns a sleeping grandchild that inherits stdin;
- the grandchild redirects stdout and stderr to `File::NULL`;
- the child records both PIDs and exits immediately.

Before the fix, the runner exceeded its own deadline and only the test's outer
watchdog stopped it. After the fix, it raises
`SubprocessRunner::TimeoutError`, returns within the generous elapsed bound,
and the grandchild is gone. The regression passes on Ruby 3.2.3 and 4.0.1.

## Prevention checklist

- Define success as the absence of every runner-owned completion blocker, not
  merely direct-child exit.
- Keep helper-thread liveness inside the same monotonic deadline as process and
  output monitoring.
- Review every `join`, `value`, `read`, and `write` that runs after a completion
  predicate; none may introduce a new unbounded wait.
- Use one shared poll budget when waiting on multiple threads or streams.
- Test inherited stdin and inherited output separately on POSIX, because either
  can outlive the direct child.
- Give hang regressions an outer watchdog so a failure is deterministic.
- Limit Windows claims to direct-child termination and reaping until stronger
  descendant containment is implemented and verified there.

## Related references

- `docs/superpowers/specs/2026-08-27-summarizer-runtime-limits-design.md`
- `docs/superpowers/plans/2026-08-27-summarizer-runtime-limits.md`
- `README.md` — Privacy and Isolation; V1 Non-goals and Roadmap
