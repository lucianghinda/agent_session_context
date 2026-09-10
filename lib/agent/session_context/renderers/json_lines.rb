# frozen_string_literal: true

module Agent
  module SessionContext
    module Renderers
      class JSONLines
        def call(value)
          # Same privacy rule as Renderers::JSON: never hand the Loop itself
          # (or its round trips, which carry Message#raw) to Serializer. One
          # line per round trip, from the already-stripped LoopView Hash.
          return loop_lines(value) if value.is_a?(Loop)

          Array(value).map { |prompt| ::JSON.generate(Serializer.serialize(prompt)) }.join("\n")
        end

        private

        def loop_lines(loop_model)
          round_trips = LoopView.new(loop_model).to_h.fetch(:round_trips)
          round_trips.map { |round_trip| ::JSON.generate(Serializer.serialize(round_trip)) }.join("\n")
        end
      end
    end
  end
end
