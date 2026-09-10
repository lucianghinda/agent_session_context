# frozen_string_literal: true

require "json"
require "time"
require "agent_sessions"
require "zeitwerk"
require_relative "session_context/errors"

module Agent
  module SessionContext
    LOADER = Zeitwerk::Loader.for_gem_extension(Agent)
    LOADER.ignore(File.expand_path("session_context/errors.rb", __dir__))
    LOADER.inflector.inflect("cli" => "CLI", "json" => "JSON", "json_lines" => "JSONLines")
    LOADER.setup
    private_constant :LOADER

    class << self
      def resolve(identifier, agent: nil, env: ENV, catalog: Agent::Sessions)
        SessionResolver.new(catalog:, env: env).resolve(identifier, agent: agent)
      end

      def current(agent: nil, env: ENV, catalog: Agent::Sessions)
        SessionResolver.new(catalog:, env: env).current(agent:)
      end

      def show(session, include_injected: false, **)
        Builder.new(**).show(session, include_injected:)
      end

      def prompts(session, **)
        Builder.new(**).prompts(session)
      end

      def loop(session, **)
        Builder.new(**).loop(session)
      end

      def summarize(
        session,
        using: nil,
        summarizer: nil,
        timeout: nil,
        env: ENV,
        config_loader: Config,
        backend_factory: Summarizers,
        **
      )
        if summarizer
          raise ArgumentError, "timeout applies only to built-in summarizers" unless timeout.nil?

          return Builder.new(**).summarize(session, summarizer:)
        end

        config = config_loader.load(session:, env:, timeout:)
        backend = backend_factory.for(using || session.agent, timeout_seconds: config.timeout_seconds)
        Builder.new(**).summarize(session, summarizer: backend)
      end
    end
  end
end
