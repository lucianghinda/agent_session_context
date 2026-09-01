# frozen_string_literal: true

module Agent
  module SessionContext
    class Builder
      PromptsResult = Data.define(:prompts, :reader_warnings) do
        def partial_capture?
          !reader_warnings.empty?
        end
      end

      def initialize(
        catalog: Agent::Sessions,
        now: Time.now,
        collector: EvidenceCollector.new,
        prompt_extractor: PromptExtractor.new,
        injected_context_collector: InjectedContextCollector.new
      )
        @catalog = catalog
        @now = now
        @collector = collector
        @prompt_extractor = prompt_extractor
        @injected_context_collector = injected_context_collector
      end

      def show(session, include_injected: false)
        validate_include_injected!(include_injected)
        transcript = capture(session)
        observed = @collector.call(transcript)

        build_snapshot(
          session:,
          transcript:,
          observed:,
          prompts: @prompt_extractor.call(transcript),
          injected_context: @injected_context_collector.call(transcript, include_text: include_injected),
          warnings: transcript.warnings,
          summary_metadata: base_metadata(transcript)
        )
      end

      def prompts(session)
        prompts_result(session).prompts
      end

      def prompts_result(session)
        transcript = capture(session)
        PromptsResult.new(
          prompts: @prompt_extractor.call(transcript),
          reader_warnings: transcript.warnings
        )
      end

      def summarize(session, summarizer:)
        transcript = capture(session)
        observed = @collector.call(transcript)
        semantic = SemanticPipeline.new(backend: summarizer).call(transcript:, observed:)
        semantic_collections, unknown_warnings = collect_semantic_items(semantic.items)

        build_snapshot(
          session: session,
          transcript: transcript,
          observed: observed,
          semantic_collections: semantic_collections,
          warnings: transcript.warnings + semantic.warnings + unknown_warnings,
          summary_metadata: semantic.metadata.merge(base_metadata(transcript))
        )
      end

      private

      def validate_include_injected!(value)
        return if value.equal?(true) || value.equal?(false)

        raise ArgumentError, "include_injected must be true or false"
      end

      def capture(session)
        Transcript.capture(session, reader: @catalog.read(session), now: @now)
      end

      def collect_semantic_items(items)
        collections = empty_semantic_collections
        warnings = []

        items.each do |item|
          field = SemanticCategories.lookup(item.kind)&.snapshot_field
          unless field
            warnings << "Dropped unknown semantic kind #{item.kind.inspect}"
            next
          end

          collections[field] << item
        end

        [collections.transform_values(&:freeze).freeze, warnings.freeze]
      end

      def empty_semantic_collections
        SemanticCategories.snapshot_fields.to_h do |field|
          [field, []]
        end
      end

      def build_snapshot(
        session:,
        transcript:,
        observed:,
        warnings:,
        summary_metadata:,
        prompts: [],
        injected_context: [],
        semantic_collections: empty_semantic_collections.transform_values(&:freeze).freeze
      )
        Snapshot.new(
          session_uid: session.uid,
          agent: session.agent,
          project_path: session.project_path,
          captured_at: transcript.captured_at,
          message_count: transcript.entries.length,
          prompts:,
          injected_context:,
          files: observed.files,
          documents: observed.documents,
          tool_activity: observed.tool_activity,
          **semantic_snapshot_attributes(semantic_collections),
          warnings: warnings,
          summary_metadata: summary_metadata
        )
      end

      def semantic_snapshot_attributes(semantic_collections)
        SemanticCategories.snapshot_fields.to_h do |field|
          [field, semantic_collections.fetch(field)]
        end
      end

      def base_metadata(transcript)
        metadata = { injected_parts_filtered: transcript.entries.sum { |entry| entry.parts.count(&:injected) } }
        reader_warning_count = transcript.warnings.length
        metadata[:reader_warning_count] = reader_warning_count if reader_warning_count.positive?
        metadata
      end
    end
  end
end
