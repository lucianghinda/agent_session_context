# frozen_string_literal: true

module Agent
  module SessionContext
    Item = Data.define(:kind, :label, :detail, :evidence, :source_refs, :attributes) do
      EVIDENCE_VALUES = %i[observed explicit inferred].freeze

      def initialize(kind:, label:, evidence:, source_refs:, detail: nil, attributes: {})
        unless EVIDENCE_VALUES.include?(evidence)
          raise ArgumentError,
                "evidence must be one of: #{EVIDENCE_VALUES.join(", ")}"
        end

        super(
          kind: kind.to_sym,
          label: normalize_string(label, :label),
          detail: normalize_optional_string(detail, :detail),
          evidence: evidence,
          source_refs: ImmutableValue.copy(Array(source_refs)),
          attributes: normalize_attributes(attributes)
        )
      end

      private

      def normalize_attributes(attributes)
        raise TypeError, "attributes must be a Hash" unless attributes.is_a?(Hash)

        attributes.each_with_object({}) do |(key, value), normalized|
          normalized[normalize_attribute_key(key)] = ImmutableValue.copy(value)
        end.freeze
      end

      def normalize_attribute_key(key)
        return key if key.is_a?(Symbol)
        return key.to_sym if key.respond_to?(:to_sym)

        raise TypeError, "attribute keys must be symbolizable"
      end

      def normalize_string(value, name)
        raise TypeError, "#{name} must be a String" unless value.respond_to?(:to_str)

        String.new(value.to_str).freeze
      end

      def normalize_optional_string(value, name)
        return if value.nil?

        normalize_string(value, name)
      end
    end
  end
end
