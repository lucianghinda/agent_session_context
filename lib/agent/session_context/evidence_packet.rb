# frozen_string_literal: true

module Agent
  module SessionContext
    class EvidencePacket
      MAX_BYTES = 65_536
      Result = Data.define(:chunks, :warnings, :source_refs) do
        def source_refs_for(chunk)
          ref_index = source_refs.to_h do |source_ref|
            [EvidencePacket.safe_ref_text(source_ref), source_ref]
          end
          represented_refs = []
          seen_refs = {}

          String(chunk).each_line(chomp: true) do |line|
            prefix, = line.split(" ", 2)
            source_ref = ref_index[prefix]
            next unless source_ref
            next if seen_refs.key?(prefix)

            seen_refs[prefix] = true
            represented_refs << source_ref
          end

          represented_refs.freeze
        end
      end
      TRUNCATABLE_KEYS = {
        message: ["text"].freeze,
        tool_use: %w[input name].freeze,
        observed: ["label"].freeze
      }.freeze
      UNSAFE_SOURCE_REF_TEXT_PATTERN = /(?:\p{Space}|\p{Cntrl})/

      class << self
        def safe_ref_text(source_ref)
          text = source_ref.to_s
          normalized_text = normalize_ref_text(text, source_ref)

          if normalized_text.match?(UNSAFE_SOURCE_REF_TEXT_PATTERN)
            raise ArgumentError,
                  "Source ref text cannot contain whitespace or control characters (#{source_ref_type(source_ref)})"
          end

          normalized_text
        end

        private

        def normalize_ref_text(text, source_ref)
          return text if text.encoding == Encoding::UTF_8 && text.valid_encoding?

          utf8_text = duplicate_as_utf8(text)
          return utf8_text if utf8_text.valid_encoding?
          return utf8_text if utf8_bytes?(text)

          raise ArgumentError,
                "Source ref text must be valid UTF-8 or ASCII-only in a safely " \
                "convertible encoding (#{source_ref_type(source_ref)})"
        rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError
          raise ArgumentError,
                "Source ref text must be valid UTF-8 or ASCII-only in a safely " \
                "convertible encoding (#{source_ref_type(source_ref)})"
        end

        def duplicate_as_utf8(text)
          String.new(text, encoding: text.encoding).dup.force_encoding(Encoding::UTF_8)
        end

        def utf8_bytes?(text)
          text.bytes.all? { |byte| byte < 128 }
        end

        def source_ref_type(source_ref)
          source_ref.class.name || source_ref.class.to_s
        end
      end

      def call(transcript:, observed:)
        warnings = []
        carried_refs = []
        seen_refs = {}
        lines = []

        transcript.entries.each do |entry|
          entry.parts.each do |part|
            line = serialize_transcript_part(entry.role, part, warnings)
            next unless line

            remember_ref(seen_refs, carried_refs, part.source_ref)
            lines << line
          end
        end

        observed_lines(observed).each do |source_ref, payload|
          line = bounded_serialized_line(source_ref, payload, TRUNCATABLE_KEYS.fetch(:observed), warnings)
          remember_ref(seen_refs, carried_refs, source_ref)
          lines << line
        end

        Result.new(
          chunks: chunk_lines(lines).freeze,
          warnings: warnings.map { |warning| String.new(warning).freeze }.freeze,
          source_refs: carried_refs.freeze
        )
      end

      private

      def serialize_transcript_part(role, part, warnings)
        return if part.injected

        case part.type
        when :text
          return unless %i[user assistant system].include?(role)

          bounded_serialized_line(
            part.source_ref,
            {
              "kind" => "message",
              "role" => role.to_s,
              "text" => part.text.to_s
            },
            TRUNCATABLE_KEYS.fetch(:message),
            warnings
          )
        when :tool_use
          bounded_serialized_line(
            part.source_ref,
            {
              "kind" => "tool_use",
              "role" => role.to_s,
              "name" => part.name || "(unknown)",
              "input" => part.text.to_s
            },
            TRUNCATABLE_KEYS.fetch(:tool_use),
            warnings
          )
        end
      end

      def observed_lines(observed)
        lines = []

        observed.files.each do |item|
          classifications = ["file"]
          classifications.unshift("document") if EvidenceCollector.document_item?(item)
          item.source_refs.each do |source_ref|
            lines << [source_ref, observed_payload(item, classifications)]
          end
        end

        lines
      end

      def observed_payload(item, classifications)
        {
          "kind" => "observed",
          "classifications" => classifications.freeze,
          "label" => item.label,
          "action" => item.attributes.fetch(:action).to_s
        }
      end

      def serialize_line(source_ref, payload)
        source_ref_text = validated_source_ref_text(source_ref)
        "#{source_ref_text} #{JSON.generate(payload)}"
      end

      def bounded_serialized_line(source_ref, payload, truncatable_keys, warnings)
        fail_if_fixed_overhead_too_large(source_ref, payload, truncatable_keys)

        line = serialize_line(source_ref, payload)
        return line if line.bytesize <= MAX_BYTES

        bounded_payload = payload.dup

        truncatable_keys.each do |key|
          next unless bounded_payload[key].is_a?(String)

          bounded_value = maximal_fitting_value(source_ref, bounded_payload, key)
          bounded_payload[key] = bounded_value

          line = serialize_line(source_ref, bounded_payload)
          return warning_line(source_ref, line, warnings) if line.bytesize <= MAX_BYTES
        end

        raise ArgumentError, "Evidence line for #{source_ref} cannot fit within #{MAX_BYTES} bytes"
      end

      def fail_if_fixed_overhead_too_large(source_ref, payload, truncatable_keys)
        minimal_payload = payload.each_with_object({}) do |(key, value), normalized|
          normalized[key] = truncatable_keys.include?(key) && value.is_a?(String) ? "" : value
        end

        return if serialize_line(source_ref, minimal_payload).bytesize <= MAX_BYTES

        raise ArgumentError,
              "Source ref and fixed payload overhead cannot fit within #{MAX_BYTES} bytes for #{source_ref}"
      end

      def maximal_fitting_value(source_ref, payload, key)
        original = payload.fetch(key)
        low = 0
        high = original.bytesize
        best = ""

        while low <= high
          middle = (low + high) / 2
          candidate = utf8_prefix(original, middle)
          payload[key] = candidate

          if serialize_line(source_ref, payload).bytesize <= MAX_BYTES
            best = candidate
            low = middle + 1
          else
            high = middle - 1
          end
        end

        payload[key] = original
        best
      end

      def utf8_prefix(text, max_bytes)
        String.new(text.byteslice(0, max_bytes), encoding: Encoding::UTF_8).scrub("")
      end

      def warning_line(source_ref, line, warnings)
        warnings << "Truncated oversized evidence line for #{source_ref}"
        line
      end

      def chunk_lines(lines)
        chunks = []
        current_chunk = String.new

        lines.each do |line|
          if current_chunk.empty?
            current_chunk << line
            next
          end

          projected_size = current_chunk.bytesize + 1 + line.bytesize

          if projected_size <= MAX_BYTES
            current_chunk << "\n" << line
          else
            chunks << current_chunk.freeze
            current_chunk = String.new(line)
          end
        end

        chunks << current_chunk.freeze unless current_chunk.empty?
        chunks
      end

      def remember_ref(seen_refs, carried_refs, source_ref)
        key = validated_source_ref_text(source_ref)
        return if seen_refs.key?(key)

        seen_refs[key] = true
        carried_refs << source_ref
      end

      def validated_source_ref_text(source_ref)
        self.class.safe_ref_text(source_ref)
      end
    end
  end
end
