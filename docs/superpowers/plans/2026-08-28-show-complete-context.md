# Complete Local Context in `show` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-ruby:subagent-driven-development (recommended) or superpowers-ruby:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `show` return exact user prompts and an injected-context inventory by default, with opt-in full injected text and explicit exclusions across the Ruby API and CLI.

**Architecture:** Extend the immutable `Snapshot` with `prompts` and `injected_context`. A focused collector groups byte-identical injected transcript parts while preserving provenance; `Builder#show` captures once and assembles prompts, injected inventory, and observed evidence. The existing renderers and CLI consume that same snapshot, so library and command behavior cannot drift.

**Tech Stack:** Ruby 3.2+, Zeitwerk, Minitest, `agent_sessions`, OptionParser, standard library JSON.

---

## Execution Context

- Worktree: `/Users/luciang/Dropbox/workprojects/opensource/agent_context/.worktrees/agent-context-show-complete-context`
- Branch: `feat/show-complete-context`
- Approved design: `docs/superpowers/specs/2026-08-28-show-complete-context-design.md`
- Baseline: 275 tests, 2,149 assertions, zero failures on Ruby 4.0.1
- Preserve the dirty `Gemfile` and untracked `Gemfile.lock` in the main worktree; they are outside this feature worktree.
- Do not push, publish, tag, or release.

## File Structure

### New files

- `lib/agent/session_context/injected_context.rb` — immutable public inventory entry.
- `lib/agent/session_context/injected_context_collector.rb` — exact grouping and marker-kind classification for injected transcript parts.
- `test/injected_context_collector_test.rb` — grouping, ordering, provenance, and content-inclusion coverage.

### Modified files

- `lib/agent/session_context/transcript.rb` — associate every existing exact injection marker with its stable inventory kind.
- `lib/agent/session_context/snapshot.rb` — add frozen `prompts` and `injected_context` collections.
- `lib/agent/session_context/builder.rb` — assemble the complete local `show` snapshot from one transcript capture.
- `lib/agent/session_context.rb` — expose strict `include_injected:` on the Ruby API.
- `lib/agent/session_context/renderers/text.rb` — render prompt and injected-context sections safely.
- `lib/agent/session_context/renderers/markdown.rb` — render nested prompt headings and fenced injected text safely.
- `lib/agent/session_context/cli.rb` — parse `--include-injected`, forward it, warn, and explain exclusions.
- `test/value_objects_test.rb` — pin the new value object and expanded snapshot contract.
- `test/transcript_test.rb` — pin marker-to-kind ownership without changing injection detection.
- `test/builder_test.rb` — pin one-read assembly, defaults, full inclusion, and Ruby API validation.
- `test/renderers_test.rb` — pin human order/safety and machine schema.
- `test/cli_test.rb` — pin flag scope, forwarding, warnings, help, and JSON cleanliness.
- `test/integration_test.rb` — exercise both real readers and prove summarizer input remains narrow.
- `README.md` — document the complete supported local view and explicit exclusions.
- `CHANGELOG.md` — record the unreleased behavior.

## Task 1: Model and Collect Injected Context

**Files:**
- Create: `lib/agent/session_context/injected_context.rb`
- Create: `lib/agent/session_context/injected_context_collector.rb`
- Create: `test/injected_context_collector_test.rb`
- Modify: `lib/agent/session_context/transcript.rb:169-221`
- Modify: `test/transcript_test.rb:5-18,110-128`
- Modify: `test/value_objects_test.rb:36-94`

- [ ] **Step 1: Write the failing `InjectedContext` value-object tests**

Add these tests after the existing prompt tests in `test/value_objects_test.rb`:

```ruby
def test_injected_context_normalizes_and_freezes_its_values
  text = String.new("# AGENTS.md instructions\nUse Ruby")
  refs = [
    Agent::SessionContext::SourceRef.new(
      session_uid: "codex:session-123",
      message_index: 1,
      part_index: 1
    )
  ]

  context = Agent::SessionContext::InjectedContext.new(
    kind: "agents_instructions",
    bytes: text.bytesize,
    occurrences: 1,
    source_refs: refs,
    text:
  )

  text.replace("mutated")
  refs.clear

  assert_equal :agents_instructions, context.kind
  assert_equal 33, context.bytes
  assert_equal 1, context.occurrences
  assert_equal 1, context.source_refs.length
  assert_equal "# AGENTS.md instructions\nUse Ruby", context.text
  assert_predicate context, :frozen?
  assert_predicate context.source_refs, :frozen?
  assert_predicate context.text, :frozen?
end

def test_injected_context_validates_counts_refs_and_optional_text
  ref = Agent::SessionContext::SourceRef.new(
    session_uid: "codex:session-123",
    message_index: 1,
    part_index: 1
  )

  context = Agent::SessionContext::InjectedContext.new(
    kind: :provider_meta,
    bytes: 0,
    occurrences: 1,
    source_refs: [ref]
  )

  assert_nil context.text
  assert_raises(ArgumentError) do
    Agent::SessionContext::InjectedContext.new(
      kind: :provider_meta,
      bytes: -1,
      occurrences: 1,
      source_refs: [ref]
    )
  end
  assert_raises(ArgumentError) do
    Agent::SessionContext::InjectedContext.new(
      kind: :provider_meta,
      bytes: 1,
      occurrences: 0,
      source_refs: [ref]
    )
  end
  assert_raises(TypeError) do
    Agent::SessionContext::InjectedContext.new(
      kind: :provider_meta,
      bytes: 1,
      occurrences: 1,
      source_refs: ["not a source ref"]
    )
  end
end
```

