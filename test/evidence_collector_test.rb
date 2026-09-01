# frozen_string_literal: true

require "test_helper"

class EvidenceCollectorTest < Minitest::Test
  def setup
    Agent::SessionContext.const_get(:Transcript)
  end

  def test_call_exposes_canonical_files_with_derived_documents_compatibility_view
    result = collect(
      [
        tool_use_part(name: "Read", call_id: "call-1", input: %({"path":"README.md"})),
        tool_use_part(name: "Read", call_id: "call-2", input: %({"path":"lib/example.rb"}))
      ]
    )

    assert_equal %i[files tool_activity], Agent::SessionContext::EvidenceCollector::Result.members
    refute_respond_to result, :warnings
    assert_equal ["README.md", "lib/example.rb"], result.files.map(&:label)
    assert_equal ["README.md"], result.documents.map(&:label)
    assert_same result.files.first, result.documents.first
    assert_equal [result.files.first.object_id], result.documents.map(&:object_id)
  end

  def test_call_collects_tool_activity_files_and_documents_from_recorded_tool_use_parts
    result = collect(
      [
        tool_use_part(name: "Read", call_id: "call-1", input: %({"path":"/tmp/README.md"})),
        tool_use_part(name: "Write", call_id: "call-2", input: %({"path":"lib/output.rb"})),
        tool_use_part(name: "apply_patch", call_id: "call-3", input: %({"path":"docs/guide.md"})),
        tool_use_part(
          name: "shell",
          call_id: "call-4",
          input: %(sed -n '1,5p' ./docs/guide.md, && cat /tmp/output.log)
        ),
        tool_use_part(
          name: "mystery",
          call_id: "call-5",
          input: %({"target":"assets/logo.png","alpha":1})
        )
      ]
    )

    assert_equal %i[files tool_activity], Agent::SessionContext::EvidenceCollector::Result.members
    assert_predicate result.files, :frozen?
    assert_predicate result.tool_activity, :frozen?

    assert_equal([
                   ["Read", { call_id: "call-1", input_keys: ["path"] }],
                   ["Write", { call_id: "call-2", input_keys: ["path"] }],
                   ["apply_patch", { call_id: "call-3", input_keys: ["path"] }],
                   ["shell", { call_id: "call-4" }],
                   ["mystery", { call_id: "call-5", input_keys: %w[alpha target] }]
                 ], result.tool_activity.map { |item| [item.label, item.attributes] })
    assert(result.tool_activity.all? { |item| item.kind == :tool && item.evidence == :observed })
    assert_predicate result.tool_activity.first.attributes.fetch(:input_keys), :frozen?
    assert_predicate result.tool_activity.last.attributes.fetch(:input_keys), :frozen?

    assert_equal([
                   ["/tmp/README.md", :read],
                   ["lib/output.rb", :modified],
                   ["docs/guide.md", :modified],
                   ["./docs/guide.md", :referenced],
                   ["/tmp/output.log", :referenced],
                   ["assets/logo.png", :referenced]
                 ], result.files.map { |item| [item.label, item.attributes.fetch(:action)] })
    assert(result.files.all? { |item| item.kind == :file && item.evidence == :observed })

    assert_equal([
                   ["/tmp/README.md", :read],
                   ["docs/guide.md", :modified],
                   ["./docs/guide.md", :referenced]
                 ], result.documents.map { |item| [item.label, item.attributes.fetch(:action)] })
    assert_predicate result.documents, :frozen?
    assert(result.documents.all? { |item| item.kind == :file && item.evidence == :observed })
    assert_equal(
      result.files.select do |item|
        ["/tmp/README.md", "docs/guide.md", "./docs/guide.md"].include?(item.label)
      end.map(&:object_id),
      result.documents.map(&:object_id)
    )
  end

  def test_call_recurses_only_under_path_keys_and_keeps_relative_paths_unresolved
    result = collect(
      [
        tool_use_part(
          name: "Read",
          call_id: "call-1",
          input: JSON.generate(
            "path" => ["../docs/guide.txt", { "nested" => ["notes/readme.markdown", 12] }],
            "metadata" => { "note" => "ignored.md" }
          )
        )
      ]
    )

    assert_equal([
                   ["../docs/guide.txt", :read],
                   ["notes/readme.markdown", :read]
                 ], result.files.map { |item| [item.label, item.attributes.fetch(:action)] })
    assert_equal([
                   ["../docs/guide.txt", :read],
                   ["notes/readme.markdown", :read]
                 ], result.documents.map { |item| [item.label, item.attributes.fetch(:action)] })
  end

  def test_call_merges_duplicate_file_and_document_evidence_by_kind_path_and_action
    result = collect(
      [
        tool_use_part(name: "Read", call_id: "call-1", input: %({"path":"README.md"})),
        tool_use_part(name: "Read", call_id: "call-2", input: %({"path":"README.md"}))
      ]
    )

    assert_equal 1, result.files.length
    assert_equal 1, result.documents.length
    assert_equal(%w[call-1 call-2], result.tool_activity.map { |item| item.attributes.fetch(:call_id) })
    assert_equal(
      [
        Agent::SessionContext::SourceRef.new(session_uid: "codex:session-123", message_index: 1, part_index: 1),
        Agent::SessionContext::SourceRef.new(session_uid: "codex:session-123", message_index: 1, part_index: 2)
      ],
      result.files.first.source_refs
    )
    assert_same result.files.first, result.documents.first
  end

  def test_call_ignores_tool_result_bodies_and_injected_text_when_no_tool_use_parts_exist
    result = collect(
      [
        plain_part(type: :tool_result, text: %({"path":"README.md"})),
        plain_part(type: :text, text: "/tmp/secret.txt", injected: true)
      ],
      role: :user
    )

    assert_equal [], result.tool_activity
    assert_equal [], result.files
    assert_equal [], result.documents
  end

  def test_call_never_raises_for_invalid_json_and_keeps_unknown_tool_activity
    result = collect(
      [
        tool_use_part(name: nil, call_id: "call-1", input: "{broken"),
        tool_use_part(name: "mystery", call_id: "call-2", input: "curl https://example.com/a/b")
      ]
    )

    assert_equal ["(unknown)", "mystery"], result.tool_activity.map(&:label)
    assert_equal [{ call_id: "call-1" }, { call_id: "call-2" }], result.tool_activity.map(&:attributes)
    assert_equal [], result.files
    assert_equal [], result.documents
  end

  def test_call_falls_back_to_raw_scan_for_valid_json_without_path_keys
    result = collect(
      [
        tool_use_part(name: "mystery", call_id: "call-1", input: %({"note":"docs/guide.md","alpha":1}))
      ]
    )

    assert_equal([["mystery", { call_id: "call-1", input_keys: %w[alpha note] }]], result.tool_activity.map do |item|
      [item.label, item.attributes]
    end)
    assert_equal([["docs/guide.md", :referenced]], result.files.map do |item|
      [item.label, item.attributes.fetch(:action)]
    end)
    assert_equal([["docs/guide.md", :referenced]], result.documents.map do |item|
      [item.label, item.attributes.fetch(:action)]
    end)
  end

  def test_call_keeps_nil_call_id_in_tool_activity_attributes
    result = collect(
      [
        tool_use_part(name: "Read", call_id: nil, input: %({"beta":2,"path":"README.md","alpha":1}))
      ]
    )

    assert_equal([["Read", { call_id: nil, input_keys: %w[alpha beta path] }]], result.tool_activity.map do |item|
      [item.label, item.attributes]
    end)
    assert_equal([["README.md", :read]], result.files.map { |item| [item.label, item.attributes.fetch(:action)] })
    assert_equal([["README.md", :read]], result.documents.map { |item| [item.label, item.attributes.fetch(:action)] })
  end

  def test_call_table_drives_tool_actions_and_keeps_same_path_with_different_actions_separate
    cases = [
      ["Read", "shared/README.md", :read, "Read"],
      ["read_file", "io/source.txt", :read, "read_file"],
      ["view_image", "images/photo.png", :read, "view_image"],
      ["Write", "writes/out.txt", :modified, "Write"],
      ["Edit", "edits/out.txt", :modified, "Edit"],
      ["MultiEdit", "multi/out.txt", :modified, "MultiEdit"],
      ["apply_patch", "patches/out.txt", :modified, "apply_patch"],
      ["move_file", "moves/out.txt", :modified, "move_file"],
      ["shell", "shared/README.md", :referenced, "shell"],
      [nil, "nil_name/path.txt", :referenced, "(unknown)"],
      ["mystery", "unknown/path.txt", :referenced, "mystery"]
    ]

    result = collect(
      cases.each_with_index.map do |(tool_name, path, _action, _label), index|
        input =
          if tool_name == "shell"
            "cat #{path}"
          else
            %({"path":"#{path}","order":#{index}})
          end

        tool_use_part(name: tool_name, call_id: "call-#{index + 1}", input: input)
      end
    )

    assert_equal cases.map { |(_tool_name, _path, _action, label)| label }, result.tool_activity.map(&:label)
    assert(result.tool_activity.all? { |item| item.kind == :tool })
    assert_equal(
      cases.map { |_tool_name, path, action, _label| [path, action] },
      result.files.map { |item| [item.label, item.attributes.fetch(:action)] }
    )
    assert_includes result.files.map { |item|
      [item.label, item.attributes.fetch(:action)]
    }, ["shared/README.md", :read]
    assert_includes result.files.map { |item|
      [item.label, item.attributes.fetch(:action)]
    }, ["shared/README.md", :referenced]
  end

  def test_call_filters_documents_from_file_items_case_insensitively
    paths = [
      "docs/AGENTS.md",
      "docs/CLAUDE.md",
      "README",
      "guide/README.md",
      "notes/design.MARKDOWN",
      "notes/todo.Txt",
      "files/report.PDF",
      "draft/proposal.Doc",
      "word/spec.DOCX",
      "open/file.OdT",
      "rich/notes.rTf",
      "lib/example.rb"
    ]

    result = collect(
      paths.each_with_index.map do |path, index|
        tool_use_part(name: "Read", call_id: "call-#{index + 1}", input: %({"path":"#{path}"}))
      end
    )

    expected_document_labels = paths[0...-1]

    assert_equal paths, result.files.map(&:label)
    assert_equal expected_document_labels, result.documents.map(&:label)
    assert(result.documents.all? { |item| item.kind == :file })
    assert_equal(
      result.files.select { |item| expected_document_labels.include?(item.label) }.map(&:object_id),
      result.documents.map(&:object_id)
    )
    refute_includes result.documents.map(&:label), "lib/example.rb"
  end

  def test_call_rejects_url_like_values_in_raw_text_and_keyed_json
    result = collect(
      [
        tool_use_part(
          name: "shell",
          call_id: "call-1",
          input: "visit https://example.com:3000/a/b?redirect=/tmp/report.txt#docs/guide.md " \
                 "then open /tmp/actual.log and mirror example.com/a/b"
        ),
        tool_use_part(
          name: "Read",
          call_id: "call-2",
          input: %({"path":["https://example.com:3000/a/b?redirect=/tmp/report.txt#docs/guide.md","example.com/a/b","/tmp/real.txt"]})
        )
      ]
    )

    assert_equal([["/tmp/actual.log", :referenced], ["/tmp/real.txt", :read]], result.files.map do |item|
      [item.label, item.attributes.fetch(:action)]
    end)
    assert_equal([["/tmp/real.txt", :read]], result.documents.map do |item|
      [item.label, item.attributes.fetch(:action)]
    end)
    assert_same result.files.last, result.documents.first
  end

  def test_call_rejects_single_segment_schemeless_domain_urls
    result = collect(
      [
        tool_use_part(
          name: "shell",
          call_id: "call-1",
          input: "mirror example.com/a and www.example.com/a but keep /tmp/actual.log"
        ),
        tool_use_part(
          name: "Read",
          call_id: "call-2",
          input: %({"path":["example.com/a","www.example.com/a"]})
        )
      ]
    )

    assert_equal([["/tmp/actual.log", :referenced]], result.files.map do |item|
      [item.label, item.attributes.fetch(:action)]
    end)
    assert_equal [], result.documents
  end

  def test_call_keeps_domain_like_suffixes_when_they_are_real_paths
    result = collect(
      [
        tool_use_part(
          name: "shell",
          call_id: "call-1",
          input: "inspect /tmp/example.com/a ./cache/example.com/a/b docs/example.com/a and curl example.com/a"
        ),
        tool_use_part(
          name: "Read",
          call_id: "call-2",
          input: %({"path":["/tmp/example.com/a","example.com/a"]})
        )
      ]
    )

    assert_equal([
                   ["/tmp/example.com/a", :referenced],
                   ["./cache/example.com/a/b", :referenced],
                   ["docs/example.com/a", :referenced],
                   ["/tmp/example.com/a", :read]
                 ], result.files.map { |item| [item.label, item.attributes.fetch(:action)] })
    assert_equal [], result.documents
  end

  def test_call_ignores_empty_and_nul_keyed_path_values_without_raising
    result = collect(
      [
        tool_use_part(name: "Read", call_id: "call-1", input: %({"path":["","docs\\u0000bad.md","README.md"]}))
      ]
    )

    assert_equal([["README.md", :read]], result.files.map { |item| [item.label, item.attributes.fetch(:action)] })
    assert_equal([["README.md", :read]], result.documents.map { |item| [item.label, item.attributes.fetch(:action)] })
  end

  private

  def collect(parts, role: :assistant)
    transcript = Agent::SessionContext::Transcript.new(
      session: build_session(agent: :codex),
      captured_at: Time.utc(2026, 8, 27, 12, 5, 0),
      entries: [
        Agent::SessionContext::TranscriptEntry.new(
          index: 1,
          role: role,
          at: Time.utc(2026, 8, 27, 12, 0, 0),
          parts: parts
        )
      ],
      warnings: []
    )

    Agent::SessionContext::EvidenceCollector.new.call(transcript)
  end

  def tool_use_part(name:, call_id:, input:)
    part_index = next_part_index

    Agent::SessionContext::TranscriptPart.new(
      index: part_index,
      type: :tool_use,
      text: input,
      name: name,
      call_id: call_id,
      injected: false,
      source_ref: source_ref_for(part_index)
    )
  end

  def plain_part(type:, text:, injected: false)
    part_index = next_part_index

    Agent::SessionContext::TranscriptPart.new(
      index: part_index,
      type: type,
      text: text,
      name: nil,
      call_id: nil,
      injected: injected,
      source_ref: source_ref_for(part_index)
    )
  end

  def next_part_index
    @next_part_index = @next_part_index.to_i + 1
  end

  def source_ref_for(part_index)
    Agent::SessionContext::SourceRef.new(
      session_uid: "codex:session-123",
      message_index: 1,
      part_index: part_index
    )
  end

  def build_session(agent:, id: "session-123")
    Agent::Sessions::Session.new(
      agent: agent,
      id: id,
      path: "/tmp/#{id}.jsonl",
      started_at: Time.utc(2026, 8, 27, 11, 0, 0),
      updated_at: Time.utc(2026, 8, 27, 12, 0, 0),
      bytes: 128,
      format: :jsonl,
      fidelity: :full,
      project_path: "/tmp/project"
    )
  end
end
