# frozen_string_literal: true

class FakeCatalog
  Session = Data.define(:agent, :id, :uid, :updated_at)

  attr_reader :calls

  def initialize
    @builders = {}
    @calls = Hash.new(0)
  end

  def add(agent, *sessions, &block)
    @builders[agent.to_sym] = block || proc { sessions }
    self
  end

  def build_session(agent, id:, uid: nil, updated_at: Time.utc(2026, 1, 1))
    agent = agent.to_sym
    Session.new(agent:, id: id.to_s, uid: uid || "#{agent}:#{id}", updated_at:)
  end

  def sessions(agent, env:)
    agent = agent.to_sym
    builder = @builders.fetch(agent) { proc { [] } }

    Enumerator.new do |yielder|
      @calls[agent] += 1
      builder.call(env).each do |session|
        yielder << session
      end
    end.lazy
  end
end
