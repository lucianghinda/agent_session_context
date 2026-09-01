# frozen_string_literal: true

require "English"
require "open3"

module Agent
  module SessionContext
    class SubprocessRunner
      DEFAULT_CLOCK = lambda {
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      }
      private_constant :DEFAULT_CLOCK

      class TimeoutError < StandardError
        attr_reader :timeout_seconds

        def initialize(timeout_seconds)
          @timeout_seconds = timeout_seconds
          super("subprocess exceeded #{timeout_seconds} seconds")
        end
      end

      class OutputLimitError < StandardError
        attr_reader :stream, :max_output_bytes

        def initialize(stream:, max_output_bytes:)
          @stream = stream
          @max_output_bytes = max_output_bytes
          super("#{stream} exceeded #{max_output_bytes} bytes")
        end
      end

      def initialize(timeout_seconds:, max_output_bytes:, clock: DEFAULT_CLOCK, termination_grace_seconds: 0.5)
        @timeout_seconds = validate_timeout!(timeout_seconds)
        @max_output_bytes = validate_max_output_bytes!(max_output_bytes)
        @clock = validate_clock!(clock)
        @termination_grace_seconds = validate_termination_grace!(termination_grace_seconds)
      end

      def call(env:, argv:, stdin_data:)
        deadline = monotonic_now + @timeout_seconds
        stdin = stdout = stderr = wait_thread = stdin_thread = nil
        stdin_error = nil
        completed = false
        stdout_buffer = String.new.b
        stderr_buffer = String.new.b

        stdin, stdout, stderr, wait_thread = Open3.popen3(
          env,
          *argv,
          unsetenv_others: true,
          **process_group_options
        )
        prepare_streams!(stdin, stdout, stderr)
        stdin_thread, stdin_error = start_stdin_writer(stdin, stdin_data)

        status = monitor_process(
          deadline:,
          wait_thread:,
          stdout:,
          stderr:,
          stdout_buffer:,
          stderr_buffer:,
          stdin_thread:,
          stdin_error:
        )

        join_stdin_thread!(stdin_thread, stdin_error)
        completed = true
        [stdout_buffer, stderr_buffer, status]
      ensure
        cleanup_call(
          wait_thread:,
          stdin:,
          stdout:,
          stderr:,
          stdin_thread:,
          stdin_error:,
          completed:,
          primary_error: $ERROR_INFO
        )
      end

      private

      def validate_timeout!(value)
        validate_numeric!(value, name: "timeout_seconds", allow_zero: false)
      end

      def validate_max_output_bytes!(value)
        unless value.is_a?(Integer) && value.positive?
          raise ArgumentError,
                "max_output_bytes must be a positive Integer"
        end

        value
      end

      def validate_clock!(value)
        raise ArgumentError, "clock must respond to call" unless value.respond_to?(:call)

        value
      end

      def validate_termination_grace!(value)
        validate_numeric!(value, name: "termination_grace_seconds", allow_zero: true)
      end

      def validate_numeric!(value, name:, allow_zero:)
        valid_type = value.is_a?(Integer) || value.is_a?(Float)
        unless valid_type
          raise ArgumentError,
                "#{name} must be a #{allow_zero ? "nonnegative" : "positive"} finite number"
        end

        finite = !value.is_a?(Float) || value.finite?
        positive_enough = allow_zero ? value >= 0 : value.positive?
        unless finite && positive_enough
          raise ArgumentError,
                "#{name} must be a #{allow_zero ? "nonnegative" : "positive"} finite number"
        end

        value
      end

      def process_group_options
        return { new_pgroup: true } if Gem.win_platform?

        { pgroup: true }
      end

      def prepare_streams!(stdin, stdout, stderr)
        stdin.binmode
        stdout.binmode
        stderr.binmode
      end

      def start_stdin_writer(stdin, stdin_data)
        error_box = { error: nil }
        writer_thread = Thread.new do
          write_stdin(stdin, stdin_data)
        rescue Errno::EPIPE
          nil
        rescue IOError => e
          error_box[:error] = e unless stdin.closed?
        rescue StandardError => e
          error_box[:error] = e
        ensure
          close_stream(stdin)
        end

        [writer_thread, error_box]
      end

      def write_stdin(stdin, stdin_data)
        return if stdin_data.nil?

        payload = stdin_data.dup.force_encoding(Encoding::BINARY)
        stdin.write(payload)
        stdin.flush
      end

      def monitor_process(deadline:, wait_thread:, stdout:, stderr:, stdout_buffer:, stderr_buffer:, stdin_thread:,
                          stdin_error:)
        streams = { stdout: stdout, stderr: stderr }
        status = nil

        loop do
          raise_writer_error!(stdin_thread, stdin_error)
          stdin_writer_finished = stdin_writer_finished?(stdin_thread)

          raise TimeoutError, @timeout_seconds if timed_out?(deadline)

          status = wait_thread.value if wait_thread.join(0)
          break if status && streams.empty? && stdin_writer_finished

          ready = wait_for_ready_streams(wait_thread, stdin_thread, streams.values, deadline)

          ready.each do |stream|
            name = streams.key(stream)
            next unless name

            drain_stream!(
              name:,
              stream:,
              buffer: name == :stdout ? stdout_buffer : stderr_buffer,
              streams:
            )
          end
        end

        status || wait_thread.value
      end

      def drain_stream!(name:, stream:, buffer:, streams:)
        chunk = stream.read_nonblock(4096, exception: false)

        case chunk
        when :wait_readable
          nil
        when nil
          close_stream(stream)
          streams.delete(name)
        else
          append_chunk!(buffer, chunk, name)
        end
      end

      def append_chunk!(buffer, chunk, stream_name)
        remaining = @max_output_bytes - buffer.bytesize
        if chunk.bytesize > remaining
          buffer << chunk.byteslice(0, remaining) if remaining.positive?
          raise OutputLimitError.new(stream: stream_name, max_output_bytes: @max_output_bytes)
        end

        buffer << chunk
      end

      def wait_for_ready_streams(wait_thread, stdin_thread, readable_streams, deadline)
        interval = poll_interval(deadline)
        return [] if interval <= 0

        if readable_streams.empty?
          wait_deadline = monotonic_now + interval
          wait_thread.join(remaining_poll_time(wait_deadline))
          stdin_thread&.join(remaining_poll_time(wait_deadline))
          return []
        end

        IO.select(readable_streams, nil, nil, interval)&.first || []
      end

      def raise_writer_error!(stdin_thread, error_box)
        return unless stdin_thread
        return unless stdin_thread.join(0)
        return unless error_box[:error]

        raise error_box[:error]
      end

      def stdin_writer_finished?(stdin_thread)
        return true unless stdin_thread

        !stdin_thread.join(0).nil?
      end

      def cleanup_call(wait_thread:, stdin:, stdout:, stderr:, stdin_thread:, stdin_error:, completed:, primary_error:)
        terminate_process(wait_thread) if wait_thread && !completed
      rescue StandardError
        nil
      ensure
        close_stream(stdin)
        close_stream(stdout)
        close_stream(stderr)
        begin
          join_stdin_thread!(stdin_thread, stdin_error, suppress_error: !primary_error.nil?) if stdin_thread
        rescue StandardError
          nil
        end
      end

      def terminate_process(wait_thread)
        pid = wait_thread.pid

        if Gem.win_platform?
          terminate_direct_child(wait_thread)
        else
          terminate_process_group(pid)
        end

        wait_thread.value
      rescue Errno::ECHILD
        nil
      end

      def terminate_direct_child(wait_thread)
        pid = wait_thread.pid

        begin
          Process.kill("TERM", pid)
        rescue Errno::EINVAL
          kill_direct_child(pid)
          return
        rescue Errno::ESRCH
          return
        end

        return unless wait_thread.join(@termination_grace_seconds).nil?

        kill_direct_child(pid)
      end

      def terminate_process_group(pid)
        Process.kill("TERM", -pid)
      rescue Errno::ESRCH
        nil
      else
        sleep_cleanup_grace(@termination_grace_seconds)

        begin
          Process.kill("KILL", -pid)
        rescue Errno::ESRCH
          nil
        end
      end

      def kill_direct_child(pid)
        Process.kill("KILL", pid)
      rescue Errno::ESRCH
        nil
      end

      def timed_out?(deadline)
        monotonic_now >= deadline
      end

      def remaining_seconds(deadline)
        [deadline - monotonic_now, 0].max
      end

      def poll_interval(deadline)
        [remaining_seconds(deadline), 0.05].min
      end

      def remaining_poll_time(wait_deadline)
        [wait_deadline - monotonic_now, 0].max
      end

      def monotonic_now
        @clock.call
      end

      def cleanup_monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def sleep_cleanup_grace(duration)
        return if duration.zero?

        deadline = cleanup_monotonic_now + duration

        sleep([deadline - cleanup_monotonic_now, 0.01].min) while cleanup_monotonic_now < deadline
      end

      def close_stream(stream)
        return unless stream
        return if stream.closed?

        stream.close
      rescue IOError, Errno::EBADF
        nil
      end

      def join_stdin_thread!(stdin_thread, error_box, suppress_error: false)
        return unless stdin_thread

        stdin_thread.join
        raise error_box[:error] if !suppress_error && error_box && error_box[:error]
      end
    end
  end
end
