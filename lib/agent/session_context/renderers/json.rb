# frozen_string_literal: true

module Agent
  module SessionContext
    module Renderers
      class JSON
        def call(value)
          ::JSON.generate(Serializer.serialize(value))
        end
      end
    end
  end
end
