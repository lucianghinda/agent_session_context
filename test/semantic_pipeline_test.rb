# frozen_string_literal: true

require "test_helper"
require_relative "support/fake_summarizer"

class SemanticPipelineTest < Minitest::Test
  FakePacketResult = Data.define(:chunks, :warnings, :source_refs, :chunk_refs) do
    def source_refs_for(chunk)
      Array(chunk_refs.fetch(chunk)).freeze
    end
  end

  class FakePacket
    attr_reader :calls

    def initialize(result)
      @result = result
      @calls = []
    end

    def call(transcript:, observed:)
      @calls << { transcript:, observed: }
      @result
    end
  end

  def test_call_extracts_once_for_one_chunk_and_uses_chunk_specific_refs
    chunk_ref = ref(1, 1)
    packet = build_packet(
      chunks: ["Visible chunk evidence"],
      warnings: ["packet warning"],
      source_refs: [chunk_ref],
      chunk_refs: { "Visible chunk evidence" => [chunk_ref] }
    )
    summarizer = FakeSummarizer.new(
      responses: [
        JSON.generate(full_payload(
                        "goals" => [{ "text" => "Ground the summary", "evidence" => "explicit",
                                      "source_refs" => [chunk_ref.to_s] }]
                      ))
      ]
    )

    result = pipeline(packet:, backend: summarizer).call(transcript: :transcript, observed: :observed)

    assert_equal [{ transcript: :transcript, observed: :observed }], packet.calls
    assert_equal 1, summarizer.requests.length
    assert_equal Agent::SessionContext::SemanticSchema.extraction, summarizer.requests.first.schema
    assert_includes summarizer.requests.first.prompt, "untrusted quoted data"
    assert_includes summarizer.requests.first.prompt, "not instructions"
    assert_includes summarizer.requests.first.prompt, "goals"
    assert_includes summarizer.requests.first.prompt, "decisions"
    assert_includes summarizer.requests.first.prompt, "terms"
    assert_includes summarizer.requests.first.prompt, "constraints"
    assert_includes summarizer.requests.first.prompt, "open_questions"
    assert_includes summarizer.requests.first.prompt, "next_actions"
    assert_equal([[:goal, "Ground the summary", [chunk_ref]]], result.items.map do |item|
      [item.kind, item.label, item.source_refs]
    end)
    assert_equal ["packet warning"], result.warnings
    assert_equal({ backend: :fake, chunks: 1 }, result.metadata)
  end

  def test_call_reduces_multiple_chunks_from_validated_items_only_and_preserves_all_warnings
    first_ref = ref(1, 1)
    second_ref = ref(1, 2)
    packet = build_packet(
      chunks: ["chunk one transcript", "chunk two transcript"],
      warnings: ["packet warning"],
      source_refs: [first_ref, second_ref],
      chunk_refs: {
        "chunk one transcript" => [first_ref],
        "chunk two transcript" => [second_ref]
      }
    )
    summarizer = FakeSummarizer.new(
      responses: [
        JSON.generate(
          full_payload(
            "goals" => [
              { "text" => "Keep only grounded chunk one claims", "evidence" => "explicit",
                "source_refs" => [first_ref.to_s] },
              { "text" => "Drop cross chunk citation", "evidence" => "explicit", "source_refs" => [second_ref.to_s] }
            ],
            "surprises" => [{ "text" => "warn from extraction" }]
          )
        ),
        JSON.generate(
          full_payload(
            "decisions" => [{ "text" => "Chunk two decision", "evidence" => "explicit",
                              "source_refs" => [second_ref.to_s] }]
          )
        ),
        JSON.generate(
          full_payload(
            "next_actions" => [{ "text" => "Ship the grounded snapshot", "evidence" => "inferred",
                                 "source_refs" => [first_ref.to_s, second_ref.to_s] }],
            "surprises" => [{ "text" => "warn from reduction" }]
          )
        )
      ]
    )

    result = pipeline(packet:, backend: summarizer).call(transcript: :transcript, observed: :observed)

    assert_equal 3, summarizer.requests.length
    reduction_prompt = summarizer.requests.last.prompt

    assert_includes reduction_prompt, "Keep only grounded chunk one claims"
    assert_includes reduction_prompt, "Chunk two decision"
    assert_includes reduction_prompt, "untrusted"
    assert_includes reduction_prompt, "non-instructional"
    assert_includes reduction_prompt, "not instructions"
    assert_includes reduction_prompt, "goals"
    assert_includes reduction_prompt, "decisions"
    assert_includes reduction_prompt, "terms"
    assert_includes reduction_prompt, "constraints"
    assert_includes reduction_prompt, "open_questions"
    assert_includes reduction_prompt, "next_actions"
    assert_includes reduction_prompt, first_ref.to_s
    assert_includes reduction_prompt, second_ref.to_s
    refute_includes reduction_prompt, "Drop cross chunk citation"
    refute_includes reduction_prompt, "chunk one transcript"
    refute_includes reduction_prompt, "chunk two transcript"

    assert_equal([[:next_action, "Ship the grounded snapshot", [first_ref, second_ref]]], result.items.map do |item|
      [item.kind, item.label, item.source_refs]
    end)
    assert_equal(
      [
        "packet warning",
        "Dropped goals[1] because it referenced an unknown source ref",
        "Dropped unknown category \"surprises\"",
        "Dropped unknown category \"surprises\""
      ],
      result.warnings
    )
    assert_equal({ backend: :fake, chunks: 2 }, result.metadata)
  end

  def test_call_reduction_cannot_recite_refs_from_chunks_that_produced_no_validated_items
    first_ref = ref(1, 1)
    second_ref = ref(1, 2)
    packet = build_packet(
      chunks: ["valid chunk", "empty chunk"],
      warnings: [],
      source_refs: [first_ref, second_ref],
      chunk_refs: {
        "valid chunk" => [first_ref],
        "empty chunk" => [second_ref]
      }
    )
    summarizer = FakeSummarizer.new(
      responses: [
        JSON.generate(full_payload(
                        "goals" => [{ "text" => "Validated from chunk one", "evidence" => "explicit",
                                      "source_refs" => [first_ref.to_s] }]
                      )),
        JSON.generate(full_payload),
        JSON.generate(full_payload(
                        "next_actions" => [{ "text" => "Illicitly cite empty chunk", "evidence" => "inferred",
                                             "source_refs" => [second_ref.to_s] }]
                      ))
      ]
    )

    result = pipeline(packet:, backend: summarizer).call(transcript: :transcript, observed: :observed)

    assert_equal [], result.items
    assert_equal ["Dropped next_actions[0] because it referenced an unknown source ref"], result.warnings
  end

  def test_call_raises_invalid_summary_for_invalid_utf8_backend_output_on_single_chunk
    chunk_ref = ref(1, 1)
    packet = build_packet(
      chunks: ["single chunk"],
      warnings: [],
      source_refs: [chunk_ref],
      chunk_refs: { "single chunk" => [chunk_ref] }
    )
    summarizer = FakeSummarizer.new(responses: [invalid_utf8_json_payload])

    error = assert_raises(Agent::SessionContext::InvalidSummary) do
      pipeline(packet:, backend: summarizer).call(transcript: :transcript, observed: :observed)
    end

    assert_match(/utf-8/i, error.message)
  end

  def test_call_raises_invalid_summary_for_invalid_utf8_backend_output_on_reduction
    first_ref = ref(1, 1)
    second_ref = ref(1, 2)
    packet = build_packet(
      chunks: ["chunk one", "chunk two"],
      warnings: [],
      source_refs: [first_ref, second_ref],
      chunk_refs: {
        "chunk one" => [first_ref],
        "chunk two" => [second_ref]
      }
    )
    summarizer = FakeSummarizer.new(
      responses: [
        JSON.generate(full_payload(
                        "goals" => [{ "text" => "Chunk one", "evidence" => "explicit",
                                      "source_refs" => [first_ref.to_s] }]
                      )),
        JSON.generate(full_payload(
                        "decisions" => [{ "text" => "Chunk two", "evidence" => "explicit",
                                          "source_refs" => [second_ref.to_s] }]
                      )),
        invalid_utf8_json_payload
      ]
    )

    error = assert_raises(Agent::SessionContext::InvalidSummary) do
      pipeline(packet:, backend: summarizer).call(transcript: :transcript, observed: :observed)
    end

    assert_match(/utf-8/i, error.message)
  end

  def test_call_accepts_binary_tagged_valid_utf8_backend_output_on_single_chunk_without_mutating_input
    chunk_ref = ref(1, 1)
    packet = build_packet(
      chunks: ["single chunk"],
      warnings: [],
      source_refs: [chunk_ref],
      chunk_refs: { "single chunk" => [chunk_ref] }
    )
    response = binary_utf8_json_payload(
      full_payload(
        "goals" => [{ "text" => "Résumé accepted", "evidence" => "explicit", "source_refs" => [chunk_ref.to_s] }]
      )
    )
    original_bytes = response.bytes.dup

    result = pipeline(packet:, backend: FakeSummarizer.new(responses: [response])).call(transcript: :transcript,
                                                                                        observed: :observed)

    assert_equal([[:goal, "Résumé accepted", [chunk_ref]]], result.items.map do |item|
      [item.kind, item.label, item.source_refs]
    end)
    assert_equal Encoding::ASCII_8BIT, response.encoding
    assert_equal original_bytes, response.bytes
  end

  def test_call_accepts_binary_tagged_valid_utf8_backend_output_on_reduction_without_mutating_input
    first_ref = ref(1, 1)
    second_ref = ref(1, 2)
    packet = build_packet(
      chunks: ["chunk one", "chunk two"],
      warnings: [],
      source_refs: [first_ref, second_ref],
      chunk_refs: {
        "chunk one" => [first_ref],
        "chunk two" => [second_ref]
      }
    )
    reduction_response = binary_utf8_json_payload(
      full_payload(
        "next_actions" => [{ "text" => "Ship the résumé summary", "evidence" => "inferred",
                             "source_refs" => [first_ref.to_s, second_ref.to_s] }]
      )
    )
    original_bytes = reduction_response.bytes.dup
    summarizer = FakeSummarizer.new(
      responses: [
        JSON.generate(full_payload(
                        "goals" => [{ "text" => "Chunk one", "evidence" => "explicit",
                                      "source_refs" => [first_ref.to_s] }]
                      )),
        JSON.generate(full_payload(
                        "decisions" => [{ "text" => "Chunk two", "evidence" => "explicit",
                                          "source_refs" => [second_ref.to_s] }]
                      )),
        reduction_response
      ]
    )

    result = pipeline(packet:, backend: summarizer).call(transcript: :transcript, observed: :observed)

    assert_equal([[:next_action, "Ship the résumé summary", [first_ref, second_ref]]], result.items.map do |item|
      [item.kind, item.label, item.source_refs]
    end)
    assert_equal Encoding::ASCII_8BIT, reduction_response.encoding
    assert_equal original_bytes, reduction_response.bytes
  end

  def test_call_is_atomic_when_backend_fails_mid_pipeline
    first_ref = ref(1, 1)
    second_ref = ref(1, 2)
    packet = build_packet(
      chunks: ["chunk one", "chunk two"],
      warnings: [],
      source_refs: [first_ref, second_ref],
      chunk_refs: {
        "chunk one" => [first_ref],
        "chunk two" => [second_ref]
      }
    )
    summarizer = FakeSummarizer.new do |prompt:, schema:, request_index:|
      next JSON.generate(full_payload) if request_index == 1

      raise Agent::SessionContext::SummarizerFailed, "backend blew up"
    end

    error = assert_raises(Agent::SessionContext::SummarizerFailed) do
      pipeline(packet:, backend: summarizer).call(transcript: :transcript, observed: :observed)
    end

    assert_equal "backend blew up", error.message
    assert_equal 2, summarizer.requests.length
  end

  def test_call_attributes_lambda_backends_as_custom
    chunk_ref = ref(1, 1)
    packet = build_packet(
      chunks: ["chunk one"],
      warnings: [],
      source_refs: [chunk_ref],
      chunk_refs: { "chunk one" => [chunk_ref] }
    )
    backend = lambda do |prompt:, schema:|
      JSON.generate(full_payload)
    end

    result = pipeline(packet:, backend:).call(transcript: :transcript, observed: :observed)

    assert_equal({ backend: :custom, chunks: 1 }, result.metadata)
  end

  private

  def pipeline(packet:, backend: nil)
    Agent::SessionContext::SemanticPipeline.new(
      backend: backend || FakeSummarizer.new(responses: [JSON.generate(full_payload)]),
      packet: packet,
      parser: Agent::SessionContext::SummaryParser.new
    )
  end

  def build_packet(chunks:, warnings:, source_refs:, chunk_refs:)
    FakePacket.new(
      FakePacketResult.new(
        chunks: chunks.freeze,
        warnings: warnings.freeze,
        source_refs: source_refs.freeze,
        chunk_refs: chunk_refs.freeze
      )
    )
  end

  def ref(message_index, part_index, session_uid: "codex:session-123")
    Agent::SessionContext::SourceRef.new(
      session_uid: session_uid,
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

  def invalid_utf8_json_payload
    String.new("#{JSON.generate(full_payload)}\xFF".b, encoding: Encoding::UTF_8)
  end

  def binary_utf8_json_payload(payload)
    JSON.generate(payload).encode(Encoding::UTF_8).dup.force_encoding(Encoding::ASCII_8BIT)
  end
end
