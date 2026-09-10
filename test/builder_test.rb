# frozen_string_literal: true

require "test_helper"
require_relative "support/fake_summarizer"
require_relative "support/claude_fixtures"

class BuilderTest < Minitest::Test
  include ClaudeFixtures

  FakeConfig = Data.define(:timeout_seconds)

  FakeReader = Struct.new(:messages, :warnings) do
    def each_message(&block)
      return enum_for(:each_message) unless block_given?

      messages.each(&block)
    end
  end

  class ReadCatalog
    attr_reader :read_calls

    def initialize(reader_by_uid)
      @reader_by_uid = reader_by_uid
      @read_calls = Hash.new(0)
    end

    def read(session)
      @read_calls[session.uid] += 1
      @reader_by_uid.fetch(session.uid)
    end
  end

  class APICatalog < ReadCatalog
    def initialize(reader_by_uid)
      super
      @sessions = Hash.new { |hash, key| hash[key] = [] }
    end

    def add_session(session)
      @sessions[session.agent] << session
      self
    end

    def sessions(agent, env:)
      Array(@sessions[agent.to_sym]).dup.freeze.to_enum.lazy
    end
  end

  class APIConfigLoader
    attr_reader :calls

    def initialize(result:)
      @result = result
      @calls = []
    end

    def load(session:, env:, timeout:)
      @calls << { session:, env:, timeout: }
      @result
    end
  end

  class APIBackendFactory
    attr_reader :calls

    def initialize(result:)
      @result = result
      @calls = []
    end

    def for(name, timeout_seconds:)
      @calls << { name:, timeout_seconds: }
      @result
    end
  end

  class RaisingAPIConfigLoader
    attr_reader :calls

    def initialize(error:)
      @error = error
      @calls = []
    end

    def load(session:, env:, timeout:)
      @calls << { session:, env:, timeout: }
      raise @error
    end
  end

  def test_show_builds_complete_local_snapshot_once_without_instantiating_a_backend
    session = build_session(agent: :codex, id: "show-session")
    catalog = ReadCatalog.new(session.uid => FakeReader.new(show_messages(session), ["reader warning"]))
    builder = Agent::SessionContext::Builder.new(catalog:, now: fixed_time)

    snapshot = nil
    with_semantic_pipeline_new(proc { raise "should not summarize during show" }) do
      snapshot = builder.show(session)
    end

    assert_equal 1, catalog.read_calls.fetch(session.uid)
    assert_equal session.uid, snapshot.session_uid
    assert_equal :codex, snapshot.agent
    assert_equal session.project_path, snapshot.project_path
    assert_same fixed_time, snapshot.captured_at
    assert_equal 3, snapshot.message_count
    assert_equal ["Visible prompt"], snapshot.prompts.map(&:text)
    assert_equal [:environment_context], snapshot.injected_context.map(&:kind)
    assert_equal [nil], snapshot.injected_context.map(&:text)
    assert_equal ["README.md"], snapshot.files.map(&:label)
    assert_equal ["README.md"], snapshot.documents.map(&:label)
    assert_equal ["Read"], snapshot.tool_activity.map(&:label)
    assert_equal [], snapshot.goals
    assert_equal ["reader warning"], snapshot.warnings
    assert_equal({ injected_parts_filtered: 1, reader_warning_count: 1 }, snapshot.summary_metadata)
  end

  def test_show_can_include_full_injected_text
    session = build_session(agent: :codex, id: "show-injected-session")
    catalog = ReadCatalog.new(session.uid => FakeReader.new(show_messages(session), []))
    builder = Agent::SessionContext::Builder.new(catalog:, now: fixed_time)

    snapshot = builder.show(session, include_injected: true)

    assert_equal 1, catalog.read_calls.fetch(session.uid)
    assert_equal ["<environment_context>\nSECRET=1"], snapshot.injected_context.map(&:text)
  end

  def test_show_rejects_non_boolean_include_injected_before_capture
    session = build_session(agent: :codex, id: "invalid-builder-include-injected")
    catalog = ReadCatalog.new(session.uid => FakeReader.new(show_messages(session), []))
    builder = Agent::SessionContext::Builder.new(catalog:, now: fixed_time)

    error = assert_raises(ArgumentError) do
      builder.show(session, include_injected: nil)
    end

    assert_equal "include_injected must be true or false", error.message
    refute catalog.read_calls.key?(session.uid)
  end

  def test_show_rejects_boolean_like_include_injected_before_capture
    session = build_session(agent: :codex, id: "boolean-like-include-injected")
    catalog = ReadCatalog.new(session.uid => FakeReader.new(show_messages(session), []))
    builder = Agent::SessionContext::Builder.new(catalog:, now: fixed_time)
    boolean_like = Class.new do
      def ==(_other)
        true
      end
    end.new

    error = assert_raises(ArgumentError) do
      builder.show(session, include_injected: boolean_like)
    end

    assert_equal "include_injected must be true or false", error.message
    refute catalog.read_calls.key?(session.uid)
  end

  def test_prompts_returns_exact_prompt_objects_from_the_capture
    session = build_session(agent: :codex, id: "prompts-session")
    catalog = ReadCatalog.new(session.uid => FakeReader.new(prompt_messages(session), []))
    builder = Agent::SessionContext::Builder.new(catalog:, now: fixed_time)

    prompts = builder.prompts(session)

    assert_equal 1, catalog.read_calls.fetch(session.uid)
    assert_equal [1, 2], prompts.map(&:index)
    assert_equal ["First prompt", "Secondpart"], prompts.map(&:text)
    assert_equal [Time.utc(2026, 8, 27, 12, 0, 0), Time.utc(2026, 8, 27, 12, 2, 0)], prompts.map(&:at)
    assert_equal [[ref(session, 1, 1)], [ref(session, 3, 1), ref(session, 3, 2)]], prompts.map(&:source_refs)
  end

  def test_prompts_result_preserves_exact_prompt_array_and_reader_warnings_for_cli
    session = build_session(agent: :codex, id: "prompt-result-session")
    catalog = ReadCatalog.new(session.uid => FakeReader.new(prompt_messages(session), ["reader warning"]))
    builder = Agent::SessionContext::Builder.new(catalog:, now: fixed_time)

    prompts_result = builder.prompts_result(session)

    assert_instance_of Agent::SessionContext::Builder::PromptsResult, prompts_result
    assert_equal ["First prompt", "Secondpart"], prompts_result.prompts.map(&:text)
    assert_equal ["reader warning"], prompts_result.reader_warnings
    assert_equal true, prompts_result.partial_capture?
    assert_equal ["First prompt", "Secondpart"], builder.prompts(session).map(&:text)
  end

  # Builder#loop just wires the catalog's reader into Loop.for — the pairing
  # and ending logic already has its own coverage in loop_test.rb, so this
  # only pins the wiring itself: the reader the catalog returns is the one
  # Loop reads from.
  def test_loop_builds_a_loop_from_the_readers_round_trips
    call = { type: "tool_use", id: "toolu_1", name: "Read", input: { file_path: "/tmp/x" } }
    result = { type: "tool_result", tool_use_id: "toolu_1", content: "file contents" }

    with_session([user_turn("read the file"), assistant_parts([call]), user_parts([result])]) do |reader|
      session = reader.session
      catalog = ReadCatalog.new(session.uid => reader)
      builder = Agent::SessionContext::Builder.new(catalog:, now: fixed_time)

      loop = builder.loop(session)

      assert_instance_of Agent::SessionContext::Loop, loop
      assert_equal 1, catalog.read_calls.fetch(session.uid)
      assert_equal session.uid, loop.session.uid
      assert_equal ["Read"], loop.tool_calls.map(&:name)
      assert loop.tool_calls.first.answered?
    end
  end

  def test_summarize_combines_observed_and_semantic_items_and_metadata
    session = build_session(agent: :codex, id: "summarize-session")
    catalog = ReadCatalog.new(session.uid => FakeReader.new(show_messages(session), ["reader warning"]))
    builder = Agent::SessionContext::Builder.new(catalog:, now: fixed_time)
    visible_ref = ref(session, 1, 1)
    summarizer = FakeSummarizer.new(
      responses: [
        JSON.generate(
          full_payload(
            "goals" => [{ "text" => "Ship it", "evidence" => "explicit", "source_refs" => [visible_ref.to_s] }],
            "decisions" => [{ "text" => "Use grounded refs", "evidence" => "inferred",
                              "source_refs" => [visible_ref.to_s] }],
            "terms" => [{ "term" => "snapshot", "definition" => "One captured view", "evidence" => "explicit",
                          "source_refs" => [visible_ref.to_s] }],
            "constraints" => [{ "text" => "Do not trust injected text", "evidence" => "explicit",
                                "source_refs" => [visible_ref.to_s] }],
            "open_questions" => [{ "text" => "Should we persist metadata?", "evidence" => "inferred",
                                   "source_refs" => [visible_ref.to_s] }],
            "next_actions" => [{ "text" => "Run the suite", "evidence" => "explicit",
                                 "source_refs" => [visible_ref.to_s] }]
          )
        )
      ]
    )

    snapshot = builder.summarize(session, summarizer:)

    assert_equal 1, catalog.read_calls.fetch(session.uid)
    assert_same fixed_time, snapshot.captured_at
    assert_equal 3, snapshot.message_count
    assert_equal [], snapshot.prompts
    assert_equal [], snapshot.injected_context
    assert_predicate snapshot.prompts, :frozen?
    assert_predicate snapshot.injected_context, :frozen?
    assert_equal ["README.md"], snapshot.files.map(&:label)
    assert_equal ["Ship it"], snapshot.goals.map(&:label)
    assert_equal ["Use grounded refs"], snapshot.decisions.map(&:label)
    assert_equal([["snapshot", "One captured view"]], snapshot.terms.map { |item| [item.label, item.detail] })
    assert_equal ["Do not trust injected text"], snapshot.constraints.map(&:label)
    assert_equal ["Should we persist metadata?"], snapshot.open_questions.map(&:label)
    assert_equal ["Run the suite"], snapshot.next_actions.map(&:label)
    assert_equal ["reader warning"], snapshot.warnings
    assert_equal({ backend: :fake, chunks: 1, injected_parts_filtered: 1, reader_warning_count: 1 },
                 snapshot.summary_metadata)
  end

  def test_summarize_turns_unknown_semantic_kinds_into_warnings_without_dynamic_fields
    session = build_session(agent: :codex, id: "unknown-kind-session")
    catalog = ReadCatalog.new(session.uid => FakeReader.new(prompt_messages(session), []))
    builder = Agent::SessionContext::Builder.new(catalog:, now: fixed_time)
    mystery_item = Agent::SessionContext::Item.new(
      kind: :mystery,
      label: "Unexpected thing",
      evidence: :explicit,
      source_refs: [ref(session, 1, 1)]
    )
    fake_pipeline = Struct.new(:result) do
      def call(transcript:, observed:)
        result
      end
    end.new(
      Agent::SessionContext::SemanticPipeline::Result.new(
        items: [mystery_item].freeze,
        warnings: ["pipeline warning"].freeze,
        metadata: { backend: :fake, chunks: 1 }.freeze
      )
    )

    snapshot = nil
    with_semantic_pipeline_new(proc { fake_pipeline }) do
      snapshot = builder.summarize(session, summarizer: FakeSummarizer.new(responses: [JSON.generate(full_payload)]))
    end

    assert_equal ["pipeline warning", "Dropped unknown semantic kind :mystery"], snapshot.warnings
    assert_equal [], snapshot.goals
    assert_equal [], snapshot.decisions
    assert_equal %i[
      session_uid
      agent
      project_path
      captured_at
      message_count
      prompts
      injected_context
      files
      documents
      tool_activity
      goals
      decisions
      terms
      constraints
      open_questions
      next_actions
      warnings
      summary_metadata
    ], snapshot.members
  end

  def test_public_api_supports_catalog_and_custom_summarizer_seams
    session = build_session(agent: :codex, id: "api-session")
    claude_session = build_session(agent: :claude, id: "claude-api-session")
    catalog = APICatalog.new(session.uid => FakeReader.new(prompt_messages(session), []))
    catalog.add_session(session)
    catalog.add_session(claude_session)
    backend = lambda do |prompt:, schema:|
      JSON.generate(
        full_payload(
          "goals" => [{ "text" => "API goal", "evidence" => "explicit", "source_refs" => [ref(session, 1, 1).to_s] }]
        )
      )
    end

    assert_same session, Agent::SessionContext.resolve("api-session", agent: :codex, env: {}, catalog:)
    assert_same session, Agent::SessionContext.current(env: { "CODEX_SESSION_ID" => "api-session" }, catalog:)
    assert_same session, Agent::SessionContext.current(agent: :codex, env: {}, catalog:)
    assert_same claude_session, Agent::SessionContext.current(agent: :claude, env: {}, catalog:)
    assert_equal ["First prompt", "Secondpart"], Agent::SessionContext.prompts(session, catalog:).map(&:text)
    assert_equal ["API goal"],
                 Agent::SessionContext.summarize(session, catalog:, summarizer: backend).goals.map(&:label)
    assert_equal :custom,
                 Agent::SessionContext.summarize(session, catalog:,
                                                          summarizer: backend).summary_metadata.fetch(:backend)
    show_snapshot = Agent::SessionContext.show(session, include_injected: true, catalog:)

    assert_equal ["First prompt", "Secondpart"], show_snapshot.prompts.map(&:text)
    assert_predicate show_snapshot, :frozen?
  end

  def test_public_show_rejects_non_boolean_include_injected_before_capture
    session = build_session(agent: :codex, id: "invalid-include-injected")
    catalog = APICatalog.new(session.uid => FakeReader.new(show_messages(session), []))

    error = assert_raises(ArgumentError) do
      Agent::SessionContext.show(session, include_injected: nil, catalog:)
    end

    assert_equal "include_injected must be true or false", error.message
    refute catalog.read_calls.key?(session.uid)
  end

  def test_public_api_summarize_loads_config_once_and_forwards_effective_timeout_for_built_in_backend
    session = build_session(agent: :codex, id: "api-timeout-explicit")
    catalog = APICatalog.new(session.uid => FakeReader.new(prompt_messages(session), []))
    catalog.add_session(session)
    backend = lambda do |prompt:, schema:|
      JSON.generate(
        full_payload(
          "goals" => [{ "text" => "Timed goal", "evidence" => "explicit", "source_refs" => [ref(session, 1, 1).to_s] }]
        )
      )
    end
    config_loader = APIConfigLoader.new(result: FakeConfig.new(timeout_seconds: 45))
    backend_factory = APIBackendFactory.new(result: backend)
    env = { "AGENT_CONTEXT_TEST" => "1" }.freeze

    snapshot = Agent::SessionContext.summarize(
      session,
      catalog:,
      timeout: 12,
      env:,
      config_loader:,
      backend_factory:
    )

    assert_equal [{ session:, env:, timeout: 12 }], config_loader.calls
    assert_equal [{ name: :codex, timeout_seconds: 45 }], backend_factory.calls
    assert_equal ["Timed goal"], snapshot.goals.map(&:label)
  end

  def test_public_api_summarize_uses_config_timeout_when_none_is_explicitly_provided
    session = build_session(agent: :claude, id: "api-timeout-default")
    catalog = APICatalog.new(session.uid => FakeReader.new(prompt_messages(session), []))
    catalog.add_session(session)
    backend = lambda do |prompt:, schema:|
      JSON.generate(
        full_payload(
          "goals" => [{ "text" => "Config goal", "evidence" => "explicit", "source_refs" => [ref(session, 1, 1).to_s] }]
        )
      )
    end
    config_loader = APIConfigLoader.new(result: FakeConfig.new(timeout_seconds: 88))
    backend_factory = APIBackendFactory.new(result: backend)
    env = { "AGENT_CONTEXT_TEST" => "2" }.freeze

    snapshot = Agent::SessionContext.summarize(
      session,
      catalog:,
      env:,
      config_loader:,
      backend_factory:
    )

    assert_equal [{ session:, env:, timeout: nil }], config_loader.calls
    assert_equal [{ name: :claude, timeout_seconds: 88 }], backend_factory.calls
    assert_equal ["Config goal"], snapshot.goals.map(&:label)
  end

  def test_public_api_summarize_forwards_false_timeout_to_config_loader_without_treating_it_as_nil
    session = build_session(agent: :claude, id: "api-timeout-false")
    config_error = Agent::SessionContext::ConfigurationError.new("invalid false timeout")
    config_loader = RaisingAPIConfigLoader.new(error: config_error)
    backend_factory = APIBackendFactory.new(result: Object.new)
    env = { "AGENT_CONTEXT_TEST" => "false" }.freeze

    error = assert_raises(Agent::SessionContext::ConfigurationError) do
      Agent::SessionContext.summarize(
        session,
        timeout: false,
        env:,
        config_loader:,
        backend_factory:
      )
    end

    assert_same config_error, error
    assert_equal [{ session:, env:, timeout: false }], config_loader.calls
    assert_equal [], backend_factory.calls
  end

  def test_public_api_custom_summarizer_with_explicit_timeout_raises_before_using_collaborators
    session = build_session(agent: :codex, id: "api-custom-timeout")
    config_loader = APIConfigLoader.new(result: FakeConfig.new(timeout_seconds: 30))
    backend_factory = APIBackendFactory.new(result: Object.new)
    backend = ->(**) { raise "should not be called" }

    error = assert_raises(ArgumentError) do
      Agent::SessionContext.summarize(session, summarizer: backend, timeout: 12, config_loader:, backend_factory:)
    end

    assert_equal "timeout applies only to built-in summarizers", error.message
    assert_equal [], config_loader.calls
    assert_equal [], backend_factory.calls
  end

  def test_public_api_custom_summarizer_without_timeout_bypasses_config_and_backend_factory
    session = build_session(agent: :codex, id: "api-custom")
    catalog = APICatalog.new(session.uid => FakeReader.new(prompt_messages(session), []))
    catalog.add_session(session)
    config_loader = APIConfigLoader.new(result: FakeConfig.new(timeout_seconds: 30))
    backend_factory = APIBackendFactory.new(result: Object.new)
    backend = lambda do |prompt:, schema:|
      JSON.generate(
        full_payload(
          "goals" => [{ "text" => "Custom goal", "evidence" => "explicit", "source_refs" => [ref(session, 1, 1).to_s] }]
        )
      )
    end

    snapshot = Agent::SessionContext.summarize(
      session,
      catalog:,
      summarizer: backend,
      config_loader:,
      backend_factory:
    )

    assert_equal [], config_loader.calls
    assert_equal [], backend_factory.calls
    assert_equal ["Custom goal"], snapshot.goals.map(&:label)
    assert_equal :custom, snapshot.summary_metadata.fetch(:backend)
  end

  def test_session_context_singleton_public_api_is_exact_for_this_gem
    assert_equal(
      %i[current loop prompts resolve show summarize],
      Agent::SessionContext.singleton_class.public_instance_methods(false).sort
    )
  end

  def test_summarizers_for_returns_known_backends_and_forwards_timeout
    codex_calls = []
    claude_calls = []
    codex_result = Object.new
    claude_result = Object.new

    Agent::SessionContext::Summarizers::Codex.stub(:new, lambda { |**kwargs|
      codex_calls << kwargs
      codex_result
    }) do
      Agent::SessionContext::Summarizers::Claude.stub(:new, lambda { |**kwargs|
        claude_calls << kwargs
        claude_result
      }) do
        assert_same codex_result, Agent::SessionContext::Summarizers.for(:codex, timeout_seconds: 12)
        assert_same codex_result, Agent::SessionContext::Summarizers.for("codex")
        assert_same claude_result, Agent::SessionContext::Summarizers.for("claude", timeout_seconds: 34)
        assert_same claude_result, Agent::SessionContext::Summarizers.for(:claude)
      end
    end

    assert_equal(
      [
        { timeout_seconds: 12 },
        { timeout_seconds: Agent::SessionContext::Config::DEFAULT_TIMEOUT_SECONDS }
      ],
      codex_calls
    )
    assert_equal(
      [
        { timeout_seconds: 34 },
        { timeout_seconds: Agent::SessionContext::Config::DEFAULT_TIMEOUT_SECONDS }
      ],
      claude_calls
    )
  end

  def test_summarizers_for_rejects_unknown_ones
    error = assert_raises(Agent::SessionContext::UnsupportedAgent) do
      Agent::SessionContext::Summarizers.for(:gemini)
    end

    assert_match(/unsupported summarizer/i, error.message)

    invalid_to_sym = Class.new do
      def to_sym
        123
      end
    end.new

    [nil, Object.new, invalid_to_sym].each do |value|
      error = assert_raises(Agent::SessionContext::UnsupportedAgent) do
        Agent::SessionContext::Summarizers.for(value)
      end

      assert_match(/unsupported summarizer/i, error.message)
      assert_match(/claude or codex/i, error.message)
    end
  end

  def test_with_semantic_pipeline_new_restores_inherited_new_ownership_shape_after_exceptions
    singleton = Agent::SessionContext::SemanticPipeline.singleton_class
    original_owner = Agent::SessionContext::SemanticPipeline.method(:new).owner
    original_public_methods = singleton.public_instance_methods(false)

    error = assert_raises(RuntimeError) do
      with_semantic_pipeline_new(proc { raise "boom" }) do
        Agent::SessionContext::SemanticPipeline.new
      end
    end

    assert_equal "boom", error.message
    assert_equal original_owner, Agent::SessionContext::SemanticPipeline.method(:new).owner
    assert_equal original_public_methods, singleton.public_instance_methods(false)
  end

  private

  def fixed_time
    @fixed_time ||= Time.utc(2026, 8, 27, 13, 0, 0)
  end

  def build_session(agent:, id:)
    Agent::Sessions::Session.new(
      agent: agent,
      id: id,
      path: "/tmp/#{id}.jsonl",
      started_at: Time.utc(2026, 8, 27, 11, 0, 0),
      updated_at: Time.utc(2026, 8, 27, 12, 30, 0),
      bytes: 512,
      format: :jsonl,
      fidelity: :full,
      project_path: "/tmp/project"
    )
  end

  def show_messages(_session)
    [
      build_message(
        role: :user,
        at: Time.utc(2026, 8, 27, 12, 0, 0),
        parts: [build_part(type: :text, text: "Visible prompt")]
      ),
      build_message(
        role: :user,
        at: Time.utc(2026, 8, 27, 12, 1, 0),
        parts: [build_part(type: :text, text: "<environment_context>\nSECRET=1")],
        raw: { "isMeta" => true }
      ),
      build_message(
        role: :assistant,
        at: Time.utc(2026, 8, 27, 12, 2, 0),
        parts: [
          build_part(type: :tool_use, text: %({"path":"README.md"}), name: "Read", call_id: "call-1"),
          build_part(type: :text, text: "I read the readme")
        ]
      )
    ]
  end

  def prompt_messages(_session)
    [
      build_message(
        role: :user,
        at: Time.utc(2026, 8, 27, 12, 0, 0),
        parts: [build_part(type: :text, text: "First prompt")]
      ),
      build_message(
        role: :assistant,
        at: Time.utc(2026, 8, 27, 12, 1, 0),
        parts: [build_part(type: :text, text: "ignored")]
      ),
      build_message(
        role: :user,
        at: Time.utc(2026, 8, 27, 12, 2, 0),
        parts: [
          build_part(type: :text, text: "Second"),
          build_part(type: :text, text: "part")
        ]
      )
    ]
  end

  def build_message(role:, at:, parts:, raw: {}, usage: nil, model: nil)
    Agent::Sessions::Message.new(role: role, at: at, parts: parts, raw: raw, usage: usage, model: model)
  end

  def build_part(type:, text: nil, name: nil, call_id: nil)
    Agent::Sessions::Part.new(type: type, text: text, name: name, call_id: call_id)
  end

  def ref(session, message_index, part_index)
    Agent::SessionContext::SourceRef.new(
      session_uid: session.uid,
      message_index: message_index,
      part_index: part_index
    )
  end

  def full_payload(overrides = {})
    {
      "goals" => [],
      "decisions" => [],
      "terms" => [],
      "constraints" => [],
      "open_questions" => [],
      "next_actions" => []
    }.merge(overrides)
  end

  def with_semantic_pipeline_new(replacement)
    singleton = Agent::SessionContext::SemanticPipeline.singleton_class
    original_name = :__minitest_stub__new
    original_owned_new =
      begin
        singleton.instance_method(:new).owner == singleton
      rescue NameError
        false
      end

    singleton.send(:alias_method, original_name, :new)
    singleton.send(:define_method, :new) do |*args, **kwargs|
      replacement.call(*args, **kwargs)
    end

    yield
  ensure
    if singleton
      singleton.send(:remove_method, :new) if singleton_owns_method?(singleton, :new)

      singleton.send(:alias_method, :new, original_name) if original_owned_new

      singleton.send(:remove_method, original_name) if singleton_owns_method?(singleton, original_name)
    end
  end

  def singleton_owns_method?(singleton, method_name)
    singleton.instance_method(method_name).owner == singleton
  rescue NameError
    false
  end
end
