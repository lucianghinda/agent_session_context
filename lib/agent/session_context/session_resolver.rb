# frozen_string_literal: true

module Agent
  module SessionContext
    class SessionResolver
      SUPPORTED = %i[claude codex].freeze

      def initialize(catalog: Agent::Sessions, env: ENV)
        @catalog = catalog
        @env = env
      end

      def resolve(identifier, agent: nil)
        parsed_agent, session_id = parse_identifier(identifier)
        requested_agent = (agent && normalize_agent(agent, source: "agent")) || parsed_agent

        return resolve_for_agent(requested_agent, session_id) if requested_agent

        matches = SUPPORTED.flat_map do |candidate|
          matching_sessions(candidate, session_id)
        end

        resolve_cardinality(
          matches,
          not_found_message: "Session #{session_id.inspect} was not found for claude or codex.",
          ambiguous_message: "Session #{session_id.inspect} matches multiple sessions: " \
                             "#{matches.map(&:uid).join(", ")}. Use an exact agent-prefixed identifier."
        )
      end

      def current(agent: nil, &)
        generic_identifier = fetch_env("AGENT_SESSION_ID")
        if present?(generic_identifier)
          agent_name = fetch_env("AGENT_NAME")
          unless present?(agent_name)
            raise CurrentSessionUnavailable,
                  "AGENT_SESSION_ID is set but AGENT_NAME is missing."
          end

          return resolve(generic_identifier, agent: normalize_agent(agent_name, source: "AGENT_NAME"))
        end

        claude_identifier = fetch_env("CLAUDE_CODE_SESSION_ID")
        codex_identifier = current_codex_identifier

        if present?(claude_identifier) && present?(codex_identifier)
          codex_source = present?(fetch_env("CODEX_SESSION_ID")) ? "CODEX_SESSION_ID" : "CODEX_THREAD_ID"
          raise CurrentSessionUnavailable,
                "Conflicting current session variables: CLAUDE_CODE_SESSION_ID and " \
                "#{codex_source}. Clear one and retry."
        end

        return resolve(claude_identifier, agent: :claude) if present?(claude_identifier)
        return resolve(codex_identifier, agent: :codex) if present?(codex_identifier)

        current_from_disk(agent:, &)
      end

      private

      def parse_identifier(identifier)
        identifier = identifier.to_s
        prefix, remainder = identifier.split(":", 2)

        return [normalize_agent(prefix, source: "identifier prefix"), remainder] if remainder

        [nil, identifier]
      end

      def resolve_for_agent(agent, session_id)
        matches = matching_sessions(agent, session_id)
        resolve_cardinality(
          matches,
          not_found_message: "Session #{session_id.inspect} was not found for #{agent}.",
          ambiguous_message: "Session #{session_id.inspect} matches multiple sessions for #{agent}: " \
                             "#{matches.map(&:uid).join(", ")}."
        )
      end

      def matching_sessions(agent, session_id)
        @catalog.sessions(agent, env: @env)
                .select { |session| session.id == session_id }
                .force
      end

      def resolve_cardinality(matches, not_found_message:, ambiguous_message:)
        return matches.first if matches.one?
        raise SessionNotFound, not_found_message if matches.empty?

        raise AmbiguousSession, ambiguous_message
      end

      def current_codex_identifier
        session_identifier = fetch_env("CODEX_SESSION_ID")
        return session_identifier if present?(session_identifier)

        fetch_env("CODEX_THREAD_ID")
      end

      def current_from_disk(agent:, &block)
        agents = agent ? [normalize_agent(agent, source: "agent")] : SUPPORTED
        sessions = agents.flat_map { |candidate| @catalog.sessions(candidate, env: @env).force }

        if sessions.empty?
          raise CurrentSessionUnavailable,
                "Current session is unavailable: no sessions found for #{agent_scope(agents)}. " \
                "Set AGENT_SESSION_ID with AGENT_NAME, CLAUDE_CODE_SESSION_ID, CODEX_SESSION_ID, or CODEX_THREAD_ID."
        end

        latest_updated_at = sessions.map(&:updated_at).max
        latest_sessions = sessions.select { |session| session.updated_at == latest_updated_at }

        if latest_sessions.size > 1
          raise AmbiguousSession,
                "Multiple sessions share the latest update at #{latest_updated_at.iso8601(9)}: " \
                "#{latest_sessions.map(&:uid).sort.join(", ")}. Pass an explicit SESSION."
        end

        session = latest_sessions.first
        block&.call(session)
        session
      end

      def agent_scope(agents)
        return agents.first.to_s if agents.size == 1

        agents.join(" or ")
      end

      def normalize_agent(agent, source:)
        normalized = agent.to_s.downcase.to_sym
        return normalized if SUPPORTED.include?(normalized)

        raise UnsupportedAgent,
              "Unsupported agent #{agent.inspect} from #{source}. Supported agents: #{SUPPORTED.join(", ")}."
      end

      def fetch_env(key)
        @env[key]
      end

      def present?(value)
        !value.nil? && !value.empty?
      end
    end
  end
end
