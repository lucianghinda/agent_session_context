# frozen_string_literal: true

module Agent
  module SessionContext
    class EvidenceCollector
      DOCUMENT_BASENAMES = %w[agents.md claude.md readme readme.md].freeze
      DOCUMENT_EXTENSIONS = %w[.md .markdown .txt .pdf .doc .docx .odt .rtf].freeze
      PATH_KEYS = %w[path file_path filename source destination target].freeze
      # rubocop:disable-next Layout/LineLength -- splitting this regexp would obscure its URL grammar
      SCHEMELESS_URL_PATTERN = %r{(?<![A-Za-z0-9_./-])(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}(?::\d+)?(?:/[^\s"'<>?#]+)+(?:\?[^\s"'<>#]*)?(?:#[^\s"'<>]*)?}i
      SCHEME_URL_PATTERN = %r{[A-Za-z][A-Za-z0-9+\-.]*://[^\s"'<>]+}
      TOOL_ACTIONS = {
        "Read" => :read,
        "read_file" => :read,
        "view_image" => :read,
        "Write" => :modified,
        "Edit" => :modified,
        "MultiEdit" => :modified,
        "apply_patch" => :modified,
        "move_file" => :modified
      }.freeze
      PATH_SCAN_PATTERN = %r{(?:\.\.?/|/)?[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)+}

      Result = Data.define(:files, :tool_activity) do
        def documents
          files.select { |item| EvidenceCollector.document_item?(item) }.freeze
        end
      end

      class << self
        def document_item?(item)
          item.kind == :file && document_path?(item.label)
        end

        def document_path?(path)
          basename = File.basename(path).downcase
          extension = File.extname(path).downcase

          DOCUMENT_BASENAMES.include?(basename) || DOCUMENT_EXTENSIONS.include?(extension)
        end
      end

      def call(transcript)
        tool_activity = []
        files = {}

        transcript.entries.each do |entry|
          entry.parts.each do |part|
            next unless part.type == :tool_use

            parsed_input = parse_input(part.text)
            tool_activity << build_tool_item(part, parsed_input)

            extract_paths(part.text, parsed_input).each do |path|
              add_item(files, kind: :file, path: path, action: action_for(part.name), source_ref: part.source_ref)
            end
          end
        end

        file_items = files.values.freeze

        Result.new(files: file_items, tool_activity: tool_activity.freeze)
      end

      private

      def build_tool_item(part, parsed_input)
        Item.new(
          kind: :tool,
          label: part.name || "(unknown)",
          evidence: :observed,
          source_refs: [part.source_ref],
          attributes: tool_attributes(part.call_id, parsed_input)
        )
      end

      def tool_attributes(call_id, parsed_input)
        attributes = { call_id: call_id }
        return attributes unless parsed_input.is_a?(Hash)

        attributes[:input_keys] = parsed_input.keys.map { |key| String.new(key.to_s).freeze }.sort.freeze
        attributes
      end

      def parse_input(raw_input)
        return unless raw_input.is_a?(String)

        JSON.parse(raw_input)
      rescue JSON::ParserError, TypeError
        nil
      end

      def extract_paths(raw_input, parsed_input)
        keyed_paths = extract_keyed_paths(parsed_input)
        return keyed_paths unless keyed_paths.empty?

        scan_plain_text(raw_input)
      end

      def extract_keyed_paths(parsed_input)
        return [] unless parsed_input.is_a?(Array) || parsed_input.is_a?(Hash)

        seen = {}
        collected = []
        collect_keyed_paths(parsed_input, seen, collected, under_path_key: false)
        collected.freeze
      end

      def collect_keyed_paths(value, seen, collected, under_path_key:)
        case value
        when Hash
          value.each do |key, child|
            collect_keyed_paths(child, seen, collected, under_path_key: under_path_key || PATH_KEYS.include?(key.to_s))
          end
        when Array
          value.each do |child|
            collect_keyed_paths(child, seen, collected, under_path_key: under_path_key)
          end
        when String
          append_unique_path(collected, seen, value) if valid_keyed_path?(value) && under_path_key
        end
      end

      def scan_plain_text(raw_input)
        return [].freeze unless raw_input.is_a?(String)

        spans = url_spans(raw_input)
        span_index = 0
        seen = {}

        raw_input.to_enum(:scan, PATH_SCAN_PATTERN).each_with_object([]) do |_ignored, collected|
          match = Regexp.last_match
          span_index = advance_span_index(spans, span_index, match.begin(0))
          next if overlap?(spans, span_index, match.begin(0), match.end(0))

          append_unique_path(collected, seen, match[0])
        end.freeze
      end

      def valid_keyed_path?(value)
        !value.empty? && !value.include?("\0") && !url_like?(value)
      end

      def url_like?(value)
        value.match?(/\A#{SCHEME_URL_PATTERN}\z/o) || value.match?(/\A#{SCHEMELESS_URL_PATTERN}\z/o)
      end

      def url_spans(raw_input)
        spans = []

        [SCHEME_URL_PATTERN, SCHEMELESS_URL_PATTERN].each do |pattern|
          raw_input.to_enum(:scan, pattern).each do
            match = Regexp.last_match
            spans << [match.begin(0), match.end(0)]
          end
        end

        merge_spans(spans)
      end

      def merge_spans(spans)
        return [].freeze if spans.empty?

        sorted_spans = spans.sort_by { |start_index, end_index| [start_index, end_index] }
        merged = [sorted_spans.first.dup]

        sorted_spans.drop(1).each do |start_index, end_index|
          current_span = merged.last

          if start_index <= current_span[1]
            current_span[1] = [current_span[1], end_index].max
          else
            merged << [start_index, end_index]
          end
        end

        merged.freeze
      end

      def advance_span_index(spans, span_index, match_start)
        span_index += 1 while span_index < spans.length && spans[span_index][1] <= match_start
        span_index
      end

      def overlap?(spans, span_index, _match_start, match_end)
        span_index < spans.length && spans[span_index][0] < match_end
      end

      def append_unique_path(collected, seen, path)
        return if seen.key?(path)

        seen[path] = true
        collected << path
      end

      def action_for(tool_name)
        TOOL_ACTIONS.fetch(tool_name.to_s, :referenced)
      end

      def add_item(collection, kind:, path:, action:, source_ref:)
        key = [kind, path, action]
        existing = collection[key]

        if existing
          return if existing.source_refs.include?(source_ref)

          collection[key] = Item.new(
            kind: kind,
            label: path,
            evidence: :observed,
            source_refs: existing.source_refs + [source_ref],
            attributes: existing.attributes
          )
          return
        end

        collection[key] = Item.new(
          kind: kind,
          label: path,
          evidence: :observed,
          source_refs: [source_ref],
          attributes: { action: action }
        )
      end
    end
  end
end
