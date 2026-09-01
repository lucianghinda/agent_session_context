# frozen_string_literal: true

module Agent
  module SessionContext
    module Renderers
      class Text
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

        def render_snapshot_prompts(prompts)
          ["User prompts", render_prompts(prompts)].join("\n\n")
        end

        def render_injected_context(contexts)
          entries = contexts.map do |context|
            lines = [
              "Injected #{HumanDisplay.text_inline(context.kind)}",
              "- Bytes: #{context.bytes}",
              "- Occurrences: #{context.occurrences}",
              "- Refs: #{HumanDisplay.refs(context.source_refs)}"
            ]
            if context.text
              lines << "- Text:"
              lines << HumanDisplay.text_block(context.text)
            end
            lines.join("\n")
          end

          ["Injected context", entries.join("\n\n")].join("\n\n")
        end

        def render_prompts(prompts)
          prompts.map do |prompt|
            lines = ["Prompt #{prompt.index}"]
            prompt_at = HumanDisplay.timestamp(prompt.at)
            lines << "- At: #{HumanDisplay.text_inline(prompt_at)}" if prompt_at
            lines << "- Refs: #{HumanDisplay.refs(prompt.source_refs)}"
            lines << HumanDisplay.text_block(prompt.text)
            lines.join("\n")
          end.join("\n\n")
        end

        def render_session(snapshot)
          lines = [
            "Session",
            "- UID: #{HumanDisplay.text_inline(snapshot.session_uid)}",
            "- Agent: #{HumanDisplay.text_inline(snapshot.agent)}"
          ]
          lines << "- Project path: #{HumanDisplay.text_inline(snapshot.project_path)}" if snapshot.project_path
          captured_at = HumanDisplay.timestamp(snapshot.captured_at)
          lines << "- Captured at: #{HumanDisplay.text_inline(captured_at)}" if captured_at
          lines << "- Message count: #{snapshot.message_count}"
          lines << "- Summary metadata: #{attributes(snapshot.summary_metadata)}" if snapshot.summary_metadata.any?
          lines.join("\n")
        end

        def render_section(title, items)
          return if items.empty?

          if title == "Warnings"
            return ([title] + items.map { |warning| "- #{HumanDisplay.text_inline(warning)}" }).join("\n")
          end

          ([title] + items.map { |item| "- #{item_line(item)}" }).join("\n")
        end

        def item_line(item)
          fragments = [base_item_text(item)]
          attrs = attributes(item.attributes)
          fragments << "(#{attrs})" unless attrs.empty?
          fragments << "[#{item.evidence}]"
          fragments << "refs #{HumanDisplay.refs(item.source_refs)}"
          fragments.join(" ")
        end

        def base_item_text(item)
          return "#{HumanDisplay.text_inline(item.label)}: #{HumanDisplay.text_inline(item.detail)}" if item.detail

          HumanDisplay.text_inline(item.label)
        end

        def attributes(hash)
          HumanDisplay.attributes(hash, inline_formatter: HumanDisplay.method(:text_inline))
        end
      end
    end
  end
end
