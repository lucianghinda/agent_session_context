# frozen_string_literal: true

module Agent
  module SessionContext
    class SemanticCategories
      Category = Data.define(
        :external_key,
        :internal_kind,
        :snapshot_field,
        :prompt_description,
        :item_shape
      )

      ALL = [
        Category.new(
          external_key: "goals",
          internal_kind: :goal,
          snapshot_field: :goals,
          prompt_description: "stated goals or desired outcomes from the conversation",
          item_shape: :text
        ),
        Category.new(
          external_key: "decisions",
          internal_kind: :decision,
          snapshot_field: :decisions,
          prompt_description: "decisions the participants have already made",
          item_shape: :text
        ),
        Category.new(
          external_key: "terms",
          internal_kind: :term,
          snapshot_field: :terms,
          prompt_description: "project-specific terms with their definitions",
          item_shape: :term
        ),
        Category.new(
          external_key: "constraints",
          internal_kind: :constraint,
          snapshot_field: :constraints,
          prompt_description: "limits, requirements, or non-negotiables",
          item_shape: :text
        ),
        Category.new(
          external_key: "open_questions",
          internal_kind: :open_question,
          snapshot_field: :open_questions,
          prompt_description: "questions that are still unresolved",
          item_shape: :text
        ),
        Category.new(
          external_key: "next_actions",
          internal_kind: :next_action,
          snapshot_field: :next_actions,
          prompt_description: "concrete follow-up actions that someone should take",
          item_shape: :text
        )
      ].freeze
      EXTERNAL_KEYS = ALL.map(&:external_key).freeze
      SNAPSHOT_FIELDS = ALL.map(&:snapshot_field).uniq.freeze
      EXTERNAL_INDEX = ALL.to_h { |category| [category.external_key, category] }.freeze
      INTERNAL_INDEX = ALL.to_h { |category| [category.internal_kind, category] }.freeze

      private_constant :EXTERNAL_KEYS, :SNAPSHOT_FIELDS, :EXTERNAL_INDEX, :INTERNAL_INDEX

      class << self
        def all
          ALL
        end

        def external_keys
          EXTERNAL_KEYS
        end

        def snapshot_fields
          SNAPSHOT_FIELDS
        end

        def lookup(identifier)
          case identifier
          when String
            EXTERNAL_INDEX[identifier]
          when Symbol
            INTERNAL_INDEX[identifier]
          end
        end
      end
    end
  end
end
