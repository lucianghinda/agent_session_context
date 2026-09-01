# frozen_string_literal: true

module Agent
  module SessionContext
    module Renderers
      class Markdown
        SECTION_ORDER = [
          ["Goal", :goals],
          ["Files", :files],
          ["Documents", :documents],
          ["Tool activity", :tool_activity],
          ["Decisions", :decisions],
          ["Terminology", :terms],
          ["Constraints", :constraints],
          ["Open questions", :open_questions],
          ["Next actions", :next_actions],
          ["Warnings", :warnings]
        ].freeze
        private_constant :SECTION_ORDER

        def call(value)
          if value.is_a?(Snapshot)
            render_snapshot(value)
          else
            render_prompts(Array(value))
          end
        end

        private

        def render_snapshot(snapshot)
          sections = [render_session(snapshot)]
          sections << render_snapshot_prompts(snapshot.prompts) if snapshot.prompts.any?
          sections << render_injected_context(snapshot.injected_context) if snapshot.injected_context.any?

          SECTION_ORDER.each do |title, field|
            section = render_section(title, snapshot.public_send(field))
            sections << section if section
          end

          sections.join("\n\n")
        end

        def render_prompts(prompts, heading_level: 2)
          heading = "#" * heading_level
          prompts.map do |prompt|
            lines = ["#{heading} Prompt #{prompt.index}"]
            prompt_at = HumanDisplay.timestamp(prompt.at)
            lines << "- At: #{HumanDisplay.markdown_literal(prompt_at)}" if prompt_at
            lines << "- Refs: #{HumanDisplay.markdown_literal(HumanDisplay.refs(prompt.source_refs))}"
            lines << ""
            lines << HumanDisplay.markdown_block(prompt.text)
            lines.join("\n")
          end.join("\n\n")
        end

        def render_snapshot_prompts(prompts)
          ["## User prompts", render_prompts(prompts, heading_level: 3)].join("\n\n")
        end

        def render_injected_context(contexts)
          entries = contexts.map do |context|
            lines = [
              "### Injected #{HumanDisplay.markdown_literal(context.kind)}",
              "- Bytes: #{HumanDisplay.markdown_literal(context.bytes)}",
              "- Occurrences: #{HumanDisplay.markdown_literal(context.occurrences)}",
              "- Refs: #{HumanDisplay.markdown_literal(HumanDisplay.refs(context.source_refs))}"
            ]
            if context.text
              lines << ""
              lines << HumanDisplay.markdown_block(context.text)
            end
            lines.join("\n")
          end

          ["## Injected context", entries.join("\n\n")].join("\n\n")
        end

        def render_session(snapshot)
          lines = [
            "## Session",
            "- UID: #{HumanDisplay.markdown_literal(snapshot.session_uid)}",
            "- Agent: #{HumanDisplay.markdown_literal(snapshot.agent)}"
          ]
          lines << "- Project path: #{HumanDisplay.markdown_literal(snapshot.project_path)}" if snapshot.project_path
          captured_at = HumanDisplay.timestamp(snapshot.captured_at)
          lines << "- Captured at: #{HumanDisplay.markdown_literal(captured_at)}" if captured_at
          lines << "- Message count: #{HumanDisplay.markdown_literal(snapshot.message_count)}"
          if snapshot.summary_metadata.any?
            lines << "- Summary metadata: #{HumanDisplay.markdown_literal(attributes(snapshot.summary_metadata))}"
          end
          lines.join("\n")
        end

        def render_section(title, items)
          return if items.empty?

          if title == "Warnings"
            return (["## #{title}"] + items.map { |warning| "- #{HumanDisplay.markdown_text(warning)}" }).join("\n")
          end

          (["## #{title}"] + items.map { |item| "- #{item_line(item)}" }).join("\n")
        end

        def item_line(item)
          fragments = [base_item_text(item)]
          attrs = attributes(item.attributes)
          fragments << "(#{HumanDisplay.markdown_literal(attrs)})" unless attrs.empty?
          fragments << HumanDisplay.markdown_literal("[#{item.evidence}]")
          fragments << "refs #{HumanDisplay.markdown_literal(HumanDisplay.refs(item.source_refs))}"
          fragments.join(" ")
        end

        def base_item_text(item)
          return "#{HumanDisplay.markdown_text(item.label)}: #{HumanDisplay.markdown_text(item.detail)}" if item.detail

          HumanDisplay.markdown_text(item.label)
        end

        def attributes(hash)
          HumanDisplay.attributes(hash, inline_formatter: HumanDisplay.method(:text_inline))
        end
      end
    end
  end
end
