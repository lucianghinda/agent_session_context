# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

# Synthetic Codex records, resolved through the real session reader.
module CodexFixtures
  CODEX_STAMP = "2026-09-10T09:12:03.000Z"
  CODEX_SESSION = "cccccccc-bbbb-4ccc-8ddd-eeeeeeeeeeee"

  def with_codex_session(records, **options)
    Dir.mktmpdir("agent_session_context_codex") do |home|
      path = File.join(home, ".codex", "sessions", "2026", "09", "10",
                       "rollout-2026-09-10T09-12-03-#{CODEX_SESSION}.jsonl")
      metadata = { type: "session_meta", timestamp: CODEX_STAMP,
                   payload: { id: CODEX_SESSION, cwd: "/Users/you/app", cli_version: "0.0.0" } }
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "#{([metadata] + records).map { |record| JSON.generate(record) }.join("\n")}\n")
      session = Agent::Sessions.sessions(:codex, env: { "HOME" => home }).first
      yield Agent::Sessions.read(session, **options)
    end
  end

  def codex_record(payload)
    { type: "response_item", timestamp: CODEX_STAMP, payload: payload }
  end

  def codex_message(text, phase: nil, role: "assistant")
    payload = { type: "message", role: role, content: [{ type: "output_text", text: text }] }
    payload[:phase] = phase if phase
    codex_record(payload)
  end

  def codex_reasoning(summary: [])
    codex_record({ type: "reasoning", summary: summary, encrypted_content: "synthetic-encrypted-content" })
  end

  def codex_tool_call(call_id: "call_1")
    codex_record({ type: "function_call", name: "exec_command", call_id: call_id, arguments: "{}" })
  end

  def codex_tool_result(call_id: "call_1")
    codex_record({ type: "function_call_output", call_id: call_id, output: "synthetic result" })
  end

  def codex_token_usage
    { type: "token_usage_record", timestamp: CODEX_STAMP,
      payload: { thread_token_usage: { input_tokens: 100, cached_input_tokens: 40, output_tokens: 5 } } }
  end
end
