# frozen_string_literal: true

source "https://rubygems.org"

gemspec

local_agent_sessions = File.expand_path("../../../agent_sessions/gems/agent_sessions", __dir__)
gem "agent_sessions", path: local_agent_sessions if File.directory?(local_agent_sessions)
gem "irb"
gem "minitest", "~> 5.16"
gem "rake", "~> 13.0"
gem "rubocop", "~> 1.90.0", require: false
