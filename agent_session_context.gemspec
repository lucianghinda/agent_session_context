# frozen_string_literal: true

require_relative "lib/agent/session_context/version"

repository_uri = "https://github.com/lucianghinda/agent_session_context"

Gem::Specification.new do |spec|
  spec.name = "agent_session_context"
  spec.version = Agent::SessionContext::VERSION
  spec.authors = ["Lucian Ghinda"]
  spec.email = ["dev@ghinda.com"]
  spec.summary = "Inspect and summarize recorded AI agent session context"
  spec.description = "Shows exact prompts and evidence-backed context summaries for Claude Code and Codex CLI sessions."
  spec.homepage = repository_uri
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"
  spec.metadata["bug_tracker_uri"] = "#{repository_uri}/issues"
  spec.metadata["changelog_uri"] = "#{repository_uri}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["source_code_uri"] = repository_uri
  spec.files = Dir.chdir(__dir__) do
    (%w[CHANGELOG.md LICENSE.txt README.md] +
      Dir.glob("{lib,exe}/**/*").select { |path| File.file?(path) }).sort
  end
  spec.bindir = "exe"
  spec.executables = ["agent-session-context"]
  spec.require_paths = ["lib"]
  spec.add_dependency "agent_sessions", "~> 0.4"
  spec.add_dependency "zeitwerk", "~> 2.8"
end
