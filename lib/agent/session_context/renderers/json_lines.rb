# frozen_string_literal: true

module Agent
  module SessionContext
    module Renderers
      class JSONLines
        def call(prompts)
          Array(prompts).map { |prompt| ::JSON.generate(Serializer.serialize(prompt)) }.join("\n")
        end
      end
    end
  end
end
