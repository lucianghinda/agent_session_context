# frozen_string_literal: true

module Agent
  module SessionContext
    module Renderers
      module Serializer
        module_function

        def serialize(value)
          case value
          when nil, true, false, Integer
            value
          when Float
            serialize_float(value)
          when String
            scrub_string(value)
          when Symbol
            scrub_string(value.to_s)
          when Time
            value.iso8601
          when Array
            value.map { |entry| serialize(entry) }
          when Hash
            serialize_hash(value)
          else
            return serialize_data(value) if data_object?(value)

            scrub_string(value.to_s)
          end
        end

        def scrub_string(value)
          value.encode("UTF-8", invalid: :replace, undef: :replace)
        end

        def data_object?(value)
          defined?(Data) && value.is_a?(Data)
        end

        def serialize_data(value)
          value.members.to_h do |member|
            [member.to_s, serialize_member(member, value.public_send(member))]
          end
        end

        def serialize_hash(value)
          normalized_hash_entries(value).each_with_object({}) do |(key, nested_value), serialized|
            serialized[key] = serialize(nested_value)
          end
        end

        def normalized_hash_entries(value)
          entries = value.each_with_object([]) do |(key, nested_value), collected|
            collected << [normalized_key(key), nested_value]
          end
          detect_duplicate_keys!(entries)
          entries.sort_by(&:first)
        end

        def detect_duplicate_keys!(entries)
          entries.group_by(&:first).sort_by(&:first).each do |key, grouped_entries|
            next unless grouped_entries.length > 1

            raise ArgumentError, "duplicate serialized key: #{safe_dump(key)}"
          end
        end

        def serialize_member(member, value)
          return serialize_timestamp(value) if %i[at captured_at].include?(member.to_sym)

          serialize(value)
        end

        def serialize_timestamp(value)
          case value
          when nil
            nil
          when Time
            value.iso8601
          when String
            scrub_string(value)
          else
            raise ArgumentError, "unsupported timestamp value: #{unsupported_value_label(value)}"
          end
        end

        def serialize_float(value)
          raise ArgumentError, "unsupported numeric value: #{unsupported_value_label(value)}" unless value.finite?

          value
        end

        def normalized_key(key)
          scrub_string(key.to_s)
        end

        def safe_dump(value)
          case value
          when String
            scrub_string(value).dump
          when Symbol
            scrub_string(value.to_s).dump
          when Float
            return "NaN" if value.nan?
            return "Infinity" if value.infinite? == 1
            return "-Infinity" if value.infinite? == -1

            value.to_s
          else
            scrub_string(value.inspect)
          end
        end

        def unsupported_value_label(value)
          klass = value.class
          name = klass.name
          return "(anonymous class)" if name.nil? || name.empty?

          scrub_string(name)
        end
      end
    end
  end
end
