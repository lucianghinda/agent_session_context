# frozen_string_literal: true

require "test_helper"

class ValueObjectsTest < Minitest::Test
  def test_source_ref_has_stable_string_form_and_is_immutable
    session_uid = String.new("session-123")
    source_ref = Agent::SessionContext::SourceRef.new(
      session_uid: session_uid,
      message_index: "1",
      part_index: 2
    )

    session_uid.replace("mutated")

    assert_equal "session-123/message:000001/part:000002", source_ref.to_s
    assert_equal "session-123", source_ref.session_uid
    assert_predicate source_ref, :frozen?
    assert_predicate source_ref.session_uid, :frozen?
  end

  def test_source_ref_rejects_indices_below_one
    error = assert_raises(ArgumentError) do
      Agent::SessionContext::SourceRef.new(session_uid: "session-123", message_index: 0, part_index: 1)
    end

    assert_match(/message_index/, error.message)

    error = assert_raises(ArgumentError) do
      Agent::SessionContext::SourceRef.new(session_uid: "session-123", message_index: 1, part_index: -1)
    end

    assert_match(/part_index/, error.message)
  end

  def test_prompt_freezes_text_and_source_refs
    text = String.new("Summarize the session")
    source_refs = [
      Agent::SessionContext::SourceRef.new(session_uid: "session-123", message_index: 1, part_index: 2)
    ]
    prompt = Agent::SessionContext::Prompt.new(index: 1, at: Time.utc(2026, 8, 27, 12, 0, 0), text: text,
                                               source_refs: source_refs)

    text.replace("mutated")
    source_refs << Agent::SessionContext::SourceRef.new(session_uid: "session-123", message_index: 3, part_index: 4)

    assert_equal "Summarize the session", prompt.text
    assert_equal 1, prompt.source_refs.length
    assert_predicate prompt, :frozen?
    assert_predicate prompt.text, :frozen?
    assert_predicate prompt.source_refs, :frozen?
  end

  def test_prompt_deeply_copies_supported_nested_source_ref_values
    shared_ref = [String.new("shared-ref")]
    metadata_key = String.new("kind")
    metadata_value = String.new("prompt")
    metadata = { metadata_key => [metadata_value] }
    observed_at = Time.utc(2026, 8, 27, 12, 5, 0)

    prompt = Agent::SessionContext::Prompt.new(
      index: 1,
      at: observed_at,
      text: "Summarize the session",
      source_refs: [shared_ref, shared_ref, metadata, observed_at]
    )

    shared_ref.first.replace("mutated")
    shared_ref << "later"
    metadata_key.replace("mutated")
    metadata_value.replace("mutated")
    metadata.values.first << "later"

    assert_equal [["shared-ref"], ["shared-ref"], { "kind" => ["prompt"] }, observed_at], prompt.source_refs
    assert_same prompt.source_refs[0], prompt.source_refs[1]
    assert_same observed_at, prompt.source_refs[3]
    assert_deep_frozen prompt.source_refs
  end

  def test_prompt_rejects_cyclic_source_refs
    cyclic_refs = []
    cyclic_refs << cyclic_refs

    error = assert_raises(ArgumentError) do
      Agent::SessionContext::Prompt.new(
        index: 1,
        at: Time.utc(2026, 8, 27, 12, 0, 0),
        text: "Summarize the session",
        source_refs: cyclic_refs
      )
    end

    assert_equal "cyclic arrays and hashes are not supported", error.message
  end

  def test_injected_context_normalizes_and_freezes_its_values
    text = String.new("# AGENTS.md instructions\nUse Ruby")
    refs = [
      Agent::SessionContext::SourceRef.new(
        session_uid: "codex:session-123",
        message_index: 1,
        part_index: 1
      )
    ]

    context = Agent::SessionContext::InjectedContext.new(
      kind: "agents_instructions",
      bytes: text.bytesize,
      occurrences: 1,
      source_refs: refs,
      text:
    )

    text.replace("mutated")
    refs.clear

    assert_equal :agents_instructions, context.kind
    assert_equal 33, context.bytes
    assert_equal 1, context.occurrences
    assert_equal 1, context.source_refs.length
    assert_equal "# AGENTS.md instructions\nUse Ruby", context.text
    assert_predicate context, :frozen?
    assert_predicate context.source_refs, :frozen?
    assert_predicate context.text, :frozen?
  end

  def test_injected_context_validates_counts_refs_and_optional_text
    ref = Agent::SessionContext::SourceRef.new(
      session_uid: "codex:session-123",
      message_index: 1,
      part_index: 1
    )

    context = Agent::SessionContext::InjectedContext.new(
      kind: :provider_meta,
      bytes: 24,
      occurrences: 1,
      source_refs: [ref]
    )

    assert_nil context.text
    assert_equal 24, context.bytes
    assert_raises(ArgumentError) do
      Agent::SessionContext::InjectedContext.new(
        kind: :provider_meta,
        bytes: -1,
        occurrences: 1,
        source_refs: [ref]
      )
    end
    assert_raises(ArgumentError) do
      Agent::SessionContext::InjectedContext.new(
        kind: :provider_meta,
        bytes: 1,
        occurrences: 0,
        source_refs: [ref]
      )
    end
    assert_raises(TypeError) do
      Agent::SessionContext::InjectedContext.new(
        kind: :provider_meta,
        bytes: 1,
        occurrences: 1,
        source_refs: ["not a source ref"]
      )
    end
  end

  def test_injected_context_requires_occurrences_to_match_source_refs
    ref = Agent::SessionContext::SourceRef.new(
      session_uid: "codex:session-123",
      message_index: 1,
      part_index: 1
    )

    error = assert_raises(ArgumentError) do
      Agent::SessionContext::InjectedContext.new(
        kind: :provider_meta,
        bytes: 24,
        occurrences: 2,
        source_refs: [ref]
      )
    end

    assert_equal "occurrences must equal source_refs length", error.message
  end

  def test_injected_context_requires_bytes_to_match_included_text
    error = assert_raises(ArgumentError) do
      Agent::SessionContext::InjectedContext.new(
        kind: :provider_meta,
        bytes: 23,
        occurrences: 1,
        source_refs: [
          Agent::SessionContext::SourceRef.new(
            session_uid: "codex:session-123",
            message_index: 1,
            part_index: 1
          )
        ],
        text: "opaque provider metadata"
      )
    end

    assert_equal "bytes must equal text bytesize", error.message
  end

  def test_item_validates_evidence_and_freezes_refs_and_attributes
    source_refs = [
      Agent::SessionContext::SourceRef.new(session_uid: "session-123", message_index: 1, part_index: 2)
    ]
    attributes = { "token_count" => 10 }
    label = String.new("Use immutable values")
    detail = String.new("Every stored claim should keep its original evidence")
    item = Agent::SessionContext::Item.new(
      kind: "decision",
      label: label,
      detail: detail,
      evidence: :observed,
      source_refs: source_refs,
      attributes: attributes
    )

    label.replace("mutated")
    detail.replace("mutated")
    source_refs << Agent::SessionContext::SourceRef.new(session_uid: "session-123", message_index: 3, part_index: 4)
    attributes["token_count"] = 99

    assert_equal :decision, item.kind
    assert_equal "Use immutable values", item.label
    assert_equal "Every stored claim should keep its original evidence", item.detail
    assert_equal({ token_count: 10 }, item.attributes)
    assert_equal 1, item.source_refs.length
    assert_predicate item, :frozen?
    assert_predicate item.label, :frozen?
    assert_predicate item.detail, :frozen?
    assert_predicate item.source_refs, :frozen?
    assert_predicate item.attributes, :frozen?
  end

  def test_item_allows_nil_detail_and_defaults_attributes_to_safe_empty_hash
    item = Agent::SessionContext::Item.new(
      kind: :decision,
      label: "Use immutable values",
      evidence: :explicit,
      source_refs: []
    )

    assert_nil item.detail
    assert_equal({}, item.attributes)
    assert_predicate item.attributes, :frozen?
  end

  def test_item_deeply_copies_supported_nested_attribute_values
    shared_value = [String.new("shared-attribute")]
    nested_key = String.new("inner")
    nested_value = String.new("leaf")
    deep_key = String.new("depth")
    happened_at = Time.utc(2026, 8, 27, 12, 10, 0)
    attributes = {
      "details" => {
        nested_key => [shared_value, shared_value, { deep_key => nested_value }]
      },
      "happened_at" => happened_at
    }

    item = Agent::SessionContext::Item.new(
      kind: "decision",
      label: "Use immutable values",
      detail: "Every stored claim should keep its original evidence",
      evidence: :observed,
      source_refs: [],
      attributes: attributes
    )

    shared_value.first.replace("mutated")
    shared_value << "later"
    nested_key.replace("mutated")
    nested_value.replace("mutated")
    deep_key.replace("mutated")

    assert_equal(
      {
        details: { "inner" => [["shared-attribute"], ["shared-attribute"], { "depth" => "leaf" }] },
        happened_at:
      },
      item.attributes
    )
    assert_same item.attributes[:details]["inner"][0], item.attributes[:details]["inner"][1]
    assert_same happened_at, item.attributes[:happened_at]
    assert_deep_frozen item.attributes
  end

  def test_item_rejects_unsupported_evidence_values_with_argument_error
    error = assert_raises(ArgumentError) do
      Agent::SessionContext::Item.new(
        kind: :decision,
        label: "Use immutable values",
        detail: "Every stored claim should keep its original evidence",
        evidence: "observed",
        source_refs: [],
        attributes: {}
      )
    end

    assert_match(/evidence/, error.message)

    error = assert_raises(ArgumentError) do
      Agent::SessionContext::Item.new(
        kind: :decision,
        label: "Use immutable values",
        detail: nil,
        evidence: nil,
        source_refs: [],
        attributes: {}
      )
    end

    assert_match(/evidence/, error.message)

    error = assert_raises(ArgumentError) do
      Agent::SessionContext::Item.new(
        kind: :decision,
        label: "Use immutable values",
        detail: "Every stored claim should keep its original evidence",
        evidence: :guessed,
        source_refs: [],
        attributes: {}
      )
    end

    assert_match(/evidence/, error.message)
  end

  def test_snapshot_has_exact_members_and_frozen_default_collections
    assert_equal(
      %i[
        session_uid
        agent
        project_path
        captured_at
        message_count
        prompts
        injected_context
        files
        documents
        tool_activity
        goals
        decisions
        terms
        constraints
        open_questions
        next_actions
        warnings
        summary_metadata
      ],
      Agent::SessionContext::Snapshot.members
    )

    snapshot = Agent::SessionContext::Snapshot.new(
      session_uid: "session-123",
      agent: :codex,
      project_path: nil,
      captured_at: Time.utc(2026, 8, 27, 12, 30, 0),
      message_count: 3
    )

    assert_nil snapshot.project_path
    assert_equal [], snapshot.prompts
    assert_equal [], snapshot.injected_context
    assert_equal [], snapshot.files
    assert_equal [], snapshot.documents
    assert_equal [], snapshot.tool_activity
    assert_equal [], snapshot.goals
    assert_equal [], snapshot.decisions
    assert_equal [], snapshot.terms
    assert_equal [], snapshot.constraints
    assert_equal [], snapshot.open_questions
    assert_equal [], snapshot.next_actions
    assert_equal [], snapshot.warnings
    assert_equal({}, snapshot.summary_metadata)
    assert_predicate snapshot.prompts, :frozen?
    assert_predicate snapshot.injected_context, :frozen?
    assert_predicate snapshot.files, :frozen?
    assert_predicate snapshot.documents, :frozen?
    assert_predicate snapshot.tool_activity, :frozen?
    assert_predicate snapshot.goals, :frozen?
    assert_predicate snapshot.decisions, :frozen?
    assert_predicate snapshot.terms, :frozen?
    assert_predicate snapshot.constraints, :frozen?
    assert_predicate snapshot.open_questions, :frozen?
    assert_predicate snapshot.next_actions, :frozen?
    assert_predicate snapshot.warnings, :frozen?
    assert_predicate snapshot.summary_metadata, :frozen?
  end

  def test_snapshot_freezes_collections_warning_strings_and_metadata
    session_uid = String.new("session-123")
    project_path = String.new("/tmp/project")
    warning = String.new("Missing transcript chunk")
    source_ref = Agent::SessionContext::SourceRef.new(
      session_uid: "session-123",
      message_index: 1,
      part_index: 1
    )
    prompt = Agent::SessionContext::Prompt.new(
      index: 1,
      at: nil,
      text: "Exact prompt",
      source_refs: [source_ref]
    )
    injected = Agent::SessionContext::InjectedContext.new(
      kind: :provider_meta,
      bytes: 4,
      occurrences: 1,
      source_refs: [source_ref],
      text: "meta"
    )
    prompts = [prompt]
    injected_context = [injected]
    files = [String.new("README.md")]
    warnings = [warning]
    summary_metadata = { "token_count" => 42 }

    snapshot = Agent::SessionContext::Snapshot.new(
      session_uid: session_uid,
      agent: "codex",
      project_path: project_path,
      captured_at: Time.utc(2026, 8, 27, 12, 30, 0),
      message_count: 3,
      prompts:,
      injected_context:,
      files: files,
      warnings: warnings,
      summary_metadata: summary_metadata
    )

    session_uid.replace("mutated")
    project_path.replace("mutated")
    prompts.clear
    injected_context.clear
    files << "lib/example.rb"
    warning.replace("mutated")
    warnings << "Another warning"
    summary_metadata["token_count"] = 84

    assert_predicate snapshot, :frozen?
    assert_equal "session-123", snapshot.session_uid
    assert_equal "/tmp/project", snapshot.project_path
    assert_equal [prompt], snapshot.prompts
    assert_equal [injected], snapshot.injected_context
    assert_equal ["README.md"], snapshot.files
    assert_equal ["Missing transcript chunk"], snapshot.warnings
    assert_equal({ token_count: 42 }, snapshot.summary_metadata)
    assert_predicate snapshot.session_uid, :frozen?
    assert_predicate snapshot.project_path, :frozen?
    assert_predicate snapshot.prompts, :frozen?
    assert_predicate snapshot.injected_context, :frozen?
    assert_predicate snapshot.files, :frozen?
    assert_predicate snapshot.warnings, :frozen?
    assert_predicate snapshot.warnings.first, :frozen?
    assert_predicate snapshot.summary_metadata, :frozen?
  end

  def test_snapshot_deeply_copies_nested_collections_and_summary_metadata_values
    shared_file = [String.new("README.md")]
    file_key = String.new("path")
    file_value = String.new("lib/example.rb")
    metadata_key = String.new("units")
    metadata_value = String.new("tokens")
    observed_at = Time.utc(2026, 8, 27, 12, 40, 0)
    warning = String.new("Missing transcript chunk")

    snapshot = Agent::SessionContext::Snapshot.new(
      session_uid: "session-123",
      agent: :codex,
      project_path: nil,
      captured_at: observed_at,
      message_count: 3,
      files: [shared_file, shared_file, { file_key => [file_value] }, observed_at],
      warnings: [warning],
      summary_metadata: {
        "token_count" => { metadata_key => [metadata_value] },
        "observed_at" => observed_at
      }
    )

    shared_file.first.replace("mutated")
    shared_file << "later"
    file_key.replace("mutated")
    file_value.replace("mutated")
    metadata_key.replace("mutated")
    metadata_value.replace("mutated")
    warning.replace("mutated")

    assert_equal [["README.md"], ["README.md"], { "path" => ["lib/example.rb"] }, observed_at], snapshot.files
    assert_same snapshot.files[0], snapshot.files[1]
    assert_same observed_at, snapshot.files[3]
    assert_equal({ token_count: { "units" => ["tokens"] }, observed_at: }, snapshot.summary_metadata)
    assert_same observed_at, snapshot.summary_metadata[:observed_at]
    assert_equal ["Missing transcript chunk"], snapshot.warnings
    assert_deep_frozen snapshot.files
    assert_deep_frozen snapshot.warnings
    assert_deep_frozen snapshot.summary_metadata
  end

  def test_snapshot_rejects_cyclic_summary_metadata_values
    cyclic_value = {}
    cyclic_value["self"] = cyclic_value

    error = assert_raises(ArgumentError) do
      Agent::SessionContext::Snapshot.new(
        session_uid: "session-123",
        agent: :codex,
        project_path: nil,
        captured_at: Time.utc(2026, 8, 27, 12, 30, 0),
        message_count: 3,
        summary_metadata: { "loop" => cyclic_value }
      )
    end

    assert_equal "cyclic arrays and hashes are not supported", error.message
  end

  private

  def assert_deep_frozen(value)
    case value
    when String
      assert_predicate value, :frozen?
    when Array
      assert_predicate value, :frozen?
      value.each { |entry| assert_deep_frozen(entry) }
    when Hash
      assert_predicate value, :frozen?
      value.each do |key, entry|
        assert_deep_frozen(key)
        assert_deep_frozen(entry)
      end
    end
  end
end
