# frozen_string_literal: true

module Agent
  module SessionContext
    class PromptExtractor
      def call(transcript)
        prompt_index = 0

        prompts = transcript.entries.each_with_object([]) do |entry, collected|
          next unless entry.role == :user

          contributing_parts = entry.parts.select { |part| part.type == :text && !part.injected }
          next if contributing_parts.empty?

          text = contributing_parts.map(&:text).join
          next if text.empty?

          prompt_index += 1
          collected << Prompt.new(
            index: prompt_index,
            at: entry.at,
            text: text,
            source_refs: contributing_parts.map(&:source_ref)
          )
        end

        prompts.freeze
      end
    end
  end
end
