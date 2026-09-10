# frozen_string_literal: true

require "optparse"

module Agent
  module SessionContext
    class CLI
      class Options
        AGENTS = %w[claude codex].freeze
        BACKENDS = %w[auto claude codex].freeze
        OPTION_DEFINITIONS = {
          current: {
            long: "--current",
            value: false,
            register: lambda do |parser, options|
              parser.on("--current") { options[:current] = true }
            end
          }.freeze,
          agent: {
            long: "--agent",
            value: true,
            register: lambda do |parser, options|
              parser.on("--agent AGENT", AGENTS) { |value| options[:agent] = value.to_sym }
            end
          }.freeze,
          format: {
            long: "--format",
            value: true,
            register: lambda do |parser, options|
              parser.on("--format FORMAT", CLI::FORMATS) { |value| options[:format] = value.to_sym }
            end
          }.freeze,
          using: {
            long: "--using",
            value: true,
            register: lambda do |parser, options|
              parser.on("--using BACKEND", BACKENDS) { |value| options[:using] = value.to_sym }
            end
          }.freeze,
          timeout: {
            long: "--timeout",
            value: true,
            register: lambda do |parser, options|
              parser.on("--timeout SECONDS") { |value| options[:timeout] = parse_timeout_argument(value) }
            end
          }.freeze,
          include_injected: {
            long: "--include-injected",
            value: false,
            register: lambda do |parser, options|
              parser.on("--include-injected") { options[:include_injected] = true }
            end
          }.freeze
        }.freeze
        COMMANDS = {
          show: { formats: %i[text markdown json], options: %i[current agent format include_injected] }.freeze,
          prompts: { formats: %i[text markdown json jsonl], options: %i[current agent format] }.freeze,
          loop: { formats: %i[text markdown json jsonl], options: %i[current agent format] }.freeze,
          summarize: { formats: %i[text markdown json], options: %i[current agent format using timeout] }.freeze,
          help: { formats: nil, options: [].freeze }.freeze,
          version: { formats: nil, options: [].freeze }.freeze
        }.transform_values do |descriptor|
          option_names = descriptor.fetch(:options)
          long_options = option_names.each_with_object({}) do |name, rules|
            definition = OPTION_DEFINITIONS.fetch(name)
            rules[definition.fetch(:long)] = definition.fetch(:value) ? :value : :flag
          end.freeze

          descriptor.merge(
            formats: descriptor[:formats]&.freeze,
            options: option_names.freeze,
            long_options:
          ).freeze
        end.freeze
        private_constant :AGENTS, :BACKENDS, :OPTION_DEFINITIONS, :COMMANDS

        class << self
          def parse(arguments, command:)
            descriptor = command_descriptor(command)
            options = default_options
            validate_argument_encoding!(arguments)
            validate_exact_long_options!(arguments, descriptor:)
            remaining = parser(options, descriptor:).permute(arguments.dup)

            validate_selection!(options, remaining, command:, descriptor:)
            options.merge(identifier: remaining.first).freeze
          end

          def hinted_format(arguments)
            limit = arguments.index("--") || arguments.length
            effective = :text
            index = 0

            while index < limit
              token = arguments[index]

              if token == "--format"
                candidate = arguments[index + 1]
                effective = candidate.to_sym if CLI::FORMATS.include?(candidate)
                index += 2
                next
              end

              if token.start_with?("--format=")
                candidate = token.split("=", 2).last
                effective = candidate.to_sym if CLI::FORMATS.include?(candidate)
              end

              index += 1
            end

            effective
          end

          def parse_no_args(arguments, command:)
            descriptor = command_descriptor(command)
            validate_argument_encoding!(arguments)
            validate_exact_long_options!(arguments, descriptor:)
            remaining = OptionParser.new.permute(arguments.dup)
            raise OptionParser::ParseError, "unexpected arguments: #{remaining.join(" ")}" unless remaining.empty?
          end

          private

          def default_options
            {
              current: false,
              agent: nil,
              format: :text,
              using: :auto,
              timeout: nil,
              include_injected: false
            }
          end

          def parser(options, descriptor:)
            OptionParser.new do |parser|
              descriptor.fetch(:options).each do |name|
                OPTION_DEFINITIONS.fetch(name).fetch(:register).call(parser, options)
              end
            end
          end

          def validate_selection!(options, remaining, command:, descriptor:)
            allowed_formats = descriptor.fetch(:formats)
            unless allowed_formats.include?(options[:format])
              raise OptionParser::ParseError, "--format #{options[:format]} is not supported for #{command}"
            end

            if options[:current] && !remaining.empty?
              raise OptionParser::ParseError, "SESSION and --current are mutually exclusive"
            end

            if remaining.length > 1
              raise OptionParser::ParseError, "unexpected arguments: #{remaining.drop(1).join(" ")}"
            end

            raise OptionParser::ParseError, "pass SESSION or --current" if !options[:current] && remaining.empty?
          end

          def validate_argument_encoding!(arguments)
            arguments.each do |argument|
              next unless argument.is_a?(String)

              candidate = argument.dup
              candidate.force_encoding(Encoding::UTF_8)
              raise OptionParser::InvalidArgument, "arguments must be valid UTF-8" unless candidate.valid_encoding?
            end
          end

          def validate_exact_long_options!(arguments, descriptor:)
            allowed = descriptor.fetch(:long_options)
            limit = arguments.index("--") || arguments.length
            index = 0

            while index < limit
              token = arguments[index]
              if token.start_with?("--")
                name, value = token.split("=", 2)
                rule = allowed[name]
                raise OptionParser::InvalidOption, token unless rule
                raise OptionParser::InvalidOption, token if rule == :flag && !value.nil?

                if rule == :value && value.nil?
                  index += 2
                  next
                end
              end

              index += 1
            end
          end

          def command_descriptor(command)
            COMMANDS.fetch(command.to_sym)
          end

          def parse_timeout_argument(value)
            Integer(value, 10)
          rescue ArgumentError, TypeError
            return Float::NAN if value.casecmp("nan").zero?
            return Float::INFINITY if value.casecmp("infinity").zero? || value.casecmp("inf").zero?
            return -Float::INFINITY if value.casecmp("-infinity").zero? || value.casecmp("-inf").zero?

            parsed = Float(value, exception: false)
            return parsed unless parsed.nil?

            raise OptionParser::InvalidArgument, value
          end
        end
      end
    end
  end
end
