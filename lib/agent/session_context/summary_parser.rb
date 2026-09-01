# frozen_string_literal: true

module Agent
  module SessionContext
    class SummaryParser
      Result = Data.define(:items, :warnings)

      ALLOWED_EVIDENCE = %w[explicit inferred].freeze
      TEXT_KEYS = %w[text evidence source_refs].freeze
      TERM_KEYS = %w[term definition evidence source_refs].freeze
      ITEM_KEYS = {
        text: TEXT_KEYS,
        term: TERM_KEYS
      }.freeze
      REQUIRED_CATEGORIES = SemanticCategories.external_keys

      def call(json, allowed_refs:)
        payload = parse_payload(json)
        allowed_ref_index = build_allowed_ref_index(allowed_refs)
        validate_known_categories!(payload)
        warnings = []
        merged_items = {}
        ordered_items = []

        payload.each do |category, value|
          definition = SemanticCategories.lookup(category)
          unless definition
            warnings << "Dropped unknown category #{category.inspect}"
            next
          end

          value.each_with_index do |raw_item, item_index|
            item = parse_item(definition, raw_item, item_index, allowed_ref_index, warnings)
            next unless item

            key = [item.kind, item.label, item.detail]
            existing = merged_items[key]

            if existing
              merged_items[key] = merge_item_refs(existing, item)
            else
              merged_items[key] = item
              ordered_items << key
            end
          end
        end

        Result.new(
          items: ordered_items.map { |key| merged_items.fetch(key) }.freeze,
          warnings: warnings.map { |warning| String.new(warning).freeze }.freeze
        )
      end

      private

      def parse_payload(json)
        payload = JSON.parse(json)
      rescue JSON::ParserError
        raise InvalidSummary, "Invalid JSON summary. Provide a JSON top-level object with the supported categories."
      else
        raise InvalidSummary, "Summary must be a JSON top-level object." unless payload.is_a?(Hash)

        payload
      end

      def validate_known_categories!(payload)
        REQUIRED_CATEGORIES.each do |category|
          next unless payload.key?(category)

          raise InvalidSummary, "#{category} must be an array" unless payload[category].is_a?(Array)
        end

        missing_categories = REQUIRED_CATEGORIES - payload.keys
        return if missing_categories.empty?

        raise InvalidSummary,
              "Summary is missing required categories: #{missing_categories.join(", ")}"
      end

      def build_allowed_ref_index(allowed_refs)
        normalize_allowed_refs(allowed_refs).to_h do |source_ref|
          [source_ref.to_s, source_ref]
        end
      end

      def normalize_allowed_refs(allowed_refs)
        refs =
          if allowed_refs.is_a?(Array)
            allowed_refs
          elsif allowed_refs.respond_to?(:to_a) && !allowed_refs.is_a?(String)
            allowed_refs.to_a
          elsif allowed_refs.respond_to?(:each) && !allowed_refs.is_a?(String)
            allowed_refs.each_with_object([]) { |source_ref, collected| collected << source_ref }
          else
            raise TypeError, "allowed_refs must be an enumerable of Agent::SessionContext::SourceRef objects"
          end

        refs.each do |source_ref|
          unless source_ref.is_a?(SourceRef)
            raise TypeError,
                  "allowed_refs must contain only Agent::SessionContext::SourceRef objects"
          end
        end

        refs
      end

      def parse_item(category, raw_item, item_index, allowed_ref_index, warnings)
        category_name = category.external_key

        unless raw_item.is_a?(Hash)
          warnings << "Dropped #{category_name}[#{item_index}] because items must be objects"
          return
        end

        expected_keys = ITEM_KEYS.fetch(category.item_shape)
        raw_keys = raw_item.keys.sort

        unless raw_keys == expected_keys.sort
          warnings << key_mismatch_warning(category_name, item_index, raw_keys, expected_keys)
          return
        end

        evidence = raw_item["evidence"]
        unless ALLOWED_EVIDENCE.include?(evidence)
          warnings << "Dropped #{category_name}[#{item_index}] because evidence must be explicit or inferred"
          return
        end

        refs = resolve_source_refs(category_name, item_index, raw_item["source_refs"], allowed_ref_index, warnings)
        return unless refs

        case category.item_shape
        when :term
          term = raw_item["term"]
          definition = raw_item["definition"]

          unless term.is_a?(String)
            warnings << "Dropped #{category_name}[#{item_index}] because term must be a string"
            return
          end

          unless definition.is_a?(String)
            warnings << "Dropped #{category_name}[#{item_index}] because definition must be a string"
            return
          end

          Item.new(
            kind: category.internal_kind,
            label: term,
            detail: definition,
            evidence: evidence.to_sym,
            source_refs: refs
          )
        else
          text = raw_item["text"]
          unless text.is_a?(String)
            warnings << "Dropped #{category_name}[#{item_index}] because text must be a string"
            return
          end

          Item.new(
            kind: category.internal_kind,
            label: text,
            detail: nil,
            evidence: evidence.to_sym,
            source_refs: refs
          )
        end
      end

      def resolve_source_refs(category, item_index, raw_refs, allowed_ref_index, warnings)
        unless raw_refs.is_a?(Array) && !raw_refs.empty? && raw_refs.all?(String)
          warnings << "Dropped #{category}[#{item_index}] because source_refs must be a non-empty array of strings"
          return
        end

        resolved = raw_refs.map { |value| allowed_ref_index[value] }
        if resolved.any?(&:nil?)
          warnings << "Dropped #{category}[#{item_index}] because it referenced an unknown source ref"
          return
        end

        resolved.uniq.freeze
      end

      def merge_item_refs(existing, item)
        Item.new(
          kind: existing.kind,
          label: existing.label,
          detail: existing.detail,
          evidence: merged_evidence(existing.evidence, item.evidence),
          source_refs: (existing.source_refs + item.source_refs).uniq,
          attributes: existing.attributes
        )
      end

      def merged_evidence(left, right)
        return :explicit if left == :explicit || right == :explicit

        :inferred
      end

      def key_mismatch_warning(category, item_index, raw_keys, expected_keys)
        missing_keys = expected_keys - raw_keys
        extra_keys = raw_keys - expected_keys
        details = []
        details << "missing #{missing_keys.join(", ")}" unless missing_keys.empty?
        details << "extra keys #{extra_keys.join(", ")}" unless extra_keys.empty?
        details << "additional properties are not allowed" unless extra_keys.empty?
        detail_text = details.join("; ")
        detail_suffix = " (#{detail_text})" unless detail_text.empty?

        "Dropped #{category}[#{item_index}] because item keys must exactly match " \
          "#{expected_keys.join(", ")}#{detail_suffix}"
      end
    end
  end
end
