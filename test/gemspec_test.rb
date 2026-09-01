# frozen_string_literal: true

require "test_helper"
require "bundler"

class GemspecTest < Minitest::Test
  def test_files_are_packaged_without_git
    Dir.mktmpdir("agent-context-gemspec") do |dir|
      copy_for_gemspec_test(dir)
      spec = load_gemspec(dir)
      expected_files = packaged_fixture_files

      assert_equal "agent-session_context", spec.fetch("name")
      assert_equal ["agent-session-context"], spec.fetch("executables")
      assert_equal "https://github.com/lucianghinda/agent-session-context", spec.fetch("homepage")
      assert_equal ">= 3.2.0", spec.fetch("required_ruby_version").to_s
      assert_equal({
                     "bug_tracker_uri" => "https://github.com/lucianghinda/agent-session-context/issues",
                     "changelog_uri" => "https://github.com/lucianghinda/agent-session-context/blob/main/CHANGELOG.md",
                     "rubygems_mfa_required" => "true",
                     "source_code_uri" => "https://github.com/lucianghinda/agent-session-context"
                   }, spec.fetch("metadata"))
      assert_equal expected_files, spec.fetch("files")
      assert_equal %w[agent_sessions zeitwerk], spec.fetch("runtime_dependencies").map { |dep|
        dep.fetch("name")
      }.sort
      refute_includes spec.fetch("files"), "Gemfile"
      refute_includes spec.fetch("files"), "test/load_test.rb"
    end
  end

  def test_standalone_checkout_does_not_select_a_nonexistent_agent_sessions_path
    with_bundle_fixture_checkout do |dir|
      dependencies = gemfile_dependencies(dir)

      refute(dependencies.any? do |dependency|
        dependency.name == "agent_sessions" && dependency.source.is_a?(Bundler::Source::Path)
      end)
    end
  end

  def test_checkout_with_sibling_agent_sessions_prefers_the_local_path_override
    with_bundle_fixture_checkout(with_sibling_agent_sessions: true) do |dir|
      dependency = gemfile_dependency(dir, "agent_sessions")

      assert_instance_of Bundler::Source::Path, dependency.source
      assert_equal File.realpath(File.expand_path("../../../agent_sessions/gems/agent_sessions", dir)),
                   File.realpath(dependency.source.path.to_s)
    end
  end

  def test_gemfile_dependencies_is_warning_clean_and_restores_verbose
    with_bundle_fixture_checkout do |dir|
      previous_verbose = $VERBOSE
      $VERBOSE = true

      stdout, stderr = capture_io do
        gemfile_dependencies(dir)
      end

      assert_equal "", stdout
      assert_equal "", stderr
      assert_equal true, $VERBOSE
    ensure
      $VERBOSE = previous_verbose
    end
  end

  private

  def copy_for_gemspec_test(destination)
    (packaged_fixture_files + %w[Gemfile agent-session_context.gemspec test/load_test.rb]).uniq.each do |relative_path|
      source = File.expand_path("../#{relative_path}", __dir__)
      target = File.join(destination, relative_path)
      FileUtils.mkdir_p(File.dirname(target))
      FileUtils.cp(source, target)
    end
  end

  def with_bundle_fixture_checkout(with_sibling_agent_sessions: false)
    Dir.mktmpdir("agent-context-bundle") do |dir|
      checkout = File.join(dir, "sandbox", "lane", "agent_context")
      FileUtils.mkdir_p(checkout)
      copy_for_gemspec_test(checkout)
      if with_sibling_agent_sessions
        sibling = File.expand_path("../../../agent_sessions/gems/agent_sessions", checkout)
        FileUtils.mkdir_p(sibling)
      end

      yield checkout
    end
  end

  def packaged_fixture_files
    @packaged_fixture_files ||= Dir.chdir(File.expand_path("..", __dir__)) do
      (%w[CHANGELOG.md LICENSE.txt README.md] +
        Dir.glob("{lib,exe}/**/*").select { |path| File.file?(path) }).sort
    end
  end

  def gemfile_dependency(directory, name)
    dependency = gemfile_dependencies(directory).find { |candidate| candidate.name == name }
    refute_nil dependency
    dependency
  end

  def gemfile_dependencies(directory)
    previous_pwd = Dir.pwd
    previous_verbose = $VERBOSE

    Dir.chdir(directory) do
      $VERBOSE = nil
      Bundler::Dsl.evaluate("Gemfile", nil, {}).dependencies
    end
  ensure
    $VERBOSE = previous_verbose
    Dir.chdir(previous_pwd)
  end

  def load_gemspec(directory)
    previous_verbose = $VERBOSE
    $VERBOSE = nil

    Dir.chdir(directory) do
      spec = Gem::Specification.load("agent-session_context.gemspec")
      refute_nil spec

      {
        "name" => spec.name,
        "executables" => spec.executables,
        "files" => spec.files,
        "homepage" => spec.homepage,
        "required_ruby_version" => spec.required_ruby_version,
        "metadata" => spec.metadata,
        "runtime_dependencies" => spec.runtime_dependencies.map { |dep| { "name" => dep.name } }
      }
    end
  ensure
    $VERBOSE = previous_verbose
  end
end
