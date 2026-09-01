# frozen_string_literal: true

require "test_helper"

class SummaryParserTest < Minitest::Test
  def test_semantic_categories_define_a_single_frozen_catalog
    categories = Agent::SessionContext::SemanticCategories.all

    assert_predicate categories, :frozen?
    assert categories.all?(&:frozen?)
    assert_equal(
      [
        ["goals", :goal, :goals, "stated goals or desired outcomes from the conversation", :text],
        ["decisions", :decision, :decisions, "decisions the participants have already made", :text],
        ["terms", :term, :terms, "project-specific terms with their definitions", :term],
        ["constraints", :constraint, :constraints, "limits, requirements, or non-negotiables", :text],
        ["open_questions", :open_question, :open_questions, "questions that are still unresolved", :text],
        ["next_actions", :next_action, :next_actions, "concrete follow-up actions that someone should take", :text]
      ],
      categories.map do |category|
        [
          category.external_key,
          category.internal_kind,
          category.snapshot_field,
          category.prompt_description,
          category.item_shape
        ]
      end
    )
    assert_same categories[0], Agent::SessionContext::SemanticCategories.lookup("goals")
    assert_same categories[0], Agent::SessionContext::SemanticCategories.lookup(:goal)
  end

  def test_semantic_schema_extraction_has_deterministic_closed_shape
    schema = Agent::SessionContext::SemanticSchema.extraction

    assert_equal "object", schema.fetch("type")
    assert_equal false, schema.fetch("additionalProperties")
    assert_equal %w[constraints decisions goals next_actions open_questions terms], schema.fetch("required").sort

    %w[goals decisions constraints open_questions next_actions].each do |category|
      assert_equal "array", schema.fetch("properties").fetch(category).fetch("type")

      item_schema = schema.fetch("properties").fetch(category).fetch("items")
      assert_equal "object", item_schema.fetch("type")
      assert_equal false, item_schema.fetch("additionalProperties")
      assert_equal %w[evidence source_refs text], item_schema.fetch("required").sort
      assert_equal "string", item_schema.fetch("properties").fetch("text").fetch("type")
      assert_equal "string", item_schema.fetch("properties").fetch("evidence").fetch("type")
      assert_equal %w[explicit inferred], item_schema.fetch("properties").fetch("evidence").fetch("enum")
      assert_equal "array", item_schema.fetch("properties").fetch("source_refs").fetch("type")
      assert_equal 1, item_schema.fetch("properties").fetch("source_refs").fetch("minItems")
    end

    term_schema = schema.fetch("properties").fetch("terms").fetch("items")
    assert_equal false, term_schema.fetch("additionalProperties")
    assert_equal %w[definition evidence source_refs term], term_schema.fetch("required").sort
    assert_equal "string", term_schema.fetch("properties").fetch("term").fetch("type")
    assert_equal "string", term_schema.fetch("properties").fetch("definition").fetch("type")
    assert_equal %w[explicit inferred], term_schema.fetch("properties").fetch("evidence").fetch("enum")
  end

  def test_call_parses_all_supported_categories_and_freezes_results
    first_ref = ref(1, 1)
    second_ref = ref(2, 1)

    json = JSON.generate(
      "goals" => [{ "text" => "Ship grounded summaries", "evidence" => "explicit", "source_refs" => [first_ref.to_s] }],
      "decisions" => [{ "text" => "Keep packet size bounded", "evidence" => "inferred",
                        "source_refs" => [second_ref.to_s] }],
      "terms" => [{ "term" => "packet", "definition" => "A bounded evidence chunk", "evidence" => "explicit",
                    "source_refs" => [first_ref.to_s] }],
      "constraints" => [{ "text" => "Max 64 KiB per chunk", "evidence" => "explicit",
                          "source_refs" => [second_ref.to_s] }],
      "open_questions" => [{ "text" => "Should truncation remain JSON-valid?", "evidence" => "inferred",
                             "source_refs" => [second_ref.to_s] }],
      "next_actions" => [{ "text" => "Run the full test suite", "evidence" => "explicit",
                           "source_refs" => [first_ref.to_s, second_ref.to_s] }]
    )

    result = parser.call(json, allowed_refs: [second_ref, first_ref])

    assert_equal [], result.warnings
    assert_predicate result.items, :frozen?
    assert_predicate result.warnings, :frozen?

    assert_equal([
                   [:goal, "Ship grounded summaries", nil, :explicit, [first_ref]],
                   [:decision, "Keep packet size bounded", nil, :inferred, [second_ref]],
                   [:term, "packet", "A bounded evidence chunk", :explicit, [first_ref]],
                   [:constraint, "Max 64 KiB per chunk", nil, :explicit, [second_ref]],
                   [:open_question, "Should truncation remain JSON-valid?", nil, :inferred, [second_ref]],
                   [:next_action, "Run the full test suite", nil, :explicit, [first_ref, second_ref]]
                 ], result.items.map { |item| [item.kind, item.label, item.detail, item.evidence, item.source_refs] })
  end

  def test_call_raises_invalid_summary_for_invalid_json
    error = assert_raises(Agent::SessionContext::InvalidSummary) do
      parser.call("{broken", allowed_refs: [ref(1, 1)])
    end

    assert_match(/invalid json/i, error.message)
    assert_match(/top-level object/i, error.message)
  end

  def test_call_drops_unknown_categories_but_keeps_valid_known_items
    source_ref = ref(1, 1)

    result = parser.call(
      JSON.generate(full_payload(
                      "goals" => [{ "text" => "Keep going", "evidence" => "explicit",
                                    "source_refs" => [source_ref.to_s] }],
                      "surprises" => [{ "text" => "Ignore me" }]
                    )),
      allowed_refs: [source_ref]
    )

    assert_equal([[:goal, "Keep going"]], result.items.map { |item| [item.kind, item.label] })
    assert_equal 1, result.warnings.length
    assert_match(/unknown category/i, result.warnings.first)
  end

  def test_call_drops_items_with_invalid_evidence_refs_or_extra_keys
    source_ref = ref(1, 1)
    other_ref = ref(1, 2)

    result = parser.call(
      JSON.generate(full_payload(
                      "goals" => [
                        { "text" => "Keep valid item", "evidence" => "explicit", "source_refs" => [source_ref.to_s] },
                        { "text" => "Observed is not allowed", "evidence" => "observed",
                          "source_refs" => [source_ref.to_s] },
                        { "text" => "Unknown ref", "evidence" => "explicit", "source_refs" => [other_ref.to_s] },
                        { "text" => "Missing refs", "evidence" => "explicit" },
                        { "text" => "Extra key", "evidence" => "explicit", "source_refs" => [source_ref.to_s],
                          "score" => 1 },
                        { "text" => 1, "evidence" => "explicit", "source_refs" => [source_ref.to_s] }
                      ]
                    )),
      allowed_refs: [source_ref]
    )

    assert_equal([[:goal, "Keep valid item", [source_ref]]], result.items.map do |item|
      [item.kind, item.label, item.source_refs]
    end)
    assert_equal 5, result.warnings.length
    assert result.warnings.all?(&:frozen?)
    assert(result.warnings.any? { |warning| warning.match?(/evidence/i) })
    assert(result.warnings.any? { |warning| warning.match?(/unknown source ref/i) })
    assert(result.warnings.any? { |warning| warning.match?(/source_refs/i) })
    assert(result.warnings.any? { |warning| warning.match?(/additional properties|extra key/i) })
    assert(result.warnings.any? { |warning| warning.match?(/text/i) })
  end

  def test_call_rejects_invalid_top_level_shapes
    error = assert_raises(Agent::SessionContext::InvalidSummary) do
      parser.call(JSON.generate([{ "text" => "nope" }]), allowed_refs: [ref(1, 1)])
    end

    assert_match(/top-level object/i, error.message)

    error = assert_raises(Agent::SessionContext::InvalidSummary) do
      parser.call(JSON.generate("goals" => { "text" => "still nope" }), allowed_refs: [ref(1, 1)])
    end

    assert_match(/goals/i, error.message)
    assert_match(/array/i, error.message)
  end

  def test_call_raises_when_required_known_categories_are_missing
    error = assert_raises(Agent::SessionContext::InvalidSummary) do
      parser.call(
        JSON.generate("goals" => []),
        allowed_refs: [ref(1, 1)]
      )
    end

    assert_match(/missing/i, error.message)
    assert_match(/decisions/i, error.message)
    assert_match(/next_actions/i, error.message)
  end

  def test_call_merges_duplicate_items_with_explicit_precedence_when_explicit_comes_first
    first_ref = ref(1, 1)
    second_ref = ref(1, 2)

    result = parser.call(
      JSON.generate(full_payload(
                      "goals" => [
                        { "text" => "Bound packet size", "evidence" => "explicit", "source_refs" => [first_ref.to_s] },
                        { "text" => "Bound packet size", "evidence" => "inferred", "source_refs" => [second_ref.to_s] }
                      ],
                      "next_actions" => [
                        { "text" => "Run rake test", "evidence" => "explicit", "source_refs" => [second_ref.to_s] },
                        { "text" => "Run rake test", "evidence" => "explicit", "source_refs" => [first_ref.to_s] }
                      ]
                    )),
      allowed_refs: [second_ref, first_ref]
    )

    assert_equal([
                   [:goal, "Bound packet size", :explicit, [first_ref, second_ref]],
                   [:next_action, "Run rake test", :explicit, [second_ref, first_ref]]
                 ], result.items.map { |item| [item.kind, item.label, item.evidence, item.source_refs] })
  end

  def test_call_merges_duplicate_items_with_explicit_precedence_when_explicit_comes_last
    first_ref = ref(1, 1)
    second_ref = ref(1, 2)

    result = parser.call(
      JSON.generate(full_payload(
                      "goals" => [
                        { "text" => "Bound packet size", "evidence" => "inferred", "source_refs" => [first_ref.to_s] },
                        { "text" => "Bound packet size", "evidence" => "explicit", "source_refs" => [second_ref.to_s] }
                      ]
                    )),
      allowed_refs: [first_ref, second_ref]
    )

    assert_equal([
                   [:goal, "Bound packet size", :explicit, [first_ref, second_ref]]
                 ], result.items.map { |item| [item.kind, item.label, item.evidence, item.source_refs] })
  end

  def test_call_rejects_allowed_refs_without_source_ref_objects
    error = assert_raises(TypeError) do
      parser.call(
        JSON.generate(full_payload("goals" => [{ "text" => "Keep going", "evidence" => "explicit",
                                                 "source_refs" => [ref(1, 1).to_s] }])),
        allowed_refs: [ref(1, 1).to_s]
      )
    end

    assert_match(/allowed_refs/i, error.message)
    assert_match(/SourceRef/, error.message)

    error = assert_raises(TypeError) do
      parser.call(
        JSON.generate(full_payload("goals" => [{ "text" => "Keep going", "evidence" => "explicit",
                                                 "source_refs" => [ref(1, 1).to_s] }])),
        allowed_refs: [Object.new]
      )
    end

    assert_match(/allowed_refs/i, error.message)
    assert_match(/SourceRef/, error.message)
  end

  def test_call_drops_items_that_cite_unrepresented_source_refs
    first_ref = ref(1, 1)
    missing_ref = ref(1, 2)

    result = parser.call(
      JSON.generate(full_payload(
                      "goals" => [
                        { "text" => "Represented claim", "evidence" => "explicit", "source_refs" => [first_ref.to_s] },
                        { "text" => "Unrepresented claim", "evidence" => "explicit",
                          "source_refs" => [missing_ref.to_s] }
                      ]
                    )),
      allowed_refs: [first_ref]
    )

    assert_equal([[:goal, "Represented claim", [first_ref]]], result.items.map do |item|
      [item.kind, item.label, item.source_refs]
    end)
    assert_equal 1, result.warnings.length
    assert_match(/unknown source ref/i, result.warnings.first)
  end

  private

  def parser
    @parser ||= Agent::SessionContext::SummaryParser.new
  end

  def ref(message_index, part_index)
    Agent::SessionContext::SourceRef.new(
      session_uid: "codex:session-123",
      message_index: message_index,
      part_index: part_index
    )
  end

  def full_payload(overrides = {})
    {
      "goals" => [],
      "decisions" => [],
      "terms" => [],
      "constraints" => [],
      "open_questions" => [],
      "next_actions" => []
    }.merge(overrides)
  end
end
