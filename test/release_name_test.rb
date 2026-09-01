# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"
require "rubygems"

class ReleaseNameTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  LIB = File.join(ROOT, "lib")

  def test_new_entrypoint_loads_only_the_new_namespace
    script = <<~RUBY
      $LOAD_PATH.unshift #{LIB.inspect}
      require "agent/session_context"
      abort "missing Agent::SessionContext" unless defined?(Agent::SessionContext)
      abort "loaded conflicting Agent::Context" if defined?(Agent::Context)
      puts Agent::SessionContext::VERSION
    RUBY

    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-e", script)

    assert status.success?, stderr
    assert_match(/\A\d+\.\d+\.\d+\n\z/, stdout)
  end

  def test_gemspec_uses_the_new_distribution_name
    path = File.join(ROOT, "agent-session_context.gemspec")

    assert File.file?(path)
    return unless File.file?(path)

    spec = Gem::Specification.load(path)

    refute_nil spec
    assert_equal "agent-session_context", spec.name
    assert_equal ["agent-session-context"], spec.executables
  end

  def test_conflicting_legacy_entrypoints_are_absent
    assert_path_exists File.join(ROOT, "exe", "agent-session-context")
    refute_path_exists File.join(ROOT, "exe", "agent-context")
    refute_path_exists File.join(LIB, "agent_context.rb")
    refute_path_exists File.join(LIB, "agent", "context.rb")
    refute_path_exists File.join(LIB, "agent", "context")
    refute_path_exists File.join(ROOT, "agent_context.gemspec")
  end
end