- [ ] **Step 2: Run the value-object tests and observe the missing constant**

Run:

```bash
bundle exec ruby -Itest test/value_objects_test.rb
```

Expected: FAIL with `NameError` for `Agent::SessionContext::InjectedContext`.

- [ ] **Step 3: Implement the immutable value object**

Create `lib/agent/session_context/injected_context.rb`:

```ruby
# frozen_string_literal: true

module Agent
  module Context
    InjectedContext = Data.define(:kind, :bytes, :occurrences, :source_refs, :text) do
      def initialize(kind:, bytes:, occurrences:, source_refs:, text: nil)
        super(
          kind: normalize_symbol(kind, :kind),
          bytes: normalize_nonnegative_integer(bytes, :bytes),
          occurrences: normalize_positive_integer(occurrences, :occurrences),
          source_refs: normalize_source_refs(source_refs),
          text: normalize_optional_string(text, :text)
        )
      end

      private

      def normalize_symbol(value, name)
        return value if value.is_a?(Symbol)
        return value.to_sym if value.respond_to?(:to_sym)

        fail TypeError, "#{name} must be symbolizable"
      end

      def normalize_nonnegative_integer(value, name)
        integer = normalize_integer(value, name)
        fail ArgumentError, "#{name} must be greater than or equal to 0" if integer.negative?

        integer
      end

      def normalize_positive_integer(value, name)
        integer = normalize_integer(value, name)
        fail ArgumentError, "#{name} must be greater than or equal to 1" if integer < 1

        integer
      end

      def normalize_integer(value, name)
        integer =
          if value.is_a?(Integer)
            value
          elsif value.respond_to?(:to_int)
            value.to_int
          elsif value.is_a?(String)
            Integer(value, exception: false)
          end

        fail TypeError, "#{name} must be an Integer or integer-like value" if integer.nil?

        integer
      end

      def normalize_source_refs(value)
        Array(value).map do |source_ref|
          fail TypeError, "source_refs must contain only Agent::SessionContext::SourceRef values" unless source_ref.is_a?(SourceRef)

          source_ref
        end.freeze
      end

      def normalize_optional_string(value, name)
        return if value.nil?
        fail TypeError, "#{name} must be a String" unless value.respond_to?(:to_str)

        String.new(value.to_str).freeze
      end
    end
  end
end
```

Zeitwerk discovers this file automatically; do not add a manual require.

- [ ] **Step 4: Run the value-object tests and verify they pass**

Run:

```bash
bundle exec ruby -Itest test/value_objects_test.rb
```

Expected: PASS with zero failures and zero errors.

- [ ] **Step 5: Write failing collector and marker-kind tests**

Create `test/injected_context_collector_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class InjectedContextCollectorTest < Minitest::Test
  Session = Data.define(:agent)

  def test_groups_exact_duplicates_in_first_seen_order_without_text_by_default
    agents_text = "# AGENTS.md instructions\nUse Ruby"
    environment_text = "<environment_context>\n<cwd>/tmp/project</cwd>"
    transcript = transcript_with(
      part(1, agents_text, injected: true),
      part(2, environment_text, injected: true),
      part(3, agents_text, injected: true),
      part(4, "ordinary prompt", injected: false),
      part(5, "opaque provider metadata", injected: true)
    )

    inventory = Agent::SessionContext::InjectedContextCollector.new.call(transcript)

    assert_equal %i[agents_instructions environment_context provider_meta], inventory.map(&:kind)
    assert_equal [agents_text.bytesize, environment_text.bytesize, 24], inventory.map(&:bytes)
    assert_equal [2, 1, 1], inventory.map(&:occurrences)
    assert_equal [[ref(1), ref(3)], [ref(2)], [ref(5)]], inventory.map(&:source_refs)
    assert_equal [nil, nil, nil], inventory.map(&:text)
    assert_predicate inventory, :frozen?
  end

  def test_includes_one_copy_of_each_unique_text_when_requested
    text = "<environment_context>\n<cwd>/tmp/project</cwd>"
    transcript = transcript_with(part(1, text, injected: true), part(2, text, injected: true))

    inventory = Agent::SessionContext::InjectedContextCollector.new.call(transcript, include_text: true)

    assert_equal [text], inventory.map(&:text)
    assert_equal [2], inventory.map(&:occurrences)
  end

  private

  def transcript_with(*parts)
    Agent::SessionContext::Transcript.new(
      session: Session.new(agent: :codex),
      captured_at: Time.utc(2026, 8, 28, 8, 0, 0),
      entries: [
        Agent::SessionContext::TranscriptEntry.new(
          index: 1,
          role: :user,
          at: Time.utc(2026, 8, 28, 7, 59, 0),
          parts:
        )
      ],
      warnings: []
    )
  end

  def part(index, text, injected:)
    Agent::SessionContext::TranscriptPart.new(
      index:,
      type: :text,
      text:,
      injected:,
      source_ref: ref(index)
    )
  end

  def ref(part_index)
    Agent::SessionContext::SourceRef.new(
      session_uid: "codex:session-123",
      message_index: 1,
      part_index:
    )
  end
end
```

In `test/transcript_test.rb`, replace the marker arrays with:

