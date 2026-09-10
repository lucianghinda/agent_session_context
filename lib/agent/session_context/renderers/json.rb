# frozen_string_literal: true

module Agent
  module SessionContext
    module Renderers
      class JSON
        def call(value)
          # A Loop must never reach Serializer.serialize directly: Serializer
          # walks any Data object generically by its members, and Loop holds
          # round_trips -> Message#raw, the full on-disk record with every
          # prompt and tool-result body. LoopView#to_h is the Hash that
          # already strips bodies down to sizes and tool names — serialize
          # THAT, never the Loop itself.
          return ::JSON.generate(Serializer.serialize(LoopView.new(value).to_h)) if value.is_a?(Loop)

          ::JSON.generate(Serializer.serialize(value))
        end
      end
    end
  end
end
