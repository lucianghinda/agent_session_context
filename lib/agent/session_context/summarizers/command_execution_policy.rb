# frozen_string_literal: true

module Agent
  module SessionContext
    module Summarizers
      module CommandExecutionPolicy
        COMMON_ENV_KEYS = %w[
          ALL_PROXY
          HOME
          HTTP_PROXY
          HTTPS_PROXY
          LANG
          NO_PROXY
          PATH
          SSL_CERT_DIR
          SSL_CERT_FILE
          all_proxy
          http_proxy
          https_proxy
          no_proxy
        ].freeze
        private_constant :COMMON_ENV_KEYS

        private

        def initialize_command_execution_policy(runner:, timeout_seconds:, max_output_bytes:, provider_env_keys:)
          @timeout_seconds = timeout_seconds
          @max_output_bytes = max_output_bytes
          @provider_env_keys = provider_env_keys.dup.freeze
          @runner = runner || SubprocessRunner.new(timeout_seconds:, max_output_bytes:)
        end

        def run_command!(prompt:, argv:)
          response = @runner.call(env: child_env, argv:, stdin_data: prompt)
          validate_runner_response!(response)
        rescue Errno::ENOENT => e
          raise SummarizerUnavailable, "#{name} summarizer is unavailable: #{e.message}"
        rescue SubprocessRunner::TimeoutError
          raise SummarizerFailed, "#{name} summarizer exceeded its #{@timeout_seconds}-second timeout"
        rescue SubprocessRunner::OutputLimitError => e
          raise SummarizerFailed,
                "#{name} summarizer #{translated_stream_label(e.stream)} exceeded #{@max_output_bytes} bytes"
        end

        def validate_runner_response!(response)
          unless response.is_a?(Array) && response.length == 3
            raise SummarizerFailed, "#{name} summarizer runner must return [stdout, stderr, status]"
          end

          stdout, stderr, status = response

          unless status.respond_to?(:success?)
            raise SummarizerFailed, "#{name} summarizer runner must return a status with #success?"
          end

          unless stdout.nil? || stdout.is_a?(String)
            raise SummarizerFailed, "#{name} summarizer runner must return stdout as a String"
          end

          unless stderr.nil? || stderr.is_a?(String)
            raise SummarizerFailed, "#{name} summarizer runner must return stderr as a String"
          end

          stdout = stdout.to_s
          stderr = stderr.to_s
          enforce_output_bounds!("stdout", stdout, status:)
          enforce_output_bounds!("stderr", stderr, status:)

          [stdout, stderr, status]
        end

        def failure_message(summary, stdout: nil, stderr: nil, output: nil, status: nil)
          fragments = [summary]
          append_stream_metadata(fragments, "stdout", stdout)
          append_stream_metadata(fragments, "stderr", stderr)
          append_stream_metadata(fragments, "output", output)
          append_status_metadata(fragments, status)
          fragments.join(". ")
        end

        def child_env
          ENV.each_with_object({}) do |(key, value), filtered|
            filtered[key] = value if allowed_env_key?(key)
          end
        end

        def allowed_env_key?(key)
          COMMON_ENV_KEYS.include?(key) || @provider_env_keys.include?(key) || key.start_with?("LC_")
        end

        def enforce_output_bounds!(label, value, status:)
          return if value.bytesize <= @max_output_bytes

          raise SummarizerFailed, failure_message(
            "#{name} summarizer #{label} exceeded #{@max_output_bytes} bytes",
            status:,
            stdout: label == "stdout" ? value : nil,
            stderr: label == "stderr" ? value : nil
          )
        end

        def append_stream_metadata(fragments, label, value)
          state =
            if value.nil?
              "absent"
            elsif value.empty?
              "empty"
            else
              "present"
            end

          bytesize = value.nil? ? 0 : value.bytesize
          fragments << "#{label}=#{state}(#{bytesize} bytes)"
        end

        def append_status_metadata(fragments, status)
          return unless status.respond_to?(:exitstatus)

          exitstatus = status.exitstatus
          return if exitstatus.nil?

          fragments << "exit_status=#{exitstatus}"
        end

        def translated_stream_label(stream)
          return "stdout" if stream.equal?(:stdout)
          return "stderr" if stream.equal?(:stderr)

          "output"
        end
      end
    end
  end
end