```ruby
CLAUDE_MARKER_KINDS = {
  "<command-name>" => :command_name,
  "<command-message>" => :command_message,
  "<command-args>" => :command_args,
  "<local-command-stdout>" => :local_command_stdout,
  "<local-command-stderr>" => :local_command_stderr,
  "<system-reminder>" => :system_reminder
}.freeze

CODEX_MARKER_KINDS = {
  "<environment_context>" => :environment_context,
  "<user_instructions>" => :user_instructions,
  "# AGENTS.md instructions" => :agents_instructions
}.freeze

CLAUDE_MARKERS = CLAUDE_MARKER_KINDS.keys.freeze
CODEX_MARKERS = CODEX_MARKER_KINDS.keys.freeze
```

Update the marker ownership assertion to expect the two marker-kind maps.

- [ ] **Step 6: Run the collector and transcript tests and observe the failures**

```bash
bundle exec ruby -Itest test/injected_context_collector_test.rb
bundle exec ruby -Itest test/transcript_test.rb
```

Expected: missing collector constant and array-versus-map contract failures.

- [ ] **Step 7: Implement stable marker kinds and exact injected collection**

Replace `Transcript::INJECTION_MARKERS` in `lib/agent/session_context/transcript.rb`:

```ruby
Transcript.const_set(
  :INJECTION_MARKERS,
  {
    claude: {
      "<command-name>" => :command_name,
      "<command-message>" => :command_message,
      "<command-args>" => :command_args,
      "<local-command-stdout>" => :local_command_stdout,
      "<local-command-stderr>" => :local_command_stderr,
      "<system-reminder>" => :system_reminder
    }.freeze,
    codex: {
      "<environment_context>" => :environment_context,
      "<user_instructions>" => :user_instructions,
      "# AGENTS.md instructions" => :agents_instructions
    }.freeze
  }.freeze
)
```

Change `marker_injected?` to:

```ruby
def marker_injected?(agent, text)
  return false unless text.respond_to?(:lstrip)

  stripped_text = text.lstrip
  marker_kinds = Transcript::INJECTION_MARKERS.fetch(agent&.to_sym, {})
  marker_kinds.each_key.any? { |marker| stripped_text.start_with?(marker) }
end
```

Create `lib/agent/session_context/injected_context_collector.rb`:

```ruby
# frozen_string_literal: true

module Agent
  module Context
    class InjectedContextCollector
      def call(transcript, include_text: false)
        validate_include_text!(include_text)
        groups = {}

        transcript.entries.each do |entry|
          entry.parts.each do |part|
            next unless part.injected

            text = part.text
            group = groups[text] ||= {
              kind: kind_for(transcript.session.agent, text),
              text:,
              source_refs: []
            }
            group.fetch(:source_refs) << part.source_ref
          end
        end

        groups.values.map do |group|
          source_refs = group.fetch(:source_refs)
          text = group.fetch(:text)
          InjectedContext.new(
            kind: group.fetch(:kind),
            bytes: text.bytesize,
            occurrences: source_refs.length,
            source_refs:,
            text: include_text ? text : nil
          )
        end.freeze
      end

      private

      def validate_include_text!(value)
        return if value == true || value == false

        fail ArgumentError, "include_text must be true or false"
      end

      def kind_for(agent, text)
        stripped_text = text.lstrip
        marker_kinds = Transcript::INJECTION_MARKERS.fetch(agent&.to_sym, {})
        match = marker_kinds.find { |marker, _kind| stripped_text.start_with?(marker) }
        match ? match.last : :provider_meta
      end
    end
  end
end
```

- [ ] **Step 8: Run focused tests**

```bash
bundle exec ruby -Itest test/value_objects_test.rb
bundle exec ruby -Itest test/transcript_test.rb
bundle exec ruby -Itest test/injected_context_collector_test.rb
```

Expected: all pass with zero failures and errors.

- [ ] **Step 9: Commit the injected-context domain layer**

```bash
git add lib/agent/session_context/injected_context.rb lib/agent/session_context/injected_context_collector.rb lib/agent/session_context/transcript.rb test/value_objects_test.rb test/transcript_test.rb test/injected_context_collector_test.rb
git commit -m "Preserve injected context provenance without repeated payloads" \
  -m "Model injected entries explicitly and assign stable kinds to the exact markers already used for filtering. Group only byte-identical text so the inventory stays compact without losing source references." \
  -m "Constraint: Injection detection remains exact and agent-specific" \
  -m "Rejected: Fuzzy deduplication | it can merge materially different instructions" \
  -m "Confidence: high" \
  -m "Scope-risk: narrow" \
  -m "Tested: Value-object, transcript marker, and collector unit tests"
```

## Task 2: Assemble the Complete `show` Snapshot

**Files:**
- Modify: `lib/agent/session_context/snapshot.rb:5-58`
- Modify: `lib/agent/session_context/builder.rb:22-40,99-125`
- Modify: `lib/agent/session_context.rb:26-28`
- Modify: `test/value_objects_test.rb:235-285`
- Modify: `test/builder_test.rb:89-139,226-246`

- [ ] **Step 1: Expand the failing snapshot contract tests**

Insert `prompts` and `injected_context` after `message_count` in the exact
`Snapshot.members` expectation in `test/value_objects_test.rb`. Add:

```ruby
assert_equal [], snapshot.prompts
assert_equal [], snapshot.injected_context
assert_predicate snapshot.prompts, :frozen?
assert_predicate snapshot.injected_context, :frozen?
```

Extend the snapshot defensive-copy test with real objects:

