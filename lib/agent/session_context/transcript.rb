# frozen_string_literal: true

module Agent
  module SessionContext
    TranscriptPart = Data.define(:index, :type, :text, :name, :call_id, :injected, :source_ref) do
      def initialize(index:, type:, injected:, source_ref:, text: nil, name: nil, call_id: nil)
        super(
          index: normalize_positive_index(index, :index),
          type: normalize_symbol(type, :type),
          text: normalize_optional_string(text, :text),
          name: normalize_optional_string(name, :name),
          call_id: normalize_optional_string(call_id, :call_id),
          injected: normalize_boolean(injected),
          source_ref: normalize_source_ref(source_ref)
        )
      end

      private

      def normalize_positive_index(value, name)
        index =
          if value.is_a?(Integer)
            value
          elsif value.respond_to?(:to_int)
            value.to_int
          elsif value.is_a?(String)
            Integer(value, exception: false)
          end

        raise TypeError, "#{name} must be an Integer or integer-like value" if index.nil?
        raise ArgumentError, "#{name} must be greater than or equal to 1" if index < 1

        index
      end

      def normalize_symbol(value, name)
        return value if value.is_a?(Symbol)
        return value.to_sym if value.respond_to?(:to_sym)

        raise TypeError, "#{name} must be symbolizable"
      end

      def normalize_optional_string(value, name)
        return if value.nil?

        raise TypeError, "#{name} must be a String" unless value.respond_to?(:to_str)

        String.new(value.to_str).freeze
      end

      def normalize_boolean(value)
        return value if [true, false].include?(value)

        raise TypeError, "injected must be true or false"
      end

      def normalize_source_ref(value)
        raise TypeError, "source_ref must be an Agent::SessionContext::SourceRef" unless value.is_a?(SourceRef)

        value
      end
    end

    TranscriptEntry = Data.define(:index, :role, :at, :parts) do
      def initialize(index:, role:, at:, parts:)
        super(
          index: normalize_positive_index(index, :index),
          role: normalize_symbol(role, :role),
          at: at,
          parts: normalize_parts(parts)
        )
      end

      private

      def normalize_positive_index(value, name)
        index =
          if value.is_a?(Integer)
            value
          elsif value.respond_to?(:to_int)
            value.to_int
          elsif value.is_a?(String)
            Integer(value, exception: false)
          end

        raise TypeError, "#{name} must be an Integer or integer-like value" if index.nil?
        raise ArgumentError, "#{name} must be greater than or equal to 1" if index < 1

        index
      end

      def normalize_symbol(value, name)
        return value if value.is_a?(Symbol)
        return value.to_sym if value.respond_to?(:to_sym)

        raise TypeError, "#{name} must be symbolizable"
      end

      def normalize_parts(value)
        Array(value).map do |part|
          unless part.is_a?(TranscriptPart)
            raise TypeError,
                  "parts must contain only Agent::SessionContext::TranscriptPart values"
          end

          part
        end.freeze
      end
    end

    Transcript = Data.define(:session, :captured_at, :entries, :warnings) do
      class << self
        def capture(session, reader: Agent::Sessions.read(session), now: Time.now)
          entries = []

          reader.each_message.with_index(1) do |message, message_index|
            entries << TranscriptEntry.new(
              index: message_index,
              role: message.role,
              at: message.at,
              parts: capture_parts(session, message, message_index)
            )
          end

          new(
            session: session,
            captured_at: now,
            entries: entries.freeze,
            warnings: capture_warnings(reader)
          )
        end

        def injection_kind(agent, text)
          return unless text.is_a?(String)

          stripped_text = text.b.lstrip
          marker_kinds = Transcript::INJECTION_MARKERS.fetch(agent&.to_sym, {})
          match = marker_kinds.find { |marker, _kind| stripped_text.start_with?(marker.b) }
          match&.last
        end

        private

        def capture_parts(session, message, message_index)
          message.parts.each_with_index.map do |part, part_index|
            TranscriptPart.new(
              index: part_index + 1,
              type: part.type,
              text: part.text,
              name: part.name,
              call_id: part.call_id,
              injected: injected_part?(session.agent, message, part),
              source_ref: SourceRef.new(
                session_uid: session.uid,
                message_index: message_index,
                part_index: part_index + 1
              )
            )
          end.freeze
        end

        def capture_warnings(reader)
          Array(reader.warnings).map do |warning|
            raise TypeError, "warning must be a String" unless warning.respond_to?(:to_str)

            String.new(warning.to_str).freeze
          end.freeze
        end

        def injected_part?(agent, message, part)
          return false unless message.role == :user
          return false unless part.type == :text

          raw_meta_message?(message.raw) || marker_injected?(agent, part.text)
        end

        def raw_meta_message?(raw)
          raw.is_a?(Hash) && raw["isMeta"] == true
        end

        def marker_injected?(agent, text)
          !injection_kind(agent, text).nil?
        end
      end

      def initialize(session:, captured_at:, entries:, warnings:)
        super(
          session: session,
          captured_at: captured_at,
          entries: normalize_entries(entries),
          warnings: normalize_warnings(warnings)
        )
      end

      private

      def normalize_entries(value)
        Array(value).map do |entry|
          unless entry.is_a?(TranscriptEntry)
            raise TypeError,
                  "entries must contain only Agent::SessionContext::TranscriptEntry values"
          end

          entry
        end.freeze
      end

      def normalize_warnings(value)
        Array(value).map do |warning|
          raise TypeError, "warning must be a String" unless warning.respond_to?(:to_str)

          String.new(warning.to_str).freeze
        end.freeze
      end
    end

    Transcript.const_set(
      :INJECTION_MARKERS,
      {
        claude: {
          "<command-name>" => :command_name,
          "<command-message>" => :command_message,
          "<command-args>" => :command_args,
          "<local-command-stdout>" => :local_command_stdout,
          "<local-command-stderr>" => :local_command_stderr,
          "<system-reminder>" => :system_reminder
        }.freeze,
        codex: {
          "<environment_context>" => :environment_context,
          "<user_instructions>" => :user_instructions,
          "# AGENTS.md instructions" => :agents_instructions
        }.freeze
      }.freeze
    )
  end
end
