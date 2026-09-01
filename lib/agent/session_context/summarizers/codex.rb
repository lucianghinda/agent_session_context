# frozen_string_literal: true

require "json"
require "tempfile"

module Agent
  module SessionContext
    module Summarizers
      class Codex
        include CommandExecutionPolicy

        MAX_OUTPUT_BYTES = 1_048_576
        PROVIDER_ENV_KEYS = %w[CODEX_HOME OPENAI_API_KEY].freeze
        WHITESPACE_BYTES = [9, 10, 11, 12, 13, 32].freeze
        private_constant :PROVIDER_ENV_KEYS, :WHITESPACE_BYTES

        def initialize(runner: nil, timeout_seconds: Config::DEFAULT_TIMEOUT_SECONDS)
          initialize_command_execution_policy(
            runner:,
            timeout_seconds:,
            max_output_bytes: MAX_OUTPUT_BYTES,
            provider_env_keys: PROVIDER_ENV_KEYS
          )
        end

        def name
          :codex
        end

        def call(prompt:, schema:)
          Tempfile.create(["agent-context-codex-schema", ".json"]) do |schema_file|
            schema_file.write(JSON.generate(schema))
            schema_file.flush

            Tempfile.create(["agent-context-codex-output", ".json"]) do |output_file|
              stdout, stderr, status = run_command!(
                prompt:,
                argv: command_argv(schema_path: schema_file.path, output_path: output_file.path)
              )

              fail_command!(stdout:, stderr:, status:) unless status.success?

              payload = read_last_message!(output_file.path, stdout:, stderr:)
              normalize_json!(payload, source: "last message", stdout:, stderr:)
            end
          end
        end

        private

        def command_argv(schema_path:, output_path:)
          [
            "codex",
            "exec",
            "--ephemeral",
            "--sandbox",
            "read-only",
            "--ignore-user-config",
            "--ignore-rules",
            "--skip-git-repo-check",
            "--output-schema",
            schema_path,
            "--output-last-message",
            output_path,
            "-"
          ]
        end

        def read_last_message!(path, stdout:, stderr:)
          payload = bounded_file_read(path, "last message", stdout:, stderr:)
        rescue Errno::ENOENT
          raise SummarizerFailed, failure_message(
            "#{name} summarizer did not produce a last message file; output was missing",
            stdout:,
            stderr:
          )
        else
          if blank_bytes?(payload)
            raise SummarizerFailed, failure_message(
              "#{name} summarizer produced an empty last message file",
              stdout:,
              stderr:,
              output: payload
            )
          end

          payload
        end

        def normalize_json!(payload, source:, stdout:, stderr:)
          JSON.generate(JSON.parse(payload))
        rescue JSON::ParserError, EncodingError, ArgumentError
          raise SummarizerFailed, failure_message(
            "#{name} summarizer produced invalid JSON in #{source}",
            stdout:,
            stderr:,
            output: payload
          )
        end

        def fail_command!(stdout:, stderr:, status:)
          raise SummarizerFailed, failure_message(
            "#{name} summarizer command failed",
            stdout:,
            stderr:,
            status:
          )
        end

        def bounded_file_read(path, label, stdout:, stderr:)
          File.open(path, "rb") do |file|
            payload = file.read(MAX_OUTPUT_BYTES + 1) || "".b
            if payload.bytesize > MAX_OUTPUT_BYTES
              raise SummarizerFailed, failure_message(
                "#{name} summarizer #{label} exceeded #{MAX_OUTPUT_BYTES} bytes",
                stdout:,
                stderr:,
                output: payload
              )
            end

            payload
          end
        end

        def blank_bytes?(value)
          value.empty? || value.bytes.all? { |byte| WHITESPACE_BYTES.include?(byte) }
        end
      end
    end
  end
end