```ruby
prompt = Agent::SessionContext::Prompt.new(
  index: 1,
  at: nil,
  text: "Exact prompt",
  source_refs: []
)
injected = Agent::SessionContext::InjectedContext.new(
  kind: :provider_meta,
  bytes: 4,
  occurrences: 1,
  source_refs: [],
  text: "meta"
)
prompts = [prompt]
injected_context = [injected]

snapshot = Agent::SessionContext::Snapshot.new(
  session_uid: session_uid,
  agent: "codex",
  project_path: project_path,
  captured_at: Time.utc(2026, 8, 27, 12, 30, 0),
  message_count: 3,
  prompts:,
  injected_context:,
  files:,
  warnings:,
  summary_metadata:
)

prompts.clear
injected_context.clear

assert_equal [prompt], snapshot.prompts
assert_equal [injected], snapshot.injected_context
assert_predicate snapshot.prompts, :frozen?
assert_predicate snapshot.injected_context, :frozen?
```

- [ ] **Step 2: Update builder/API tests for one-read assembly and strict opt-in**

Rename the observed-only show test to
`test_show_builds_complete_local_snapshot_once_without_instantiating_a_backend`
and add:

```ruby
assert_equal ["Visible prompt"], snapshot.prompts.map(&:text)
assert_equal [:environment_context], snapshot.injected_context.map(&:kind)
assert_equal [nil], snapshot.injected_context.map(&:text)
```

Add:

```ruby
def test_show_can_include_full_injected_text
  session = build_session(agent: :codex, id: "show-injected-session")
  catalog = ReadCatalog.new(session.uid => FakeReader.new(show_messages(session), []))
  builder = Agent::SessionContext::Builder.new(catalog:, now: fixed_time)

  snapshot = builder.show(session, include_injected: true)

  assert_equal 1, catalog.read_calls.fetch(session.uid)
  assert_equal ["<environment_context>\nSECRET=1"], snapshot.injected_context.map(&:text)
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
```

In the public API seam test, retain the show result and pin parity:

```ruby
show_snapshot = Agent::SessionContext.show(session, include_injected: true, catalog:)

assert_equal ["First prompt", "Secondpart"], show_snapshot.prompts.map(&:text)
assert_predicate show_snapshot, :frozen?
```

- [ ] **Step 3: Run snapshot and builder tests and observe failures**

```bash
bundle exec ruby -Itest test/value_objects_test.rb
bundle exec ruby -Itest test/builder_test.rb
```

Expected: missing snapshot members, missing builder keyword, and absent collection failures.

- [ ] **Step 4: Extend `Snapshot` with the frozen collections**

In `lib/agent/session_context/snapshot.rb`, add members after `:message_count`:

```ruby
:prompts,
:injected_context,
```

Add defaults after `message_count:`:

```ruby
prompts: [],
injected_context: [],
```

Pass them through the existing copier before `files`:

```ruby
prompts: duplicate_collection(prompts),
injected_context: duplicate_collection(injected_context),
```

- [ ] **Step 5: Build all `show` collections from one capture**

Change the builder initializer in `lib/agent/session_context/builder.rb` to:

```ruby
def initialize(
  catalog: Agent::Sessions,
  now: Time.now,
  collector: EvidenceCollector.new,
  prompt_extractor: PromptExtractor.new,
  injected_context_collector: InjectedContextCollector.new
)
  @catalog = catalog
  @now = now
  @collector = collector
  @prompt_extractor = prompt_extractor
  @injected_context_collector = injected_context_collector
end
```

Replace `show` with:

```ruby
def show(session, include_injected: false)
  validate_include_injected!(include_injected)
  transcript = capture(session)
  observed = @collector.call(transcript)

  build_snapshot(
    session:,
    transcript:,
    observed:,
    prompts: @prompt_extractor.call(transcript),
    injected_context: @injected_context_collector.call(
      transcript,
      include_text: include_injected
    ),
    warnings: transcript.warnings + observed.warnings,
    summary_metadata: base_metadata(transcript)
  )
end
```

Add under `private`:

```ruby
def validate_include_injected!(value)
  return if value == true || value == false

  fail ArgumentError, "include_injected must be true or false"
end
```

Expand `build_snapshot` without changing the semantic default:

```ruby
def build_snapshot(
  session:,
  transcript:,
  observed:,
  warnings:,
  summary_metadata:,
  prompts: [],
  injected_context: [],
  semantic_collections: empty_semantic_collections.transform_values(&:freeze).freeze
)
  Snapshot.new(
    session_uid: session.uid,
    agent: session.agent,
    project_path: session.project_path,
    captured_at: transcript.captured_at,
    message_count: transcript.entries.length,
    prompts:,
    injected_context:,
    files: observed.files,
    documents: observed.documents,
    tool_activity: observed.tool_activity,
    goals: semantic_collections.fetch(:goals),
    decisions: semantic_collections.fetch(:decisions),
    terms: semantic_collections.fetch(:terms),
    constraints: semantic_collections.fetch(:constraints),
    open_questions: semantic_collections.fetch(:open_questions),
    next_actions: semantic_collections.fetch(:next_actions),
    warnings:,
    summary_metadata:
  )
end
```

- [ ] **Step 6: Expose the same keyword through the module API**

Replace `Agent::SessionContext.show` in `lib/agent/session_context.rb`:

```ruby
def show(session, include_injected: false, **options)
  Builder.new(**options).show(session, include_injected:)
end
```

- [ ] **Step 7: Run focused tests**

```bash
bundle exec ruby -Itest test/value_objects_test.rb
bundle exec ruby -Itest test/builder_test.rb
```

