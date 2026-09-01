# frozen_string_literal: true

require "test_helper"

class ReadmeContractTest < Minitest::Test
  README_PATH = File.expand_path("../README.md", __dir__)
  ARCHITECTURE_FLOW = "resolve -> capture -> extract/collect -> optionally summarize -> build snapshot -> render"

  def test_readme_documents_supported_public_api_and_internal_boundaries
    readme = File.read(README_PATH)
    public_api = section(readme, "### Supported Public Ruby API", "## Options")
    internal_architecture = section(readme, "### Internal Architecture", "## Options")

    assert_includes readme, "### Supported Public Ruby API"
    assert_includes public_api, "Agent::SessionContext.resolve"
    assert_includes public_api, "Agent::SessionContext.current"
    assert_includes public_api, "Agent::Sessions::Session"
    assert_includes public_api, "Agent::SessionContext.show"
    assert_includes public_api, "Agent::SessionContext::Snapshot"
    assert_includes public_api, "Agent::SessionContext.prompts"
    assert_includes public_api, "Agent::SessionContext::Prompt"
    assert_includes public_api, "Agent::SessionContext.summarize"
    assert_includes public_api, "Agent::SessionContext::InjectedContext"
    assert_includes public_api, "Agent::SessionContext::Item"
    assert_includes public_api, "Agent::SessionContext::SourceRef"
    assert_includes public_api, "Agent::SessionContext::VERSION"
    assert_includes public_api, "Agent::SessionContext::CLI::FORMATS"
    assert_includes public_api, "[Errors](#errors)"
    assert_includes public_api, "compatibility contract"
    assert_includes internal_architecture, ARCHITECTURE_FLOW
    assert_includes internal_architecture, "`show`"
    assert_includes internal_architecture, "`include_injected`"
    assert_includes internal_architecture, "`summarize`"
    assert_includes internal_architecture, "tool-result bodies"
    assert_includes internal_architecture, "internal details"
    assert_includes internal_architecture, "without compatibility guarantees"
  end

  def test_readme_links_to_the_current_repository
    readme = File.read(README_PATH)

    assert_includes readme, "https://github.com/lucianghinda/agent-session-context"
    refute_includes readme, "https://github.com/lucianghinda/agent_context"
  end

  private

  def section(readme, heading, next_heading)
    start_index = readme.index(heading)
    refute_nil start_index, "expected README to include #{heading.inspect}"

    end_index = readme.index(next_heading, start_index)
    refute_nil end_index, "expected README to include #{next_heading.inspect} after #{heading.inspect}"

    readme[start_index...end_index]
  end
end
