# frozen_string_literal: true

require "test_helper"
require "fileutils"

class ConfigTest < Minitest::Test
  Session = Data.define(:project_path)

  def test_default_timeout_is_five_minutes_and_config_is_frozen
    config = Agent::SessionContext::Config.load(session: Session.new(project_path: nil), env: {})

    assert_equal 300, config.timeout_seconds
    assert_predicate config, :frozen?
  end

  def test_explicit_timeout_overrides_project_and_user_files
    with_config_tree(user: 120, project: 45) do |session, env|
      config = Agent::SessionContext::Config.load(session:, env:, timeout: 15)

      assert_equal 15, config.timeout_seconds
    end
  end

  def test_project_file_overrides_user_file
    with_config_tree(user: 120, project: 45) do |session, env|
      config = Agent::SessionContext::Config.load(session:, env:)

      assert_equal 45, config.timeout_seconds
    end
  end

  def test_user_file_is_used_when_project_file_is_missing
    with_config_tree(user: 120, project: :missing) do |session, env|
      config = Agent::SessionContext::Config.load(session:, env:)

      assert_equal 120, config.timeout_seconds
    end
  end

  def test_project_layer_without_timeout_is_treated_as_absent
    with_config_tree(user: 120, project: "summarize: {}\n") do |session, env|
      config = Agent::SessionContext::Config.load(session:, env:)

      assert_equal 120, config.timeout_seconds
    end
  end

  def test_existing_lower_priority_file_is_validated_even_when_explicit_timeout_wins
    invalid_document = "summarize:\n  timeout_seconds: false\n"

    error = assert_raises(Agent::SessionContext::ConfigurationError) do
      with_config_tree(user: invalid_document, project: 45) do |session, env|
        Agent::SessionContext::Config.load(session:, env:, timeout: 15)
      end
    end

    assert_includes error.message, "user configuration"
    assert_includes error.message, "config.yml"
    refute_includes error.message, invalid_document
  end

  def test_accepts_boundary_values_and_retains_float_timeout
    with_config_tree(project: 1) do |session, env|
      assert_equal 1, Agent::SessionContext::Config.load(session:, env:).timeout_seconds
    end

    with_config_tree(project: 3600) do |session, env|
      assert_equal 3600, Agent::SessionContext::Config.load(session:, env:).timeout_seconds
    end

    with_config_tree(project: 1.5) do |session, env|
      config = Agent::SessionContext::Config.load(session:, env:)

      assert_equal 1.5, config.timeout_seconds
      assert_instance_of Float, config.timeout_seconds
    end
  end

  def test_rejects_values_outside_bounds
    [0, 3601].each do |value|
      error = assert_raises(Agent::SessionContext::ConfigurationError) do
        with_config_tree(project: value) do |session, env|
          Agent::SessionContext::Config.load(session:, env:)
        end
      end

      assert_includes error.message, "project configuration"
    end
  end

  def test_rejects_explicit_false_timeout
    error = assert_raises(Agent::SessionContext::ConfigurationError) do
      Agent::SessionContext::Config.load(session: Session.new(project_path: nil), env: {}, timeout: false)
    end

    assert_includes error.message, "timeout"
  end

  def test_rejects_explicit_complex_timeout
    error = assert_raises(Agent::SessionContext::ConfigurationError) do
      Agent::SessionContext::Config.load(session: Session.new(project_path: nil), env: {}, timeout: Complex(1, 1))
    end

    assert_includes error.message, "timeout"
  end

  def test_rejects_explicit_rational_timeout
    error = assert_raises(Agent::SessionContext::ConfigurationError) do
      Agent::SessionContext::Config.load(session: Session.new(project_path: nil), env: {}, timeout: Rational(3, 2))
    end

    assert_includes error.message, "timeout"
  end

  def test_nil_and_empty_documents_and_layers_are_absent
    [nil, "", "---\n", "{}\n", "summarize: {}\n"].each do |document|
      with_config_tree(user: 120, project: document) do |session, env|
        config = Agent::SessionContext::Config.load(session:, env:)

        assert_equal 120, config.timeout_seconds
      end
    end
  end

  def test_explicit_null_summarize_is_invalid
    error = assert_raises(Agent::SessionContext::ConfigurationError) do
      with_config_tree(project: "summarize: null\n") do |session, env|
        Agent::SessionContext::Config.load(session:, env:)
      end
    end

    assert_includes error.message, "project configuration"
    assert_includes error.message, ".agent-context.yml"
  end

  def test_explicit_null_timeout_seconds_is_invalid
    error = assert_raises(Agent::SessionContext::ConfigurationError) do
      with_config_tree(project: "summarize:\n  timeout_seconds: null\n") do |session, env|
        Agent::SessionContext::Config.load(session:, env:)
      end
    end

    assert_includes error.message, "project configuration"
    assert_includes error.message, ".agent-context.yml"
  end

  def test_rejects_unknown_keys_invalid_shapes_and_unsafe_yaml
    invalid_documents = [
      "unknown: true\n",
      "summarize: 300\n",
      "summarize:\n  unknown: 300\n",
      "summarize:\n  timeout_seconds: false\n",
      "summarize:\n  timeout_seconds: .inf\n",
      "--- &defaults\nsummarize: *defaults\n",
      "--- !ruby/object:Object {}\n"
    ]

    invalid_documents.each do |document|
      error = assert_raises(Agent::SessionContext::ConfigurationError) do
        with_config_tree(project: document) do |session, env|
          Agent::SessionContext::Config.load(session:, env:)
        end
      end

      assert_includes error.message, "project configuration"
      assert_includes error.message, ".agent-context.yml"
      refute_includes error.message, document
    end
  end

  def test_absolute_xdg_path_wins_over_home_even_when_missing
    Dir.mktmpdir do |root|
      home_dir = File.join(root, "home")
      xdg_dir = File.join(root, "xdg")
      project_dir = File.join(root, "project")
      FileUtils.mkdir_p(home_dir)
      FileUtils.mkdir_p(project_dir)
      write_config(File.join(home_dir, ".config", "agent_context", "config.yml"), 120)

      config = Agent::SessionContext::Config.load(
        session: Session.new(project_path: project_dir),
        env: { "XDG_CONFIG_HOME" => xdg_dir, "HOME" => home_dir }
      )

      assert_equal 300, config.timeout_seconds
    end
  end

  def test_relative_xdg_path_falls_back_to_absolute_home
    Dir.mktmpdir do |root|
      home_dir = File.join(root, "home")
      project_dir = File.join(root, "project")
      FileUtils.mkdir_p(home_dir)
      FileUtils.mkdir_p(project_dir)
      write_config(File.join(home_dir, ".config", "agent_context", "config.yml"), 120)

      config = Agent::SessionContext::Config.load(
        session: Session.new(project_path: project_dir),
        env: { "XDG_CONFIG_HOME" => "relative-xdg", "HOME" => home_dir }
      )

      assert_equal 120, config.timeout_seconds
    end
  end

  def test_missing_empty_or_relative_home_disables_user_layer
    [nil, "", "relative-home"].each do |home_value|
      config = Agent::SessionContext::Config.load(
        session: Session.new(project_path: nil),
        env: { "HOME" => home_value }
      )

      assert_equal 300, config.timeout_seconds
    end
  end

  def test_relative_project_path_is_ignored
    Dir.mktmpdir do |root|
      home_dir = File.join(root, "home")
      FileUtils.mkdir_p(home_dir)
      write_config(File.join(home_dir, ".config", "agent_context", "config.yml"), 120)

      config = Agent::SessionContext::Config.load(
        session: Session.new(project_path: "relative-project"),
        env: { "HOME" => home_dir }
      )

      assert_equal 120, config.timeout_seconds
    end
  end

  def test_project_path_is_independent_of_current_working_directory
    Dir.mktmpdir do |root|
      home_dir = File.join(root, "home")
      project_dir = File.join(root, "project")
      other_dir = File.join(root, "elsewhere")
      FileUtils.mkdir_p(home_dir)
      FileUtils.mkdir_p(project_dir)
      FileUtils.mkdir_p(other_dir)
      write_config(File.join(home_dir, ".config", "agent_context", "config.yml"), 120)
      write_config(File.join(project_dir, ".agent-context.yml"), 45)
      write_config(File.join(other_dir, ".agent-context.yml"), 999)

      config = Dir.chdir(other_dir) do
        Agent::SessionContext::Config.load(
          session: Session.new(project_path: project_dir),
          env: { "HOME" => home_dir }
        )
      end

      assert_equal 45, config.timeout_seconds
    end
  end

  def test_existing_config_path_must_be_a_regular_file
    Dir.mktmpdir do |root|
      project_dir = File.join(root, "project")
      config_path = File.join(project_dir, ".agent-context.yml")
      FileUtils.mkdir_p(config_path)

      error = assert_raises(Agent::SessionContext::ConfigurationError) do
        Agent::SessionContext::Config.load(
          session: Session.new(project_path: project_dir),
          env: {}
        )
      end

      assert_includes error.message, "project configuration"
      assert_includes error.message, config_path
    end
  end

  def test_symlinked_project_config_path_is_rejected_even_if_target_is_a_regular_file
    Dir.mktmpdir do |root|
      project_dir = File.join(root, "project")
      target_path = File.join(root, "target.yml")
      config_path = File.join(project_dir, ".agent-context.yml")
      FileUtils.mkdir_p(project_dir)
      write_config(target_path, 45)
      File.symlink(target_path, config_path)

      error = assert_raises(Agent::SessionContext::ConfigurationError) do
        Agent::SessionContext::Config.load(
          session: Session.new(project_path: project_dir),
          env: {}
        )
      end

      assert_includes error.message, "project configuration"
      assert_includes error.message, config_path
      refute_includes error.message, File.binread(target_path)
    end
  end

  def test_invalid_utf8_bytes_raise_configuration_error_without_leaking_content
    Dir.mktmpdir do |root|
      project_dir = File.join(root, "project")
      config_path = File.join(project_dir, ".agent-context.yml")
      FileUtils.mkdir_p(project_dir)
      invalid_bytes = "\xC3\x28".b
      File.binwrite(config_path, invalid_bytes)

      error = assert_raises(Agent::SessionContext::ConfigurationError) do
        Agent::SessionContext::Config.load(
          session: Session.new(project_path: project_dir),
          env: {}
        )
      end

      assert_includes error.message, "project configuration"
      assert_includes error.message, config_path
      refute_includes error.message, invalid_bytes.inspect
    end
  end

  def test_unreadable_project_config_read_failure_becomes_configuration_error
    Dir.mktmpdir do |root|
      project_dir = File.join(root, "project")
      config_path = File.join(project_dir, ".agent-context.yml")
      FileUtils.mkdir_p(project_dir)
      write_config(config_path, 45)
      original_open = File.method(:open)

      File.stub(:open, lambda { |path, *args, &block|
        return raise Errno::EACCES, path if path == config_path

        original_open.call(path, *args, &block)
      }) do
        error = assert_raises(Agent::SessionContext::ConfigurationError) do
          Agent::SessionContext::Config.load(
            session: Session.new(project_path: project_dir),
            env: {}
          )
        end

        assert_includes error.message, "project configuration"
        assert_includes error.message, config_path
        refute_includes error.message, "summarize"
      end
    end
  end

  def test_replaced_config_path_after_initial_lstat_becomes_configuration_error
    Dir.mktmpdir do |root|
      project_dir = File.join(root, "project")
      config_path = File.join(project_dir, ".agent-context.yml")
      replaced_path = File.join(root, "replacement.yml")
      original_path = File.join(root, "original.yml")
      FileUtils.mkdir_p(project_dir)
      write_config(config_path, 45)
      write_config(replaced_path, 60)
      original_lstat = File.method(:lstat)
      swapped = false

      File.stub(:lstat, lambda { |path|
        stat = original_lstat.call(path)

        if path == config_path && !swapped
          FileUtils.mv(config_path, original_path)
          FileUtils.cp(replaced_path, config_path)
          swapped = true
        end

        stat
      }) do
        error = assert_raises(Agent::SessionContext::ConfigurationError) do
          Agent::SessionContext::Config.load(
            session: Session.new(project_path: project_dir),
            env: {}
          )
        end

        assert_includes error.message, "project configuration"
        assert_includes error.message, config_path
      end
    end
  end

  private

  def with_config_tree(user: :missing, project: :missing)
    Dir.mktmpdir do |root|
      home_dir = File.join(root, "home")
      project_dir = File.join(root, "project")
      FileUtils.mkdir_p(home_dir)
      FileUtils.mkdir_p(project_dir)

      user_path = File.join(home_dir, ".config", "agent_context", "config.yml")
      project_path = File.join(project_dir, ".agent-context.yml")

      write_layer(user_path, user)
      write_layer(project_path, project)

      yield Session.new(project_path: project_dir), { "HOME" => home_dir }
    end
  end

  def write_layer(path, value)
    return if value == :missing

    content =
      if value.nil?
        "null\n"
      elsif value.is_a?(Numeric)
        "summarize:\n  timeout_seconds: #{value}\n"
      else
        value
      end

    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
  end

  def write_config(path, timeout)
    write_layer(path, timeout)
  end
end