Expected: both pass with zero failures and errors.

- [ ] **Step 8: Commit complete snapshot assembly**

```bash
git add lib/agent/session_context.rb lib/agent/session_context/snapshot.rb lib/agent/session_context/builder.rb test/value_objects_test.rb test/builder_test.rb
git commit -m "Make show mean complete supported local context" \
  -m "Users expect one local operation to return prompts, injected visibility, and observed evidence. Assemble those collections from a single transcript capture while keeping semantic snapshots narrow." \
  -m "Constraint: CLI and library must share one snapshot path" \
  -m "Rejected: Re-read through the prompts API | it duplicates capture and can produce inconsistent timestamps" \
  -m "Confidence: high" \
  -m "Scope-risk: moderate" \
  -m "Directive: Keep include_injected strict and local-only" \
  -m "Tested: Snapshot and builder/API unit tests"
```

## Task 3: Render Prompts and Injected Context Safely

**Files:**
- Modify: `lib/agent/session_context/renderers/text.rb:16-51`
- Modify: `lib/agent/session_context/renderers/markdown.rb:16-52`
- Modify: `test/renderers_test.rb:5-210,629-716`

- [ ] **Step 1: Add failing human-renderer ordering and safety coverage**

Add to `test/renderers_test.rb`:

```ruby
def test_snapshot_renderers_place_prompts_and_injected_context_before_observed_evidence
  injected_text = "# AGENTS.md instructions\n## forged heading\n```ruby\nputs 1\n```\n\e[31m"
  snapshot = Agent::SessionContext::Snapshot.new(
    session_uid: "codex:session-123",
    agent: :codex,
    project_path: "/tmp/project",
    captured_at: Time.utc(2026, 8, 28, 8, 0, 0),
    message_count: 3,
    prompts: [
      Agent::SessionContext::Prompt.new(
        index: 1,
        at: nil,
        text: "Exact prompt",
        source_refs: [ref(1, 1)]
      )
    ],
    injected_context: [
      Agent::SessionContext::InjectedContext.new(
        kind: :agents_instructions,
        bytes: injected_text.bytesize,
        occurrences: 2,
        source_refs: [ref(2, 1), ref(3, 1)],
        text: injected_text
      )
    ],
    files: [
      Agent::SessionContext::Item.new(
        kind: :file,
        label: "README.md",
        evidence: :observed,
        source_refs: [ref(3, 2)]
      )
    ]
  )

  text = Agent::SessionContext::Renderers::Text.new.call(snapshot)
  markdown = Agent::SessionContext::Renderers::Markdown.new.call(snapshot)

  assert_operator text.index("User prompts"), :<, text.index("Injected context")
  assert_operator text.index("Injected context"), :<, text.index("Files")
  assert_includes text, "Prompt 1"
  assert_includes text, "- Bytes: #{injected_text.bytesize}"
  assert_includes text, "- Occurrences: 2"
  assert_includes text, "- Refs: 2:1, 3:1"
  assert_includes text, "| \\e[31m"

  assert_operator markdown.index("## User prompts"), :<, markdown.index("## Injected context")
  assert_operator markdown.index("## Injected context"), :<, markdown.index("## Files")
  assert_includes markdown, "### Prompt 1"
  assert_includes markdown, "### Injected `agents_instructions`"
  assert_includes markdown, Agent::SessionContext::Renderers::HumanDisplay.markdown_block(injected_text)
end
```

Extend the empty-section test:

```ruby
refute_includes text, "User prompts"
refute_includes text, "Injected context"
refute_includes markdown, "## User prompts"
refute_includes markdown, "## Injected context"
```

- [ ] **Step 2: Expand failing JSON schema expectations**

Insert `prompts` and `injected_context` after `message_count` in the JSON key
list. Add to the empty snapshot assertions:

```ruby
assert_equal [], parsed.fetch("prompts")
assert_equal [], parsed.fetch("injected_context")
```

Add a focused machine-output test:

```ruby
def test_json_renderer_serializes_prompts_and_injected_context
  snapshot = Agent::SessionContext::Snapshot.new(
    session_uid: "codex:session-123",
    agent: :codex,
    project_path: "/tmp/project",
    captured_at: Time.utc(2026, 8, 28, 8, 0, 0),
    message_count: 2,
    prompts: sample_prompts,
    injected_context: [
      Agent::SessionContext::InjectedContext.new(
        kind: :environment_context,
        bytes: 31,
        occurrences: 1,
        source_refs: [ref(1, 4)]
      )
    ]
  )
  parsed = ::JSON.parse(Agent::SessionContext::Renderers::JSON.new.call(snapshot))

  assert_equal "First prompt", parsed.fetch("prompts").first.fetch("text")
  assert_equal(
    {
      "kind" => "environment_context",
      "bytes" => 31,
      "occurrences" => 1,
      "source_refs" => [
        {"session_uid" => "codex:session-123", "message_index" => 1, "part_index" => 4}
      ],
      "text" => nil
    },
    parsed.fetch("injected_context").first
  )
end
```

- [ ] **Step 3: Run renderer tests and observe missing sections**

```bash
bundle exec ruby -Itest test/renderers_test.rb
```

Expected: failures because snapshot renderers omit prompts and injected context.

- [ ] **Step 4: Render new sections in text output**

In `lib/agent/session_context/renderers/text.rb`, replace `render_snapshot` and add:

```ruby
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
```

- [ ] **Step 5: Render nested prompt headings and injected blocks in Markdown**

