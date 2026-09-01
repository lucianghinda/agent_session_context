# frozen_string_literal: true

require "pathname"
require "psych"

module Agent
  module SessionContext
    class Config < Data.define(:timeout_seconds)
      DEFAULT_TIMEOUT_SECONDS = 300
      MIN_TIMEOUT_SECONDS = 1
      MAX_TIMEOUT_SECONDS = 3600
      ABSENT = Object.new.freeze
      PROJECT_CONFIG_FILENAME = ".agent-context.yml"
      USER_CONFIG_PATH_SEGMENTS = [".config", "agent_context", "config.yml"].freeze
      private_constant :ABSENT, :PROJECT_CONFIG_FILENAME, :USER_CONFIG_PATH_SEGMENTS

      class << self
        def load(session:, env: ENV, timeout: nil)
          project_timeout = load_layer(project_source(session))
          user_timeout = load_layer(user_source(env))

          effective_timeout =
            if timeout.nil?
              if project_timeout.nil?
                user_timeout.nil? ? DEFAULT_TIMEOUT_SECONDS : user_timeout
              else
                project_timeout
              end
            else
              validate_timeout!(timeout, source: "timeout")
            end

          new(timeout_seconds: effective_timeout)
        end

        private

        def load_layer(source)
          return nil unless source

          path = source.fetch(:path)
          stat = stat_config_path(path, source)
          return nil unless stat

          raise_configuration_error(source, "must be a regular file") unless stat.file?

          content = read_utf8(path, stat, source)
          raw = parse_yaml(content, source)
          timeout = extract_timeout(raw, source)

          return nil if timeout.equal?(ABSENT)

          validate_timeout!(timeout, source: source.fetch(:label), path:)
        rescue ConfigurationError
          raise
        rescue Psych::Exception
          raise_configuration_error(source, "contains invalid YAML")
        rescue SystemCallError
          raise_configuration_error(source, "could not be read")
        rescue ArgumentError
          raise_configuration_error(source, "contains invalid encoding")
        end

        def stat_config_path(path, source)
          File.lstat(path)
        rescue Errno::ENOENT, Errno::ENOTDIR
          nil
        rescue SystemCallError
          raise_configuration_error(source, "could not be read")
        end

        def project_source(session)
          project_path = normalize_absolute_path(session.project_path)
          return nil unless project_path

          {
            label: "project configuration",
            path: File.join(project_path, PROJECT_CONFIG_FILENAME)
          }
        end

        def user_source(env)
          xdg_config_home = normalize_absolute_path(env["XDG_CONFIG_HOME"])
          if xdg_config_home
            return {
              label: "user configuration",
              path: File.join(xdg_config_home, "agent_context", "config.yml")
            }
          end

          home = normalize_absolute_path(env["HOME"])
          return nil unless home

          {
            label: "user configuration",
            path: File.join(home, *USER_CONFIG_PATH_SEGMENTS)
          }
        end

        def normalize_absolute_path(value)
          return nil unless value.respond_to?(:to_str)

          path = value.to_str
          return nil if path.empty?
          return path if Pathname.new(path).absolute?

          nil
        end

        def read_utf8(path, initial_stat, source)
          open_config_file(path, source) do |file|
            descriptor_stat = file.stat
            raise_configuration_error(source, "must be a regular file") unless descriptor_stat.file?
            ensure_same_identity!(initial_stat, descriptor_stat, source)

            content = file.read
            content = content.dup.force_encoding(Encoding::UTF_8)
            raise_configuration_error(source, "contains invalid encoding") unless content.valid_encoding?

            content
          end
        end

        def parse_yaml(content, source)
          return nil if content.empty?

          Psych.safe_load(
            content,
            permitted_classes: [],
            permitted_symbols: [],
            aliases: false
          )
        rescue Psych::Exception
          raise_configuration_error(source, "contains invalid YAML")
        end

        def extract_timeout(raw, source)
          return ABSENT if raw.nil?
          return ABSENT if raw == {}

          raise_configuration_error(source, "must be a mapping") unless raw.is_a?(Hash)

          unknown_keys = raw.keys - ["summarize"]
          raise_configuration_error(source, "contains unsupported settings") unless unknown_keys.empty?

          summarize = raw.fetch("summarize")
          raise_configuration_error(source, "summarize must be a mapping") unless summarize.is_a?(Hash)
          return ABSENT if summarize.empty?

          unknown_summarize_keys = summarize.keys - ["timeout_seconds"]
          unless unknown_summarize_keys.empty?
            raise_configuration_error(source,
                                      "contains unsupported summarize settings")
          end

          return ABSENT unless summarize.key?("timeout_seconds")

          summarize.fetch("timeout_seconds")
        end

        def validate_timeout!(value, source:, path: nil)
          unless value.is_a?(Integer) || value.is_a?(Float)
            raise_configuration_error({ label: source, path: },
                                      "timeout_seconds must be an Integer or Float between " \
                                      "#{MIN_TIMEOUT_SECONDS} and #{MAX_TIMEOUT_SECONDS}")
          end

          unless value.finite? &&
                 value >= MIN_TIMEOUT_SECONDS && value <= MAX_TIMEOUT_SECONDS
            raise_configuration_error({ label: source, path: },
                                      "timeout_seconds must be a finite number between " \
                                      "#{MIN_TIMEOUT_SECONDS} and #{MAX_TIMEOUT_SECONDS}")
          end

          value
        end

        def open_config_file(path, source)
          flags = File::RDONLY
          flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)

          File.open(path, flags) do |file|
            file.binmode
            yield file
          end
        rescue SystemCallError, IOError
          raise_configuration_error(source, "could not be read")
        end

        def ensure_same_identity!(initial_stat, descriptor_stat, source)
          return if initial_stat.dev == descriptor_stat.dev && initial_stat.ino == descriptor_stat.ino

          raise_configuration_error(source, "changed while being read")
        end

        def raise_configuration_error(source, reason)
          label = source.fetch(:label)
          path = source[:path]
          location = path ? " at #{path}" : ""

          raise ConfigurationError, "Invalid #{label}#{location}: #{reason}."
        end
      end
    end
  end
end
