# frozen_string_literal: true

class FakeSummarizer
  Request = Data.define(:prompt, :schema)

  attr_reader :requests, :name

  def initialize(name: :fake, responses: nil, &block)
    @name = name
    @responses = Array(responses).dup
    @block = block
    @requests = []
  end

  def call(prompt:, schema:)
    @requests << Request.new(prompt:, schema:)

    return @block.call(prompt:, schema:, request_index: @requests.length) if @block

    raise "No fake summarizer response configured for request #{@requests.length}" if @responses.empty?

    @responses.shift
  end
end