In `lib/agent/session_context/renderers/markdown.rb`, replace `render_snapshot` with the
same section order as text. Change `render_prompts` and add:

```ruby
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
```

The replacement `render_snapshot` is:

```ruby
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
```

- [ ] **Step 6: Run renderer tests**

```bash
bundle exec ruby -Itest test/renderers_test.rb
```

Expected: pass with zero failures and errors.

- [ ] **Step 7: Commit rendering**

```bash
git add lib/agent/session_context/renderers/text.rb lib/agent/session_context/renderers/markdown.rb test/renderers_test.rb
git commit -m "Keep complete show output readable and structurally safe" \
  -m "Put exact prompts and injected inventory ahead of observed evidence, and render recorded text through the existing literal-block safety boundary. Machine output receives stable fields without changing standalone prompts." \
  -m "Constraint: Recorded content must not forge surrounding text or Markdown structure" \
  -m "Rejected: Generic item rendering | full injected text needs block semantics" \
  -m "Confidence: high" \
  -m "Scope-risk: moderate" \
  -m "Tested: Text, Markdown, JSON, ordering, and hostile-content renderer tests"
```

## Task 4: Expose Full Injected Text Through the CLI

**Files:**
- Modify: `lib/agent/session_context/cli.rb:9-15,61-69,110-129,132-178`
- Modify: `test/cli_test.rb:42-70,108-132,325-405,1155-1220`

- [ ] **Step 1: Make the fake builder record the new keyword**

Replace `FakeBuilder#show`:

```ruby
def show(session, include_injected: false)
  @show_calls << {session:, include_injected:}
  @show_result
end
```

Update successful show-call expectations from `[session]` to:

```ruby
[{session:, include_injected: false}]
```

- [ ] **Step 2: Write failing flag, warning, and help tests**

Add:

```ruby
def test_show_forwards_include_injected_and_prints_stronger_privacy_warning
  session = build_session(agent: :codex, id: "session-injected")
  resolver = FakeResolver.new(resolve_result: session)
  builder = FakeBuilder.new(show_result: build_snapshot(session))

  status, _out, err = run_cli(
    "show",
    session.uid,
    "--include-injected",
    resolver:,
    builder:
  )

  assert_equal 0, status
  assert_equal [{session:, include_injected: true}], builder.show_calls
  assert_equal "warning: exact prompts and full injected context may contain secrets; review before sharing\n", err
end

def test_show_without_full_injected_text_still_warns_about_exact_prompts
  session = build_session(agent: :codex, id: "session-prompts")
  resolver = FakeResolver.new(resolve_result: session)
  builder = FakeBuilder.new(show_result: build_snapshot(session))

  status, _out, err = run_cli("show", session.uid, resolver:, builder:)

  assert_equal 0, status
  assert_equal "warning: exact prompts may contain secrets; review before sharing\n", err
end

def test_include_injected_is_rejected_outside_show
  %w[prompts summarize].each do |command|
    status, out, err = run_cli(command, "codex:session-1", "--include-injected")

    assert_equal 1, status
    assert_equal "", out
    assert_equal "invalid option: --include-injected\n", err
  end
end

def test_help_defines_show_inclusions_and_exclusions
  status, out, err = run_cli("help")

  assert_equal 0, status
  assert_equal "", err
  assert_includes out, "--include-injected"
  assert_includes out, "exact user prompts"
  assert_includes out, "assistant messages"
  assert_includes out, "thinking"
  assert_includes out, "tool-result bodies"
  assert_includes out, "raw provider envelopes"
end
```

Update the three successful show tests to expect the default privacy warning
instead of empty stderr. In the snapshot-warning test, assert both the privacy
line and reader warning are present. Insert the new empty arrays after
`message_count` in the JSON show expectation:

```ruby
"prompts" => [],
"injected_context" => [],
```

- [ ] **Step 3: Run CLI tests and observe failures**

```bash
bundle exec ruby -Itest test/cli_test.rb
```

Expected: unknown option and missing privacy warning failures.

- [ ] **Step 4: Parse, forward, and warn for the flag**

Change the show option rules:

```ruby
show: {
  "--current" => :flag,
  "--agent" => :value,
  "--format" => :value,
  "--include-injected" => :flag
}.freeze,
```

Replace CLI `show`:

```ruby
def show
  @current_format = hinted_format(@argv)
  selection = parse_selection(
    @argv,
    command: "show",
    allowed_formats: %i[text markdown json],
    allow_include_injected: true
  )
  session = resolve_session(selection)
  include_injected = selection.fetch(:include_injected)
  snapshot = @builder.show(session, include_injected:)
  emit_show_privacy_warning(include_injected)
  emit_warnings(session.uid, snapshot.warnings)
  write_output(snapshot, format: selection.fetch(:format))
  partial_capture_status(snapshot)
end
```

Expand `parse_selection` with `allow_include_injected: false`, add
`include_injected: false` to its options hash, and register:

```ruby
if allow_include_injected
  parser.on("--include-injected") { options[:include_injected] = true }
end
```

Add:

```ruby
def emit_show_privacy_warning(include_injected)
  if include_injected
    @stderr.puts "warning: exact prompts and full injected context may contain secrets; review before sharing"
  else
    @stderr.puts "warning: exact prompts may contain secrets; review before sharing"
  end
end
```

- [ ] **Step 5: Expand CLI help with the precise boundary**

Add after Common options:

