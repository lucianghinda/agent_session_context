# frozen_string_literal: true

module Agent
  module SessionContext
    Prompt = Data.define(:index, :at, :text, :source_refs) do
      def initialize(index:, at:, text:, source_refs:)
        super(
          index: normalize_positive_index(index),
          at: at,
          text: normalize_string(text, :text),
          source_refs: ImmutableValue.copy(Array(source_refs))
        )
      end

      private

      def normalize_positive_index(value)
        index =
          if value.is_a?(Integer)
            value
          elsif value.respond_to?(:to_int)
            value.to_int
          elsif value.is_a?(String)
            Integer(value, exception: false)
          end

        raise TypeError, "index must be an Integer or integer-like value" if index.nil?
        raise ArgumentError, "index must be greater than or equal to 1" if index < 1

        index
      end

      def normalize_string(value, name)
        raise TypeError, "#{name} must be a String" unless value.respond_to?(:to_str)

        String.new(value.to_str).freeze
      end
    end
  end
end
