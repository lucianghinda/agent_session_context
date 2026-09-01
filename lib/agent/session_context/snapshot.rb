# frozen_string_literal: true

module Agent
  module SessionContext
    Snapshot = Data.define(
      :session_uid,
      :agent,
      :project_path,
      :captured_at,
      :message_count,
      :prompts,
      :injected_context,
      :files,
      :documents,
      :tool_activity,
      :goals,
      :decisions,
      :terms,
      :constraints,
      :open_questions,
      :next_actions,
      :warnings,
      :summary_metadata
    ) do
      def initialize(
        session_uid:,
        agent:,
        project_path:,
        captured_at:,
        message_count:,
        prompts: [],
        injected_context: [],
        files: [],
        documents: [],
        tool_activity: [],
        goals: [],
        decisions: [],
        terms: [],
        constraints: [],
        open_questions: [],
        next_actions: [],
        warnings: [],
        summary_metadata: {}
      )
        super(
          session_uid: normalize_string(session_uid, :session_uid),
          agent: normalize_agent(agent),
          project_path: normalize_optional_string(project_path, :project_path),
          captured_at: captured_at,
          message_count: normalize_message_count(message_count),
          prompts: duplicate_collection(prompts),
          injected_context: duplicate_collection(injected_context),
          files: duplicate_collection(files),
          documents: duplicate_collection(documents),
          tool_activity: duplicate_collection(tool_activity),
          goals: duplicate_collection(goals),
          decisions: duplicate_collection(decisions),
          terms: duplicate_collection(terms),
          constraints: duplicate_collection(constraints),
          open_questions: duplicate_collection(open_questions),
          next_actions: duplicate_collection(next_actions),
          warnings: normalize_warnings(warnings),
          summary_metadata: normalize_summary_metadata(summary_metadata)
        )
      end

      private

      def duplicate_collection(value)
        ImmutableValue.copy(Array(value))
      end

      def normalize_agent(value)
        return value if value.is_a?(Symbol)
        return value.to_sym if value.respond_to?(:to_sym)

        raise TypeError, "agent must be symbolizable"
      end

      def normalize_message_count(value)
        count =
          if value.is_a?(Integer)
            value
          elsif value.respond_to?(:to_int)
            value.to_int
          elsif value.is_a?(String)
            Integer(value, exception: false)
          end

        raise TypeError, "message_count must be an Integer or integer-like value" if count.nil?
        raise ArgumentError, "message_count must be greater than or equal to 0" if count.negative?

        count
      end

      def normalize_string(value, name)
        raise TypeError, "#{name} must be a String" unless value.respond_to?(:to_str)

        String.new(value.to_str).freeze
      end

      def normalize_optional_string(value, name)
        return if value.nil?

        normalize_string(value, name)
      end

      def normalize_summary_metadata(value)
        raise TypeError, "summary_metadata must be a Hash" unless value.is_a?(Hash)

        value.each_with_object({}) do |(key, metadata_value), normalized|
          normalized[normalize_summary_metadata_key(key)] = ImmutableValue.copy(metadata_value)
        end.freeze
      end

      def normalize_summary_metadata_key(key)
        return key if key.is_a?(Symbol)
        return key.to_sym if key.respond_to?(:to_sym)

        raise TypeError, "summary_metadata keys must be symbolizable"
      end

      def normalize_warnings(value)
        Array(value).map { |warning| normalize_string(warning, :warning) }.freeze
      end
    end
  end
end