```text
Show behavior:
  Includes exact user prompts and an injected-context inventory.
  --include-injected  Include deduplicated full injected text
  Excludes assistant messages, thinking, tool-result bodies,
  and raw provider envelopes.
```

- [ ] **Step 6: Run CLI tests**

```bash
bundle exec ruby -Itest test/cli_test.rb
```

Expected: pass; JSON stdout remains parseable and warning-free.

- [ ] **Step 7: Commit CLI behavior**

```bash
git add lib/agent/session_context/cli.rb test/cli_test.rb
git commit -m "Make full injected context an explicit show choice" \
  -m "Expose the same strict opt-in as the Ruby API, warn whenever show emits exact prompts, and define the exclusions in command help so complete context is not mistaken for a raw transcript." \
  -m "Constraint: Full injected text must never be enabled by configuration or truthy coercion" \
  -m "Rejected: Enable full text by default | large duplicated instruction blocks overwhelm normal output" \
  -m "Confidence: high" \
  -m "Scope-risk: moderate" \
  -m "Directive: Keep --include-injected scoped to local show output" \
  -m "Tested: CLI parsing, forwarding, warnings, help, and JSON envelopes"
```

## Task 5: Prove Both Readers and Document the Contract

**Files:**
- Modify: `test/integration_test.rb:8-25,30-240,304-336`
- Modify: `README.md:3-11,30-54,114-171,173-226,251-272`
- Modify: `CHANGELOG.md:1-3`

- [ ] **Step 1: Expand integration schema and show assertions**

Insert `prompts` and `injected_context` after `message_count` in
`SNAPSHOT_KEYS` and `assert_snapshot_keys`.

In both fixture tests, after the standalone prompt assertion, add:

```ruby
assert_equal prompts, show_snapshot.prompts
assert_equal [], summary_snapshot.prompts
assert_equal [], summary_snapshot.injected_context
assert show_snapshot.injected_context.all? { |context| context.text.nil? }
```

For Claude, pin inventory and full text:

```ruby
assert_equal %i[command_name provider_meta], show_snapshot.injected_context.map(&:kind)
assert_equal [1, 1], show_snapshot.injected_context.map(&:occurrences)

full_show_snapshot = Agent::SessionContext.show(session, include_injected: true)
assert_equal [
  "<command-name>/compact</command-name>\n<command-message>Keep only the release decision.</command-message>",
  "Internal planner note: preserve the release rationale only."
], full_show_snapshot.injected_context.map(&:text)
```

For Codex, pin inventory and full text:

```ruby
assert_equal %i[environment_context agents_instructions], show_snapshot.injected_context.map(&:kind)
assert_equal [1, 1], show_snapshot.injected_context.map(&:occurrences)

full_show_snapshot = Agent::SessionContext.show(session, include_injected: true)
assert_equal [
  "<environment_context>\n<cwd>/Users/you/demo-app</cwd>\n<approval_policy>never</approval_policy>\n</environment_context>",
  "# AGENTS.md instructions\nUse Ruby for utility scripts.\n"
], full_show_snapshot.injected_context.map(&:text)
```

After parsing each show and summary snapshot, assert:

```ruby
assert_equal parse_jsonl(prompts), show_json.fetch("prompts")
assert_equal 2, show_json.fetch("injected_context").length
assert show_json.fetch("injected_context").all? { |context| context.fetch("text").nil? }
assert_equal [], summary_json.fetch("prompts")
assert_equal [], summary_json.fetch("injected_context")
```

Keep the existing `refute_includes` assertions against semantic requests; they
prove local injected visibility does not widen provider input.

- [ ] **Step 2: Run integration tests**

```bash
bundle exec ruby -Itest test/integration_test.rb
```

Expected: both real-reader fixtures pass, and session bytes and mtimes remain unchanged.

- [ ] **Step 3: Update README commands and API examples**

Change the synopsis:

```text
agent-session-context show SESSION [--include-injected] [--format text|markdown|json]
```

Use these Ruby examples:

```ruby
snapshot = Agent::SessionContext.show(session)
snapshot_with_injected_text = Agent::SessionContext.show(session, include_injected: true)
prompts = Agent::SessionContext.prompts(session)
```

- [ ] **Step 4: Document the supported local view and explicit exclusions**

Replace the current show bullet list with:

```markdown
`show` returns all supported local context in one snapshot:

- session identity and capture metadata
- exact user-authored prompts
- an injected-context inventory with kind, byte size, occurrences, and source refs
- observed files and documents referenced by recorded tool calls
- observed tool activity
- warnings and summary metadata

Pass `--include-injected` or Ruby `include_injected: true` to include one copy
of each byte-identical injected block. The default inventory omits the text so
large repeated AGENTS and environment blocks do not dominate the output.

`show` deliberately remains narrower than a raw transcript. It always excludes
assistant messages, thinking content, tool-result bodies, and raw provider
envelopes. Both `show` modes are local-only and never invoke a semantic provider.
```

In Privacy and Isolation, state that exact prompts and opt-in injected text may
contain secrets and must be reviewed before sharing. Preserve the statement
that `summarize` excludes injected blocks from provider input.

Update the machine-schema list so snapshots include `prompts` and
`injected_context` after `message_count`. Explain that summarize snapshots keep
both arrays empty.

- [ ] **Step 5: Add the unreleased changelog entry**

Under `## [Unreleased]`:

```markdown
- Make `show` include exact user prompts and a deduplicated injected-context
  inventory, with explicit `--include-injected`/`include_injected: true` access
  to full local text and documented raw-transcript exclusions.
```

