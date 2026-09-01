# frozen_string_literal: true

module Agent
  module SessionContext
    class InjectedContextCollector
      def call(transcript, include_text: false)
        validate_include_text!(include_text)
        groups = {}

        transcript.entries.each do |entry|
          entry.parts.each do |part|
            next unless part.injected

            text = injected_text(part)
            group = groups[text] ||= {
              kind: Transcript.injection_kind(transcript.session.agent, text) || :provider_meta,
              text:,
              source_refs: []
            }
            group.fetch(:source_refs) << part.source_ref
          end
        end

        groups.values.map do |group|
          source_refs = group.fetch(:source_refs)
          text = group.fetch(:text)
          InjectedContext.new(
            kind: group.fetch(:kind),
            bytes: text.bytesize,
            occurrences: source_refs.length,
            source_refs:,
            text: include_text ? text : nil
          )
        end.freeze
      end

      private

      def validate_include_text!(value)
        return if [true, false].include?(value)

        raise ArgumentError, "include_text must be true or false"
      end

      def injected_text(part)
        text = part.text
        raise TypeError, "injected parts must contain text" unless text.respond_to?(:to_str)

        text.to_str
      end
    end
  end
end
