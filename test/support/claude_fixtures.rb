# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

# Writes throwaway Claude Code JSONL into a fake HOME and reads it back
# through agent_sessions, exactly as loop_test.rb and loop_view_test.rb both
# need. Shared here so the two files do not carry two copies of the same
# fixture plumbing.
module ClaudeFixtures
  STAMP = "2026-08-04T13:55:06.852Z"
  SESSION = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
  PROJECT = "-Users-you-app"

  # Yields a throwaway HOME and an env hash pointing at it.
  def with_home
    Dir.mktmpdir("agent_session_context") do |home|
      yield home, { "HOME" => home }
    end
  end

  def write(content, *segments)
    path = File.join(*segments)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def turn(role, content)
    { type: role, timestamp: STAMP, sessionId: SESSION, uuid: "u1", cwd: "/Users/you/app",
      isSidechain: false, message: { role: role, content: content } }
  end

  def user_turn(text) = turn("user", [{ type: "text", text: text }])
  def assistant_turn(text) = turn("assistant", [{ type: "text", text: text }])
  def user_parts(parts) = turn("user", parts)
  def assistant_parts(parts) = turn("assistant", parts)

  def write_transcript(home, records)
    content = "#{records.map { |r| JSON.generate(r) }.join("\n")}\n"
    write(content, home, ".claude", "projects", PROJECT, "#{SESSION}.jsonl")
  end

  def read_session(env, **)
    Agent::Sessions.read(Agent::Sessions.sessions(:claude, env: env).first, **)
  end

  def with_session(records, **options)
    with_home do |home, env|
      write_transcript(home, records)
      yield read_session(env, **options)
    end
  end
end
