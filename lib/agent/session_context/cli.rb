# frozen_string_literal: true

require "optparse"

module Agent
  module SessionContext
    class CLI
      FORMATS = %w[text markdown json jsonl].freeze

      def initialize(
        argv,
        env: ENV,
        stdout: $stdout,
        stderr: $stderr,
        now: Time.now,
        resolver: SessionResolver.new(env: env),
        builder: Builder.new(now: now),
        backend_factory: Summarizers,
        config_loader: Config
      )
        @argv = argv.dup
        @env = env
        @stdout = stdout
        @stderr = stderr
        @resolver = resolver
        @builder = builder
        @backend_factory = backend_factory
        @config_loader = config_loader
        @current_format = :text
      end

      def run
        case (command = @argv.shift)
        when "show" then show
        when "prompts" then prompts
        # Named loop_command, not loop: Kernel#loop is an instance method
        # available everywhere, and a method named `loop` on this CLI object
        # would shadow it for the rest of this instance.
        when "loop" then loop_command
        when "summarize" then summarize
        when "version", "--version", "-v" then version(@argv)
        when nil then help([], @stdout, 0)
        when "help", "--help", "-h" then help(@argv, @stdout, 0)
        else
          @stderr.puts "unknown command: #{safe_text(command)}"
          1
        end
      rescue Agent::SessionContext::Error, OptionParser::ParseError => e
        emit_error(e)
        1
      end

      private

      def show
        @current_format = Options.hinted_format(@argv)
        selection = Options.parse(@argv, command: :show)
        session = resolve_session(selection)
        include_injected = selection.fetch(:include_injected)
        snapshot = @builder.show(session, include_injected:)
        if include_injected
          @stderr.puts "warning: exact prompts and full injected context may contain secrets; review before sharing"
        else
          @stderr.puts "warning: exact prompts may contain secrets; review before sharing"
        end
        emit_warnings(session.uid, snapshot.warnings)
        write_output(snapshot, format: selection.fetch(:format))
        partial_capture_status(snapshot)
      end

      def prompts
        @current_format = Options.hinted_format(@argv)
        selection = Options.parse(@argv, command: :prompts)
        session = resolve_session(selection)
        prompts_result = @builder.prompts_result(session)
        @stderr.puts "warning: exact prompts may contain secrets; review before sharing"
        emit_warnings(session.uid, prompts_result.reader_warnings)
        write_output(prompts_result.prompts, format: selection.fetch(:format))
        prompts_result.partial_capture? ? 1 : 0
      end

      # No "may contain secrets" stderr warning here, unlike show and
      # prompts: this view prints byte sizes and tool names, never prompt or
      # tool-result bodies (LoopView's own privacy rule), so its output is
      # always safe to paste anywhere.
      def loop_command
        @current_format = Options.hinted_format(@argv)
        selection = Options.parse(@argv, command: :loop)
        session = resolve_session(selection)
        loop = @builder.loop(session)
        emit_warnings(session.uid, loop.warnings)
        format = selection.fetch(:format)
        # Human CLI diagnostics are already on stderr. Standalone views and
        # structured output retain the original warnings.
        output = human_format?(format) ? loop.with(warnings: []) : loop
        write_output(output, format:)
        loop.warnings.empty? ? 0 : 1
      end

      def summarize
        @current_format = Options.hinted_format(@argv)
        selection = Options.parse(@argv, command: :summarize)
        session = resolve_session(selection)
        config = @config_loader.load(session:, env: @env, timeout: selection.fetch(:timeout))
        backend_name = selection.fetch(:using) == :auto ? session.agent : selection.fetch(:using)
        timeout_seconds = configured_timeout_seconds(config)
        @stderr.puts "summarizing with #{safe_text(backend_name)} (timeout: #{format_timeout(timeout_seconds)}s)"
        summarizer = @backend_factory.for(backend_name, timeout_seconds:)
        snapshot = @builder.summarize(session, summarizer:)
        emit_warnings(session.uid, snapshot.warnings)
        write_output(snapshot, format: selection.fetch(:format))
        partial_capture_status(snapshot)
      end

      def version(arguments)
        Options.parse_no_args(arguments, command: :version)
        @stdout.puts Agent::SessionContext::VERSION
        0
      end

      def help(arguments, io, status)
        Options.parse_no_args(arguments, command: :help)
        io.puts <<~HELP
          Usage: agent-session-context COMMAND [options] [SESSION]

          Commands:
            show
            prompts
            loop
            summarize
            version
            help

          Common options:
            --current             Use environment identity, else latest on disk
            --agent claude|codex  Narrow explicit lookup or --current disk fallback
            --format text|markdown|json|jsonl

          Show behavior:
            Includes exact user prompts and an injected-context inventory.
            --include-injected  Include deduplicated full injected text
            Excludes assistant messages, thinking, tool-result bodies,
            and raw provider envelopes.

          Loop behavior:
            Shows prompts, model entries, tool calls paired with their results,
            and the last recorded state. Entries are not a count of API requests.
            Prints byte sizes and tool names, never bodies. Deterministic;
            the ending is always labelled inferred.

          Summarize options:
            --using auto|claude|codex
            --timeout SECONDS    Set a 1-3600s timeout for each provider call
        HELP
        status
      end

      def resolve_session(selection)
        if selection.fetch(:current)
          @resolver.current(agent: selection.fetch(:agent)) do |session|
            @stderr.puts(
              "warning: --current found no session environment identifier; " \
              "using latest session on disk: #{safe_text(session.uid)}"
            )
          end
        else
          @resolver.resolve(selection.fetch(:identifier), agent: selection.fetch(:agent))
        end
      end

      def emit_warnings(session_uid, warnings)
        Array(warnings).each do |warning|
          @stderr.puts "warning: #{safe_text(session_uid)}: #{safe_text(warning)}"
        end
      end

      def write_output(value, format:)
        rendered = renderer_for(format).call(value)
        if human_format?(format)
          @stdout.write(rendered)
          @stdout.write("\n")
        else
          @stdout.write(rendered)
        end
      end

      def renderer_for(format)
        case format
        when :text then Renderers::Text.new
        when :markdown then Renderers::Markdown.new
        when :json then Renderers::JSON.new
        when :jsonl then Renderers::JSONLines.new
        else
          raise OptionParser::ParseError, "unsupported format #{format.inspect}"
        end
      end

      def human_format?(format)
        %i[text markdown].include?(format)
      end

      def emit_error(error)
        if @current_format == :json
          error_json = JSON.generate(
            {
              error: {
                type: scrubbed_error_type(error),
                message: Renderers::Serializer.scrub_string(normalized_error_message(error))
              }
            }
          )
          @stdout.write(error_json)
        else
          @stderr.puts safe_text(normalized_error_message(error))
        end
      end

      def safe_text(value)
        Renderers::HumanDisplay.text_inline(value)
      end

      def partial_capture_status(snapshot)
        snapshot.summary_metadata.fetch(:reader_warning_count, 0).positive? ? 1 : 0
      end

      def configured_timeout_seconds(config)
        value = config.timeout_seconds
        if value.is_a?(Integer) && value >= Config::MIN_TIMEOUT_SECONDS && value <= Config::MAX_TIMEOUT_SECONDS
          return value
        end
        if value.is_a?(Float) &&
           value.finite? &&
           value >= Config::MIN_TIMEOUT_SECONDS &&
           value <= Config::MAX_TIMEOUT_SECONDS
          return value
        end

        raise ConfigurationError, "Invalid configured timeout_seconds."
      end

      def format_timeout(value)
        return value.to_i.to_s if value.is_a?(Float) && value.finite? && value == value.to_i

        value.to_s
      end

      def normalized_error_message(error)
        return error.args.first.to_s if error.instance_of?(OptionParser::ParseError)

        error.message.to_s
      end

      def scrubbed_error_type(error)
        Renderers::Serializer.scrub_string(error.class.name.to_s)
      end
    end
  end
end
