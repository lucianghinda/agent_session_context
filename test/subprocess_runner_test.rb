# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"
require "rbconfig"
require "timeout"

class SubprocessRunnerTest < Minitest::Test
  RUBY = RbConfig.ruby

  def test_successfully_returns_stdout_stderr_and_status
    runner = build_runner(timeout_seconds: 1.0, max_output_bytes: 64)

    stdout, stderr, status = runner.call(
      env: { "LC_ALL" => "C" },
      argv: ruby_command('STDOUT.write(STDIN.read.upcase); STDERR.write("warn\\n")'),
      stdin_data: "hello\n"
    )

    assert_equal "HELLO\n".b, stdout
    assert_equal "warn\n".b, stderr
    assert_predicate status, :success?
  end

  def test_runner_hides_inherited_env_and_keeps_explicit_env
    runner = build_runner(timeout_seconds: 1.0, max_output_bytes: 256)
    inherited_key = "AGENT_CONTEXT_INHERITED_SECRET"
    explicit_key = "AGENT_CONTEXT_VISIBLE_VALUE"
    inherited_secret = "parent-secret-token"
    parent_visible_value = "parent-visible-value"
    explicit_value = "child-visible"
    inherited_original = capture_env_entry(inherited_key)
    explicit_original = capture_env_entry(explicit_key)
    ENV[inherited_key] = inherited_secret
    ENV[explicit_key] = parent_visible_value
    probe = <<~RUBY
      require "json"
      STDOUT.write(
        JSON.generate(
          inherited_present: ENV.key?(#{inherited_key.dump}),
          explicit_value: ENV[#{explicit_key.dump}]
        )
      )
    RUBY

    inherited_stdout, inherited_stderr, inherited_status = Open3.capture3(
      { explicit_key => explicit_value },
      *ruby_command(probe)
    )
    inherited_payload = JSON.parse(inherited_stdout)

    assert_predicate inherited_status, :success?
    assert_equal true, inherited_payload.fetch("inherited_present")
    assert_equal explicit_value, inherited_payload.fetch("explicit_value")
    refute inherited_stdout.include?(inherited_secret), "control stdout leaked inherited secret"
    refute inherited_stderr.include?(inherited_secret), "control stderr leaked inherited secret"

    stdout, stderr, status = runner.call(
      env: { explicit_key => explicit_value },
      argv: ruby_command(probe),
      stdin_data: nil
    )
    payload = JSON.parse(stdout)

    refute payload.fetch("inherited_present")
    assert_equal explicit_value, payload.fetch("explicit_value")
    assert_equal inherited_secret, ENV.fetch(inherited_key)
    assert_equal parent_visible_value, ENV.fetch(explicit_key)
    refute stdout.include?(inherited_secret), "child stdout leaked inherited secret"
    refute stderr.include?(inherited_secret), "child stderr leaked inherited secret"
    assert_equal "".b, stderr
    assert_predicate status, :success?
  ensure
    restore_env_entry(inherited_key, inherited_original)
    restore_env_entry(explicit_key, explicit_original)
  end

  def test_exact_stdout_limit_succeeds
    stdout = "x" * 16
    runner = build_runner(timeout_seconds: 1.0, max_output_bytes: stdout.bytesize)

    actual_stdout, actual_stderr, status = runner.call(
      env: {},
      argv: ruby_command("STDOUT.write(#{stdout.dump})"),
      stdin_data: nil
    )

    assert_equal stdout.b, actual_stdout
    assert_equal "".b, actual_stderr
    assert_predicate status, :success?
  end

  def test_stdout_limit_plus_one_raises_output_limit_error
    runner = build_runner(timeout_seconds: 1.0, max_output_bytes: 8)

    error = assert_raises(Agent::SessionContext::SubprocessRunner::OutputLimitError) do
      runner.call(
        env: {},
        argv: ruby_command('STDOUT.write("123456789")'),
        stdin_data: nil
      )
    end

    assert_equal :stdout, error.stream
    assert_equal 8, error.max_output_bytes
    refute_includes error.message, "123456789"
  end

  def test_exact_stderr_limit_succeeds
    stderr = "y" * 16
    runner = build_runner(timeout_seconds: 1.0, max_output_bytes: stderr.bytesize)

    actual_stdout, actual_stderr, status = runner.call(
      env: {},
      argv: ruby_command("STDERR.write(#{stderr.dump})"),
      stdin_data: nil
    )

    assert_equal "".b, actual_stdout
    assert_equal stderr.b, actual_stderr
    assert_predicate status, :success?
  end

  def test_stderr_limit_plus_one_raises_output_limit_error
    runner = build_runner(timeout_seconds: 1.0, max_output_bytes: 8)

    error = assert_raises(Agent::SessionContext::SubprocessRunner::OutputLimitError) do
      runner.call(
        env: {},
        argv: ruby_command('STDERR.write("abcdefghi")'),
        stdin_data: nil
      )
    end

    assert_equal :stderr, error.stream
    assert_equal 8, error.max_output_bytes
    refute_includes error.message, "abcdefghi"
  end

  def test_errors_do_not_include_secret_output_or_command_content
    secret = "super-secret-token"
    output_limit_runner = build_runner(timeout_seconds: 0.25, max_output_bytes: 8)
    timeout_runner = build_runner(timeout_seconds: 0.25, max_output_bytes: 64)

    output_error = assert_raises(Agent::SessionContext::SubprocessRunner::OutputLimitError) do
      output_limit_runner.call(
        env: {},
        argv: ruby_command("STDOUT.write(#{(secret * 2).dump})"),
        stdin_data: nil
      )
    end

    refute_includes output_error.message, secret

    timeout_error = assert_raises(Agent::SessionContext::SubprocessRunner::TimeoutError) do
      timeout_runner.call(
        env: {},
        argv: ruby_command(<<~RUBY),
          secret_argv = #{secret.dump}
          $stdout.sync = true
          $stderr.sync = true
          STDERR.write(secret_argv)
          STDOUT.write(secret_argv)
          sleep 5
        RUBY
        stdin_data: nil
      )
    end

    refute_includes timeout_error.message, secret
    assert_equal 0.25, timeout_error.timeout_seconds
  end

  def test_sleeping_child_times_out_and_is_reaped
    with_tmpdir do |tmpdir|
      pid_path = File.join(tmpdir, "pid.txt")
      runner = build_runner(timeout_seconds: 0.35, max_output_bytes: 64)
      started_at = monotonic_now
      pid = nil

      error = assert_raises(Agent::SessionContext::SubprocessRunner::TimeoutError) do
        runner.call(
          env: { "PID_PATH" => pid_path },
          argv: ruby_command(<<~RUBY),
            File.write(ENV.fetch("PID_PATH"), Process.pid.to_s)
            sleep 5
          RUBY
          stdin_data: nil
        )
      end

      elapsed = monotonic_now - started_at
      pid = read_recorded_integers(pid_path).first

      assert_operator elapsed, :<, 3.0
      assert_equal 0.35, error.timeout_seconds
      assert_eventually("expected child #{pid} to exit") { !process_alive?(pid) }
    ensure
      best_effort_cleanup_processes(pid)
    end
  end

  def test_large_stdout_and_stderr_do_not_deadlock
    output_size = 200_000
    stdout = "o" * output_size
    stderr = "e" * output_size
    runner = build_runner(timeout_seconds: 2.0, max_output_bytes: 250_000)

    actual_stdout, actual_stderr, status = runner.call(
      env: {},
      argv: ruby_command(<<~RUBY),
        out = "o" * #{output_size}
        err = "e" * #{output_size}
        threads = []
        threads << Thread.new { STDOUT.write(out) }
        threads << Thread.new { STDERR.write(err) }
        threads.each(&:join)
      RUBY
      stdin_data: nil
    )

    assert_equal stdout.b, actual_stdout
    assert_equal stderr.b, actual_stderr
    assert_predicate status, :success?
  end

  def test_large_stdin_does_not_block_timeout_enforcement
    runner = build_runner(timeout_seconds: 0.25, max_output_bytes: 32)
    large_input = "z" * 2_000_000

    started_at = monotonic_now

    assert_raises(Agent::SessionContext::SubprocessRunner::TimeoutError) do
      runner.call(
        env: {},
        argv: ruby_command("sleep 5"),
        stdin_data: large_input
      )
    end

    assert_operator monotonic_now - started_at, :<, 3.0
  end

  def test_descendant_holding_stdin_still_times_out
    skip "POSIX only" if Gem.win_platform?

    with_tmpdir do |tmpdir|
      pid_path = File.join(tmpdir, "pids.txt")
      runner = build_runner(timeout_seconds: 0.35, max_output_bytes: 32, termination_grace_seconds: 0.1)
      large_input = "z" * 2_000_000
      child_pid = nil
      grandchild_pid = nil
      started_at = monotonic_now

      error = assert_raises(Agent::SessionContext::SubprocessRunner::TimeoutError) do
        Timeout.timeout(4) do
          runner.call(
            env: { "PID_PATH" => pid_path },
            argv: ruby_command(<<~RUBY),
              require "rbconfig"
              grandchild_pid = Process.spawn(
                RbConfig.ruby,
                "-e",
                "sleep 5",
                out: File::NULL,
                err: File::NULL
              )
              File.write(ENV.fetch("PID_PATH"), [Process.pid, grandchild_pid].join(","))
              exit! 0
            RUBY
            stdin_data: large_input
          )
        end
      end

      child_pid, grandchild_pid = read_recorded_integers(pid_path)

      assert_equal 0.35, error.timeout_seconds
      assert_operator monotonic_now - started_at, :<, 3.0
      assert_eventually("expected grandchild #{grandchild_pid} to exit") { !process_alive?(grandchild_pid) }
    ensure
      best_effort_cleanup_process_group(child_pid)
      best_effort_cleanup_processes(child_pid, grandchild_pid)
    end
  end

  def test_continuously_readable_output_still_times_out
    runner = build_runner(timeout_seconds: 0.3, max_output_bytes: 250_000_000)
    started_at = monotonic_now

    error = assert_raises(Agent::SessionContext::SubprocessRunner::TimeoutError) do
      Timeout.timeout(4) do
        runner.call(
          env: {},
          argv: ruby_command(<<~RUBY),
            $stdout.sync = true
            $stderr.sync = true
            chunk = "x" * 4096
            threads = []
            threads << Thread.new { loop { STDOUT.write(chunk) } }
            threads << Thread.new { loop { STDERR.write(chunk) } }
            threads.each(&:join)
          RUBY
          stdin_data: nil
        )
      end
    end

    assert_equal 0.3, error.timeout_seconds
    assert_operator monotonic_now - started_at, :<, 3.0
  end

  def test_clock_failure_after_spawn_re_raises_and_reaps_child
    with_tmpdir do |tmpdir|
      pid_path = File.join(tmpdir, "pid.txt")
      runner = build_runner(
        timeout_seconds: 2.0,
        max_output_bytes: 32,
        clock: ExplodingClock.new(pid_path:, error: RuntimeError.new("clock exploded"))
      )
      pid = nil

      error = assert_raises(RuntimeError) do
        runner.call(
          env: { "PID_PATH" => pid_path },
          argv: ruby_command(<<~RUBY),
            File.write(ENV.fetch("PID_PATH"), Process.pid.to_s)
            sleep 5
          RUBY
          stdin_data: nil
        )
      end

      pid = read_recorded_integers(pid_path).first

      assert_equal "clock exploded", error.message
      assert_eventually("expected child #{pid} to exit") { !process_alive?(pid) }
    ensure
      best_effort_cleanup_processes(pid)
    end
  end

  def test_timeout_terminates_sleeping_grandchild_on_posix
    skip "POSIX only" if Gem.win_platform?

    with_tmpdir do |tmpdir|
      pid_path = File.join(tmpdir, "pids.txt")
      runner = build_runner(timeout_seconds: 0.3, max_output_bytes: 32, termination_grace_seconds: 0.1)
      child_pid = nil
      grandchild_pid = nil

      assert_raises(Agent::SessionContext::SubprocessRunner::TimeoutError) do
        runner.call(
          env: { "PID_PATH" => pid_path },
          argv: ruby_command(<<~RUBY),
            require "rbconfig"
            grandchild_pid = Process.spawn(RbConfig.ruby, "-e", "sleep 5")
            File.write(ENV.fetch("PID_PATH"), [Process.pid, grandchild_pid].join(","))
            sleep 5
          RUBY
          stdin_data: nil
        )
      end

      child_pid, grandchild_pid = read_recorded_integers(pid_path)

      assert_eventually("expected child #{child_pid} to exit") { !process_alive?(child_pid) }
      assert_eventually("expected grandchild #{grandchild_pid} to exit") { !process_alive?(grandchild_pid) }
    ensure
      best_effort_cleanup_process_group(child_pid)
      best_effort_cleanup_processes(child_pid, grandchild_pid)
    end
  end

  def test_timeout_kills_term_ignoring_grandchild_after_parent_exits
    skip "POSIX only" if Gem.win_platform?

    with_tmpdir do |tmpdir|
      pid_path = File.join(tmpdir, "pids.txt")
      runner = build_runner(timeout_seconds: 0.3, max_output_bytes: 32, termination_grace_seconds: 0.2)
      child_pid = nil
      grandchild_pid = nil

      assert_raises(Agent::SessionContext::SubprocessRunner::TimeoutError) do
        runner.call(
          env: { "PID_PATH" => pid_path },
          argv: ruby_command(<<~RUBY),
            require "rbconfig"
            child_term = <<~'INNER'
              trap("TERM") { exit! 0 }
              sleep 5
            INNER
            grandchild = <<~'INNER'
              trap("TERM") { }
              $stdout.sync = true
              sleep 5
            INNER
            grandchild_pid = Process.spawn(RbConfig.ruby, "-e", grandchild)
            File.write(ENV.fetch("PID_PATH"), [Process.pid, grandchild_pid].join(","))
            eval(child_term, binding, __FILE__, __LINE__)
          RUBY
          stdin_data: nil
        )
      end

      child_pid, grandchild_pid = read_recorded_integers(pid_path)

      assert_eventually("expected grandchild #{grandchild_pid} to exit") { !process_alive?(grandchild_pid) }
    ensure
      best_effort_cleanup_process_group(child_pid)
      best_effort_cleanup_processes(child_pid, grandchild_pid)
    end
  end

  def test_output_overflow_terminates_and_reaps_child
    with_tmpdir do |tmpdir|
      pid_path = File.join(tmpdir, "pid.txt")
      runner = build_runner(timeout_seconds: 1.0, max_output_bytes: 8, termination_grace_seconds: 0.1)
      pid = nil

      error = assert_raises(Agent::SessionContext::SubprocessRunner::OutputLimitError) do
        runner.call(
          env: { "PID_PATH" => pid_path },
          argv: ruby_command(<<~RUBY),
            $stdout.sync = true
            File.write(ENV.fetch("PID_PATH"), Process.pid.to_s)
            STDOUT.write("123456789")
            sleep 5
          RUBY
          stdin_data: nil
        )
      end

      pid = read_recorded_integers(pid_path).first

      assert_equal :stdout, error.stream
      assert_eventually("expected child #{pid} to exit") { !process_alive?(pid) }
    ensure
      best_effort_cleanup_processes(pid)
    end
  end

  def test_constructor_validates_arguments
    assert_raises(ArgumentError) { Agent::SessionContext::SubprocessRunner.new(timeout_seconds: 0, max_output_bytes: 1) }
    assert_raises(ArgumentError) { Agent::SessionContext::SubprocessRunner.new(timeout_seconds: Float::INFINITY, max_output_bytes: 1) }
    assert_raises(ArgumentError) { Agent::SessionContext::SubprocessRunner.new(timeout_seconds: 1, max_output_bytes: 0) }
    assert_raises(ArgumentError) { Agent::SessionContext::SubprocessRunner.new(timeout_seconds: 1, max_output_bytes: 1, termination_grace_seconds: -1) }
    assert_raises(ArgumentError) { Agent::SessionContext::SubprocessRunner.new(timeout_seconds: 1, max_output_bytes: 1, clock: nil) }
  end

  def test_constructor_rejects_string_timeout_with_validation_message
    error = assert_raises(ArgumentError) do
      Agent::SessionContext::SubprocessRunner.new(timeout_seconds: "1", max_output_bytes: 1)
    end

    assert_equal "timeout_seconds must be a positive finite number", error.message
  end

  def test_constructor_rejects_string_termination_grace_with_validation_message
    error = assert_raises(ArgumentError) do
      Agent::SessionContext::SubprocessRunner.new(timeout_seconds: 1, max_output_bytes: 1,
                                                  termination_grace_seconds: "0.1")
    end

    assert_equal "termination_grace_seconds must be a nonnegative finite number", error.message
  end

  def test_unexpected_ioerror_from_stdin_writer_is_raised
    runner = build_runner(timeout_seconds: 1.0, max_output_bytes: 8)
    fake_stdin = FakeStdin.new(IOError.new("boom"))

    stdin_thread, error_box = runner.send(:start_stdin_writer, fake_stdin, "payload")

    error = assert_raises(IOError) do
      runner.send(:join_stdin_thread!, stdin_thread, error_box)
    end

    assert_equal "boom", error.message
    assert_equal 1, fake_stdin.close_calls
  end

  def test_writer_error_during_monitoring_terminates_and_re_raises
    with_tmpdir do |tmpdir|
      pid_path = File.join(tmpdir, "pid.txt")
      runner = ExplodingWriterRunner.new(
        wait_for: -> { read_recorded_integers(pid_path) },
        writer_error: IOError.new("writer exploded"),
        timeout_seconds: 1.5,
        max_output_bytes: 32,
        termination_grace_seconds: 0.1
      )
      pid = nil
      started_at = monotonic_now

      error = assert_raises(IOError) do
        runner.call(
          env: { "PID_PATH" => pid_path },
          argv: ruby_command(<<~RUBY),
            File.write(ENV.fetch("PID_PATH"), Process.pid.to_s)
            sleep 5
          RUBY
          stdin_data: "payload"
        )
      end

      pid = read_recorded_integers(pid_path).first

      assert_equal "writer exploded", error.message
      assert_operator monotonic_now - started_at, :<, 3.0
      assert_eventually("expected child #{pid} to exit") { !process_alive?(pid) }
    ensure
      best_effort_cleanup_processes(pid)
    end
  end

  def test_windows_termination_falls_back_to_kill_after_term_einval_and_reaps
    runner = build_runner(timeout_seconds: 1.0, max_output_bytes: 8, termination_grace_seconds: 0.1)
    wait_thread = FakeWaitThread.new(pid: 1234)
    calls = []

    Process.stub(:kill, lambda { |signal, pid|
      calls << [signal, pid]
      raise Errno::EINVAL if signal == "TERM"

      1
    }) do
      Gem.stub(:win_platform?, true) do
        runner.send(:terminate_process, wait_thread)
      end
    end

    assert_equal [["TERM", 1234], ["KILL", 1234]], calls
    assert_equal 1, wait_thread.value_calls
    assert_equal 0, wait_thread.join_calls.length
  end

  def test_posix_group_esrch_skips_grace_and_kill
    runner = build_runner(timeout_seconds: 1.0, max_output_bytes: 8, termination_grace_seconds: 0.2)
    sleep_calls = []
    kill_calls = []

    runner.stub(:sleep_cleanup_grace, ->(duration) { sleep_calls << duration }) do
      Process.stub(:kill, lambda { |signal, pid|
        kill_calls << [signal, pid]
        raise Errno::ESRCH if signal == "TERM"

        1
      }) do
        runner.send(:terminate_process_group, 4321)
      end
    end

    assert_equal [["TERM", -4321]], kill_calls
    assert_empty sleep_calls
  end

  private

  def build_runner(timeout_seconds:, max_output_bytes:, termination_grace_seconds: 0.05, clock: nil)
    options = {
      timeout_seconds: timeout_seconds,
      max_output_bytes: max_output_bytes,
      termination_grace_seconds: termination_grace_seconds
    }
    options[:clock] = clock if clock

    Agent::SessionContext::SubprocessRunner.new(**options)
  end

  def capture_env_entry(key)
    return [:present, ENV.fetch(key)] if ENV.key?(key)

    [:absent, nil]
  end

  def restore_env_entry(key, entry)
    presence, value = entry

    if presence == :present
      ENV[key] = value
    else
      ENV.delete(key)
    end
  end

  def ruby_command(source)
    [RUBY, "-e", source]
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def assert_eventually(message, timeout: 3.0)
    deadline = monotonic_now + timeout

    until monotonic_now >= deadline
      return if yield

      sleep 0.01
    end

    assert yield, message
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def with_tmpdir(&)
    Dir.mktmpdir(&)
  end

  def read_recorded_integers(path)
    assert_eventually("expected #{path} to exist") { File.exist?(path) && !File.empty?(path) }

    File.read(path).split(",").map { Integer(_1) }
  end

  def best_effort_cleanup_process_group(leader_pid)
    return unless leader_pid
    return if Gem.win_platform?

    Process.kill("KILL", -leader_pid)
  rescue Errno::ESRCH
    nil
  end

  def best_effort_cleanup_processes(*pids)
    pids.compact.each do |pid|
      Process.kill("KILL", pid)
    rescue Errno::ESRCH
      nil
    end
  end

  class FakeStdin
    attr_reader :close_calls

    def initialize(write_error = nil)
      @write_error = write_error
      @closed = false
      @close_calls = 0
    end

    def write(_payload)
      raise @write_error if @write_error

      nil
    end

    def flush
      nil
    end

    def close
      @closed = true
      @close_calls += 1
    end

    def closed?
      @closed
    end
  end

  class ExplodingClock
    def initialize(pid_path:, error:)
      @pid_path = pid_path
      @error = error
      @raised = false
    end

    def call
      if !@raised && File.exist?(@pid_path) && !File.empty?(@pid_path)
        @raised = true
        raise @error
      end

      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end

  class ExplodingWriterRunner < Agent::SessionContext::SubprocessRunner
    def initialize(wait_for:, writer_error:, **)
      @wait_for = wait_for
      @writer_error = writer_error
      super(**)
    end

    private

    def write_stdin(_stdin, _stdin_data)
      @wait_for.call
      raise @writer_error
    end
  end

  class FakeWaitThread
    attr_reader :join_calls, :value_calls, :pid

    def initialize(pid:, status: :status)
      @pid = pid
      @status = status
      @join_calls = []
      @value_calls = 0
    end

    def join(timeout = nil)
      @join_calls << timeout
      nil
    end

    def value
      @value_calls += 1
      @status
    end
  end
end
