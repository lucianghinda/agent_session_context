# frozen_string_literal: true

require "test_helper"
require_relative "support/fake_catalog"

class SessionResolverTest < Minitest::Test
  def test_resolve_matches_agent_prefixed_identifier_exactly
    catalog = FakeCatalog.new
                         .add(:claude, session(:claude, id: "claude-1"))
                         .add(:codex, session(:codex, id: "codex-1"))

    resolver = build_resolver(catalog:)

    assert_equal "claude:claude-1", resolver.resolve("claude:claude-1").uid
    assert_equal({ claude: 1 }, catalog.calls)
  end

  def test_resolve_uses_explicit_agent_with_bare_identifier
    catalog = FakeCatalog.new
                         .add(:claude, session(:claude, id: "shared-id"))
                         .add(:codex, session(:codex, id: "shared-id"))

    resolver = build_resolver(catalog:)

    assert_equal "codex:shared-id", resolver.resolve("shared-id", agent: :codex).uid
    assert_equal({ codex: 1 }, catalog.calls)
  end

  def test_resolve_prefers_explicit_agent_over_identifier_prefix
    catalog = FakeCatalog.new
                         .add(:claude, session(:claude, id: "shared-id"))
                         .add(:codex, session(:codex, id: "shared-id"))

    resolver = build_resolver(catalog:)

    assert_equal "claude:shared-id", resolver.resolve("codex:shared-id", agent: :claude).uid
    assert_equal({ claude: 1 }, catalog.calls)
  end

  def test_resolve_scans_both_agents_for_unique_bare_identifier
    catalog = FakeCatalog.new
                         .add(:claude, session(:claude, id: "claude-only"))
                         .add(:codex, session(:codex, id: "codex-only"))

    resolver = build_resolver(catalog:)

    assert_equal "codex:codex-only", resolver.resolve("codex-only").uid
    assert_equal({ claude: 1, codex: 1 }, catalog.calls)
  end

  def test_resolve_rejects_duplicate_bare_identifier_across_agents
    catalog = FakeCatalog.new
                         .add(:claude, session(:claude, id: "duplicate"))
                         .add(:codex, session(:codex, id: "duplicate"))

    resolver = build_resolver(catalog:)

    error = assert_raises(Agent::SessionContext::AmbiguousSession) do
      resolver.resolve("duplicate")
    end

    assert_includes error.message, "claude:duplicate"
    assert_includes error.message, "codex:duplicate"
  end

  def test_resolve_rejects_duplicate_identifier_within_one_agent
    catalog = FakeCatalog.new
                         .add(
                           :codex,
                           session(:codex, id: "duplicate", uid: "codex:duplicate:first"),
                           session(:codex, id: "duplicate", uid: "codex:duplicate:second")
                         )

    resolver = build_resolver(catalog:)

    error = assert_raises(Agent::SessionContext::AmbiguousSession) do
      resolver.resolve("duplicate", agent: :codex)
    end

    assert_includes error.message, "codex:duplicate:first"
    assert_includes error.message, "codex:duplicate:second"
  end

  def test_resolve_raises_session_not_found_for_unknown_identifier
    resolver = build_resolver(catalog: FakeCatalog.new)

    error = assert_raises(Agent::SessionContext::SessionNotFound) do
      resolver.resolve("missing-id")
    end

    assert_includes error.message, "missing-id"
  end

  def test_resolve_rejects_unsupported_identifier_prefix
    resolver = build_resolver(catalog: FakeCatalog.new)

    error = assert_raises(Agent::SessionContext::UnsupportedAgent) do
      resolver.resolve("cursor:abc123")
    end

    assert_includes error.message, "cursor"
  end

  def test_current_generic_environment_overrides_provider_variables
    catalog = FakeCatalog.new
                         .add(:claude, session(:claude, id: "claude-1"))
                         .add(:codex, session(:codex, id: "codex-1"))

    resolver = build_resolver(
      catalog:,
      env: {
        "AGENT_SESSION_ID" => "claude-1",
        "AGENT_NAME" => "claude",
        "CLAUDE_CODE_SESSION_ID" => "ignored-claude",
        "CODEX_SESSION_ID" => "codex-1"
      }
    )

    assert_equal "claude:claude-1", resolver.current.uid
    assert_equal({ claude: 1 }, catalog.calls)
  end

  def test_current_uses_agent_name_over_agent_session_id_prefix
    catalog = FakeCatalog.new
                         .add(:claude, session(:claude, id: "shared-id"))
                         .add(:codex, session(:codex, id: "shared-id"))

    resolver = build_resolver(
      catalog:,
      env: {
        "AGENT_NAME" => "claude",
        "AGENT_SESSION_ID" => "codex:shared-id"
      }
    )

    assert_equal "claude:shared-id", resolver.current.uid
    assert_equal({ claude: 1 }, catalog.calls)
  end

  def test_current_requires_agent_name_when_generic_session_id_is_present
    resolver = build_resolver(
      catalog: FakeCatalog.new,
      env: { "AGENT_SESSION_ID" => "claude-1" }
    )

    error = assert_raises(Agent::SessionContext::CurrentSessionUnavailable) do
      resolver.current
    end

    assert_includes error.message, "AGENT_NAME"
  end

  def test_current_rejects_unknown_agent_name
    resolver = build_resolver(
      catalog: FakeCatalog.new,
      env: {
        "AGENT_SESSION_ID" => "session-1",
        "AGENT_NAME" => "cursor"
      }
    )

    error = assert_raises(Agent::SessionContext::UnsupportedAgent) do
      resolver.current
    end

    assert_includes error.message, "AGENT_NAME"
    assert_includes error.message, "cursor"
  end

  def test_current_prefers_codex_session_id_over_thread_id
    catalog = FakeCatalog.new
                         .add(:codex) do |_env|
                           [
                             session(:codex, id: "thread-id"),
                             session(:codex, id: "session-id")
                           ]
                         end

    resolver = build_resolver(
      catalog:,
      env: {
        "CODEX_SESSION_ID" => "session-id",
        "CODEX_THREAD_ID" => "thread-id"
      }
    )

    assert_equal "codex:session-id", resolver.current.uid
  end

  def test_current_resolves_claude_session_from_claude_variable
    catalog = FakeCatalog.new
                         .add(:claude, session(:claude, id: "claude-1"))
                         .add(:codex, session(:codex, id: "codex-1"))

    resolver = build_resolver(
      catalog:,
      env: { "CLAUDE_CODE_SESSION_ID" => "claude-1" }
    )

    assert_equal "claude:claude-1", resolver.current.uid
    assert_equal({ claude: 1 }, catalog.calls)
  end

  def test_current_resolves_codex_session_from_thread_variable
    catalog = FakeCatalog.new
                         .add(:claude, session(:claude, id: "claude-1"))
                         .add(:codex, session(:codex, id: "thread-1"))

    resolver = build_resolver(
      catalog:,
      env: { "CODEX_THREAD_ID" => "thread-1" }
    )

    assert_equal "codex:thread-1", resolver.current.uid
    assert_equal({ codex: 1 }, catalog.calls)
  end

  def test_current_rejects_conflicting_claude_and_codex_identifiers
    %w[CODEX_SESSION_ID CODEX_THREAD_ID].each do |codex_key|
      resolver = build_resolver(
        catalog: FakeCatalog.new,
        env: {
          "CLAUDE_CODE_SESSION_ID" => "claude-1",
          codex_key => "codex-1"
        }
      )

      error = assert_raises(Agent::SessionContext::CurrentSessionUnavailable) do
        resolver.current
      end

      assert_includes error.message, "CLAUDE_CODE_SESSION_ID"
      assert_includes error.message, codex_key
    end
  end

  def test_current_raises_session_not_found_when_selected_identifier_is_absent_on_disk
    [
      {
        env: { "AGENT_SESSION_ID" => "missing", "AGENT_NAME" => "claude" },
        calls: { claude: 1 }
      },
      {
        env: { "CLAUDE_CODE_SESSION_ID" => "missing" },
        calls: { claude: 1 }
      },
      {
        env: { "CODEX_SESSION_ID" => "missing" },
        calls: { codex: 1 }
      },
      {
        env: { "CODEX_THREAD_ID" => "missing" },
        calls: { codex: 1 }
      }
    ].each do |scenario|
      catalog = FakeCatalog.new
                           .add(:claude, session(:claude, id: "available"))
                           .add(:codex, session(:codex, id: "available"))
      resolver = build_resolver(catalog:, env: scenario[:env])

      error = assert_raises(Agent::SessionContext::SessionNotFound) do
        resolver.current
      end

      assert_includes error.message, "missing"
      assert_equal scenario[:calls], catalog.calls
    end
  end

  def test_current_raises_when_no_identifiers_are_present
    resolver = build_resolver(catalog: FakeCatalog.new, env: {})

    error = assert_raises(Agent::SessionContext::CurrentSessionUnavailable) do
      resolver.current
    end

    assert_includes error.message, "AGENT_SESSION_ID"
    assert_includes error.message, "CLAUDE_CODE_SESSION_ID"
    assert_includes error.message, "CODEX_SESSION_ID"
  end

  def test_current_falls_back_to_the_latest_session_across_agents_and_yields_it
    catalog = FakeCatalog.new
                         .add(:claude, session(:claude, id: "older", updated_at: Time.utc(2026, 1, 1)))
                         .add(:codex, session(:codex, id: "newer", updated_at: Time.utc(2026, 1, 2)))
    resolver = build_resolver(catalog:, env: {})
    yielded = []

    current = resolver.current { |selected| yielded << selected }

    assert_equal "codex:newer", current.uid
    assert_equal [current], yielded
    assert_equal({ claude: 1, codex: 1 }, catalog.calls)
  end

  def test_current_environment_identity_beats_newer_disk_session_without_yielding
    catalog = FakeCatalog.new
                         .add(:claude, session(:claude, id: "environment", updated_at: Time.utc(2026, 1, 1)))
                         .add(:codex, session(:codex, id: "newer", updated_at: Time.utc(2026, 1, 2)))
    resolver = build_resolver(catalog:, env: { "CLAUDE_CODE_SESSION_ID" => "environment" })

    assert_equal "claude:environment", resolver.current(agent: :codex) {
      flunk "environment resolution must not yield"
    }.uid
    assert_equal({ claude: 1 }, catalog.calls)
  end

  def test_current_agent_restriction_searches_only_the_selected_catalog
    catalog = FakeCatalog.new
                         .add(:claude, session(:claude, id: "claude", updated_at: Time.utc(2026, 1, 1)))
                         .add(:codex, session(:codex, id: "codex", updated_at: Time.utc(2026, 1, 2)))
    resolver = build_resolver(catalog:, env: {})

    assert_equal "claude:claude", resolver.current(agent: :claude).uid
    assert_equal({ claude: 1 }, catalog.calls)
  end

  def test_current_without_environment_or_sessions_names_the_searched_scope
    resolver = build_resolver(catalog: FakeCatalog.new, env: {})

    error = assert_raises(Agent::SessionContext::CurrentSessionUnavailable) do
      resolver.current
    end

    assert_includes error.message, "claude or codex"
  end

  def test_current_with_an_agent_restriction_names_and_searches_only_that_agent_when_empty
    catalog = FakeCatalog.new
                         .add(:claude, session(:claude, id: "available"))
    resolver = build_resolver(catalog:, env: {})

    error = assert_raises(Agent::SessionContext::CurrentSessionUnavailable) do
      resolver.current(agent: :codex)
    end

    assert_includes error.message, "codex"
    assert_equal({ codex: 1 }, catalog.calls)
  end

  def test_current_rejects_ties_for_the_latest_disk_session
    timestamp = Time.utc(2026, 6, 7, 8, 9, 10) + Rational(123_456_789, 1_000_000_000)
    catalog = FakeCatalog.new
                         .add(:claude, session(:claude, id: "first", uid: "z-last", updated_at: timestamp))
                         .add(:codex, session(:codex, id: "second", uid: "a-first", updated_at: timestamp))
    resolver = build_resolver(catalog:, env: {})

    error = assert_raises(Agent::SessionContext::AmbiguousSession) do
      resolver.current
    end

    assert_includes error.message, timestamp.iso8601(9)
    assert_includes error.message, "a-first, z-last"
    assert_includes error.message, "Pass an explicit SESSION."
  end

  private

  def build_resolver(catalog:, env: {})
    Agent::SessionContext::SessionResolver.new(catalog:, env:)
  end

  def session(agent, id:, uid: nil, updated_at: Time.utc(2026, 1, 1))
    FakeCatalog::Session.new(
      agent: agent.to_sym,
      id: id.to_s,
      uid: uid || "#{agent}:#{id}",
      updated_at:
    )
  end
end
