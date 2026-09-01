# frozen_string_literal: true

require "test_helper"

class CLIOptionsTest < Minitest::Test
  def test_cli_formats_constant_remains_public
    assert_equal %w[text markdown json jsonl], Agent::SessionContext::CLI::FORMATS
  end

  def test_parse_returns_a_frozen_selection_without_mutating_arguments
    arguments = ["session-1", "--format=json", "--include-injected"]

    selection = Agent::SessionContext::CLI::Options.parse(arguments, command: :show)

    assert_equal(
      {
        current: false,
        agent: nil,
        format: :json,
        using: :auto,
        timeout: nil,
        include_injected: true,
        identifier: "session-1"
      },
      selection
    )
    assert_predicate selection, :frozen?
    assert_equal ["session-1", "--format=json", "--include-injected"], arguments
  end
end
