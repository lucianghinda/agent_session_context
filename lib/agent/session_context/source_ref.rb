# frozen_string_literal: true

module Agent
  module SessionContext
    SourceRef = Data.define(:session_uid, :message_index, :part_index) do
      def initialize(session_uid:, message_index:, part_index:)
        super(
          session_uid: normalize_string(session_uid, :session_uid),
          message_index: normalize_positive_index(message_index, :message_index),
          part_index: normalize_positive_index(part_index, :part_index)
        )
      end

      def to_s
        format("%<session_uid>s/message:%<message_index>06d/part:%<part_index>06d",
               session_uid: session_uid,
               message_index: message_index,
               part_index: part_index)
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

      def normalize_string(value, name)
        raise TypeError, "#{name} must be a String" unless value.respond_to?(:to_str)

        String.new(value.to_str).freeze
      end
    end
  end
end
