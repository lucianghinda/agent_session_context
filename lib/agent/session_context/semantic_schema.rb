# frozen_string_literal: true

module Agent
  module SessionContext
    class SemanticSchema
      EVIDENCE_VALUES = %w[explicit inferred].freeze

      class << self
        def extraction
          {
            "type" => "object",
            "required" => SemanticCategories.external_keys,
            "additionalProperties" => false,
            "properties" => SemanticCategories.all.to_h do |category|
              [category.external_key, array_schema(item_schema(category.item_shape))]
            end
          }
        end

        private

        def array_schema(item_schema)
          {
            "type" => "array",
            "items" => item_schema
          }
        end

        def item_schema(item_shape)
          case item_shape
          when :term
            term_item_schema
          else
            text_item_schema
          end
        end

        def text_item_schema
          {
            "type" => "object",
            "required" => %w[text evidence source_refs],
            "additionalProperties" => false,
            "properties" => {
              "text" => { "type" => "string" },
              "evidence" => { "type" => "string", "enum" => EVIDENCE_VALUES },
              "source_refs" => source_refs_schema
            }
          }
        end

        def term_item_schema
          {
            "type" => "object",
            "required" => %w[term definition evidence source_refs],
            "additionalProperties" => false,
            "properties" => {
              "term" => { "type" => "string" },
              "definition" => { "type" => "string" },
              "evidence" => { "type" => "string", "enum" => EVIDENCE_VALUES },
              "source_refs" => source_refs_schema
            }
          }
        end

        def source_refs_schema
          {
            "type" => "array",
            "minItems" => 1,
            "items" => { "type" => "string" }
          }
        end
      end
    end
  end
end
