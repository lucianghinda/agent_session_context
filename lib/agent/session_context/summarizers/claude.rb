# frozen_string_literal: true

require "json"

module Agent
  module SessionContext
    module Summarizers
      class Claude
        include CommandExecutionPolicy

        MAX_OUTPUT_BYTES = 1_048_576
        PROVIDER_ENV_KEYS = %w[ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR].freeze
        private_constant :PROVIDER_ENV_KEYS

        def initialize(runner: nil, timeout_seconds: Config::DEFAULT_TIMEOUT_SECONDS)
          initialize_command_execution_policy(
            runner:,
            timeout_seconds:,
            max_output_bytes: MAX_OUTPUT_BYTES,
            provider_env_keys: PROVIDER_ENV_KEYS
          )
        end

        def name
          :claude
        end

        def call(prompt:, schema:)
          stdout, stderr, status = run_command!(prompt:, argv: command_argv(schema))
          fail_command!(stdout:, stderr:, status:) unless status.success?
          if stdout.strip.empty?
            raise SummarizerFailed, failure_message(
              "#{name} summarizer produced empty stdout",
              stdout:,
              stderr:
            )
          end

          envelope = parse_envelope!(stdout, stderr:)
          field_name, value = extract_structured_value!(envelope)

          normalize_value!(value, field_name:, stdout:, stderr:)
        end

        private

        def command_argv(schema)
          [
            "claude",
            "--print",
            "--safe-mode",
            "--tools",
            "",
            "--no-session-persistence",
            "--output-format",
            "json",
            "--json-schema",
            JSON.generate(schema)
          ]
        end

        def parse_envelope!(stdout, stderr:)
          envelope = JSON.parse(stdout)
          unless envelope.is_a?(Hash)
            raise SummarizerFailed, failure_message(
              "#{name} summarizer produced a non-object JSON envelope",
              stdout:,
              stderr:
            )
          end

          envelope
        rescue JSON::ParserError, EncodingError, ArgumentError
          raise SummarizerFailed, failure_message(
            "#{name} summarizer produced invalid JSON envelope",
            stdout:,
            stderr:
          )
        end

        def extract_structured_value!(envelope)
          return ["structured_output", envelope["structured_output"]] if envelope.key?("structured_output")
          return ["result", envelope["result"]] if envelope.key?("result")

          raise SummarizerFailed, "#{name} summarizer JSON envelope did not include structured_output or result"
        end

        def normalize_value!(value, field_name:, stdout:, stderr:)
          case value
          when String
            normalize_json_string!(value, stdout:, stderr:, label: field_name)
          else
            JSON.generate(JSON.parse(JSON.generate(value)))
          end
        rescue JSON::GeneratorError, TypeError
          raise SummarizerFailed, failure_message(
            "#{name} summarizer produced a non-JSON #{field_name} value",
            stdout:,
            stderr:,
            output: value.inspect
          )
        end

        def normalize_json_string!(value, stdout:, stderr:, label:)
          JSON.generate(JSON.parse(value))
        rescue JSON::ParserError, EncodingError, ArgumentError
          raise SummarizerFailed, failure_message(
            "#{name} summarizer produced invalid JSON in #{label}",
            stdout:,
            stderr:,
            output: value
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
      end
    end
  end
end