- [ ] **Step 6: Run documentation-adjacent tests**

```bash
bundle exec ruby -Itest test/cli_test.rb
bundle exec ruby -Itest test/integration_test.rb
bundle exec ruby -Itest test/load_test.rb
```

Expected: all pass with zero failures and errors.

- [ ] **Step 7: Commit the verified public contract**

```bash
git add test/integration_test.rb README.md CHANGELOG.md
git commit -m "Explain the supported boundary behind complete show output" \
  -m "Prove prompts and injected inventory through both real session readers, while retaining semantic exclusions and unchanged fixture files. Document what complete means and what remains intentionally absent." \
  -m "Constraint: Local visibility must not widen summarizer provider input" \
  -m "Rejected: Call show a raw transcript | assistant, thinking, result bodies, and provider envelopes remain excluded" \
  -m "Confidence: high" \
  -m "Scope-risk: moderate" \
  -m "Directive: Keep README, CLI help, and JSON schema aligned when snapshot fields change" \
  -m "Tested: Claude/Codex integration, CLI, and load tests"
```

## Task 6: Full Verification and Live Codex Smoke Test

**Files:**
- Verify only; modify source only after reproducing a failed check with a focused test.

- [ ] **Step 1: Run every focused test under Ruby 4.0.1**

```bash
source /opt/homebrew/opt/chruby/share/chruby/chruby.sh
chruby ruby-4.0.1
bundle exec ruby -Itest test/value_objects_test.rb
bundle exec ruby -Itest test/transcript_test.rb
bundle exec ruby -Itest test/injected_context_collector_test.rb
bundle exec ruby -Itest test/builder_test.rb
bundle exec ruby -Itest test/renderers_test.rb
bundle exec ruby -Itest test/cli_test.rb
bundle exec ruby -Itest test/integration_test.rb
```

Expected: every command exits zero with no failures or errors.

- [ ] **Step 2: Run the full suite under Ruby 4.0.1**

```bash
bundle exec rake test
```

Expected: all tests pass; the test count exceeds the 275-test baseline.

- [ ] **Step 3: Run the full suite under Ruby 3.2.3**

```bash
source /opt/homebrew/opt/chruby/share/chruby/chruby.sh
chruby ruby-3.2.3
bundle exec rake test
```

Expected: the same test and assertion counts as Ruby 4.0.1, with zero failures,
errors, or skips.

- [ ] **Step 4: Check syntax, whitespace, and package contents**

```bash
source /opt/homebrew/opt/chruby/share/chruby/chruby.sh
chruby ruby-4.0.1
ruby -cw lib/agent/session_context/injected_context.rb
ruby -cw lib/agent/session_context/injected_context_collector.rb
ruby -cw lib/agent/session_context/snapshot.rb
ruby -cw lib/agent/session_context/builder.rb
ruby -cw lib/agent/session_context/renderers/text.rb
ruby -cw lib/agent/session_context/renderers/markdown.rb
ruby -cw lib/agent/session_context/cli.rb
git diff --check main...HEAD
bundle exec rake build
```

Expected: each Ruby command prints `Syntax OK`, the diff check is silent, and
the gem builds with the new library files included.

- [ ] **Step 5: Smoke-test the current Codex session without a provider**

Use the known UID when the terminal lacks `CODEX_SESSION_ID`:

```bash
bundle exec exe/agent-session-context show codex:01a042c7-3f6d-7301-9cb0-51e9e6fc1183 --format json > /tmp/agent-context-show.json
ruby -rjson -e 'payload = JSON.parse(File.read(ARGV.fetch(0))); abort "missing prompts" unless payload.fetch("prompts").any?; abort "missing injected inventory" unless payload.fetch("injected_context").any?; abort "default leaked text" unless payload.fetch("injected_context").all? { |entry| entry.fetch("text").nil? }' /tmp/agent-context-show.json
bundle exec exe/agent-session-context show codex:01a042c7-3f6d-7301-9cb0-51e9e6fc1183 --include-injected --format json > /tmp/agent-context-show-full.json
ruby -rjson -e 'payload = JSON.parse(File.read(ARGV.fetch(0))); abort "full text missing" unless payload.fetch("injected_context").all? { |entry| entry.fetch("text").is_a?(String) }' /tmp/agent-context-show-full.json
```

Expected: both show commands print privacy warnings to stderr, both Ruby checks
exit zero, and no `summarizing with ...` line appears.

- [ ] **Step 6: Verify repository state**

```bash
git status --short
git log --oneline --decorate -6
```

Expected: only ignored package output may remain. Do not stage `pkg/*.gem`,
temporary JSON, a lockfile, or unrelated files. If verification reveals a
defect, reproduce it in a focused test, make the minimal fix, rerun all affected
checks, and commit with Lore trailers.

## Completion Criteria

- `Agent::SessionContext.show(session)` includes exact prompts and inventory-only injected entries.
- `Agent::SessionContext.show(session, include_injected: true)` includes one full copy of each unique injected block.
- CLI `show` behaves identically and scopes `--include-injected` to that command.
- Human and machine renderers expose the same data safely.
- Help and README explicitly list assistant messages, thinking, tool-result bodies, and raw provider envelopes as excluded.
- Semantic provider input remains unchanged and excludes injected text.
- Claude and Codex fixture files remain byte-for-byte and mtime unchanged.
- Ruby 3.2.3 and Ruby 4.0.1 suites pass with identical counts.
- The gem builds, but nothing is pushed or published.
