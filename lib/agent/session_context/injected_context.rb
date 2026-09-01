# frozen_string_literal: true

module Agent
  module SessionContext
    InjectedContext = Data.define(:kind, :bytes, :occurrences, :source_refs, :text) do
      def initialize(kind:, bytes:, occurrences:, source_refs:, text: nil)
        normalized_kind = normalize_symbol(kind, :kind)
        normalized_bytes = normalize_nonnegative_integer(bytes, :bytes)
        normalized_occurrences = normalize_positive_integer(occurrences, :occurrences)
        normalized_source_refs = normalize_source_refs(source_refs)
        normalized_text = normalize_optional_string(text, :text)
        validate_consistency!(
          bytes: normalized_bytes,
          occurrences: normalized_occurrences,
          source_refs: normalized_source_refs,
          text: normalized_text
        )

        super(
          kind: normalized_kind,
          bytes: normalized_bytes,
          occurrences: normalized_occurrences,
          source_refs: normalized_source_refs,
          text: normalized_text
        )
      end

      private

      def normalize_symbol(value, name)
        return value if value.is_a?(Symbol)
        return value.to_sym if value.respond_to?(:to_sym)

        raise TypeError, "#{name} must be symbolizable"
      end

      def normalize_nonnegative_integer(value, name)
        integer = normalize_integer(value, name)
        raise ArgumentError, "#{name} must be greater than or equal to 0" if integer.negative?

        integer
      end

      def normalize_positive_integer(value, name)
        integer = normalize_integer(value, name)
        raise ArgumentError, "#{name} must be greater than or equal to 1" if integer < 1

        integer
      end

      def normalize_integer(value, name)
        integer =
          if value.is_a?(Integer)
            value
          elsif value.respond_to?(:to_int)
            value.to_int
          elsif value.is_a?(String)
            Integer(value, exception: false)
          end

        raise TypeError, "#{name} must be an Integer or integer-like value" if integer.nil?

        integer
      end

      def normalize_source_refs(value)
        Array(value).map do |source_ref|
          unless source_ref.is_a?(SourceRef)
            raise TypeError,
                  "source_refs must contain only Agent::SessionContext::SourceRef values"
          end

          source_ref
        end.freeze
      end

      def normalize_optional_string(value, name)
        return if value.nil?
        raise TypeError, "#{name} must be a String" unless value.respond_to?(:to_str)

        String.new(value.to_str).freeze
      end

      def validate_consistency!(bytes:, occurrences:, source_refs:, text:)
        raise ArgumentError, "occurrences must equal source_refs length" unless occurrences == source_refs.length
        return if text.nil? || bytes == text.bytesize

        raise ArgumentError, "bytes must equal text bytesize"
      end
    end
  end
end
