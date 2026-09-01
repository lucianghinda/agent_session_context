# frozen_string_literal: true

module Agent
  module SessionContext
    module Renderers
      module HumanDisplay
        module_function

        def text_inline(value)
          sanitize_string(value, preserve_newlines: false)
        end

        def text_block(value)
          sanitize_string(value, preserve_newlines: true).split("\n", -1).map { |line| "| #{line}" }.join("\n")
        end

        def markdown_text(value)
          escape_markdown(text_inline(value))
        end

        def markdown_literal(value)
          literal = text_inline(value)
          return "<code></code>" if literal.empty?
          return "<code>#{literal}</code>" if literal.match?(/\A +\z/)

          fence = "`" * [longest_backtick_run(literal) + 1, 1].max
          "#{fence}#{code_span_content(literal)}#{fence}"
        end

        def markdown_block(value)
          content = sanitize_string(value, preserve_newlines: true)
          fence = "`" * [longest_backtick_run(content) + 1, 3].max

          ["#{fence}text", content, fence].join("\n")
        end

        def timestamp(value)
          serialized = Serializer.serialize_timestamp(value)
          return if serialized.nil?

          serialized.to_s
        end

        def refs(source_refs)
          Array(source_refs).map { |ref| "#{ref.message_index}:#{ref.part_index}" }.join(", ")
        end

        def attributes(hash, inline_formatter:)
          Serializer.normalized_hash_entries(hash).map do |key, value|
            "#{inline_formatter.call(key)}=#{attribute_value(value, inline_formatter)}"
          end.join(", ")
        end

        def attribute_value(value, inline_formatter)
          return "{#{attributes(value, inline_formatter:)}}" if value.is_a?(Hash)
          return value.map { |entry| attribute_value(entry, inline_formatter) }.join(",") if value.is_a?(Array)

          inline_formatter.call(Serializer.serialize(value).to_s)
        end

        def sanitize_string(value, preserve_newlines:)
          scrubbed = Serializer.scrub_string(value.to_s)
          buffer = String.new(encoding: Encoding::UTF_8)

          scrubbed.each_codepoint do |codepoint|
            if preserve_newlines && codepoint == 0x0A
              buffer << "\n"
              next
            end

            visible = visible_control_escape(codepoint)
            buffer << (visible || codepoint)
          end

          buffer
        end

        def escape_markdown(value)
          escaped = value.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
          escaped = escaped.gsub(/([\\`*\[\]#])/, "\\\\\\1")
          escaped = escaped.gsub(/(^|[^[:alnum:]])_([^_]+)_([^[:alnum:]]|$)/, '\1\\_\2\\_\3')
          escaped.gsub("-", "\\-")
        end

        def code_span_content(literal)
          return " #{literal} " if literal.start_with?("`") || literal.end_with?("`")
          return " #{literal} " if literal.start_with?(" ") && literal.end_with?(" ")

          literal
        end

        def longest_backtick_run(value)
          value.scan(/`+/).map(&:length).max || 0
        end

        def visible_control_escape(codepoint)
          case codepoint
          when 0x09
            "\\t"
          when 0x0A
            "\\n"
          when 0x0D
            "\\r"
          when 0x1B
            "\\e"
          when 0x00..0x08, 0x0B..0x0C, 0x0E..0x1A, 0x1C..0x1F, 0x7F, 0x80..0x9F
            format("\\u%04X", codepoint)
          end
        end
      end
    end
  end
end
