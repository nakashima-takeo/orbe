import Foundation

// hook stdin JSON の解釈ロジック（pure 関数）。env / stdin / socket には触らない。

/// hook stdin の JSON をパース（空・非 JSON は nil）。
func parseHookJSON(_ data: Data) -> [String: Any]? {
  guard !data.isEmpty else { return nil }
  return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

/// resume 用 ID の抽出。claude/codex は "session_id"、agy は "conversationId"。
/// env フォールバック（ANTIGRAVITY_CONVERSATION_ID）は main.swift 側。
func sessionId(from obj: [String: Any]?) -> String? {
  guard let obj else { return nil }
  if let sid = obj["session_id"] as? String, !sid.isEmpty { return sid }
  if let cid = obj["conversationId"] as? String, !cid.isEmpty { return cid }
  return nil
}

/// サブエージェント実行中の hook payload か（`agent_id` はサブエージェントのときだけ入る）。
/// サブエージェントの活動はタブのセッション状態ではないので報告しない。
/// 見るのは `agent_id` だけ——`agent_type` は `--agent` で起動した本体スレッドにも入るため、
/// そちらで判定すると本体の報告まで丸ごと落ちる。
func isSubagentReport(_ obj: [String: Any]?) -> Bool {
  guard let id = obj?["agent_id"] as? String else { return false }
  return !id.isEmpty
}

/// state == "done" かつ background_tasks に status == "running" が 1 つでもあれば "working"。
/// それ以外（欠落・空配列・キャスト失敗を含む）は state をそのまま返す（誤 working には倒れない）。
func effectiveState(_ state: String, stdin obj: [String: Any]?) -> String {
  guard state == "done",
    let tasks = obj?["background_tasks"] as? [[String: Any]],
    tasks.contains(where: { ($0["status"] as? String) == "running" })
  else { return state }
  return "working"
}

/// hook payload からユーザーへ見せる文言と、その出所を取り出す（無ければ nil）。state は
/// effectiveState 適用後（done→working 読み替え後は文言なし＝working は文言を持たない）。
/// 出所は**どのフィールドから取ったか**そのもの。フィールド形は実 payload 準拠:
/// - waiting: claude Notification の `message`（出所 `notification`）、無ければ
///   PreToolUse(AskUserQuestion) の `tool_input.questions[0].question`（先頭の質問文・出所 `tool`）。
/// - done: Stop payload の `last_assistant_message`（出所 `tool`。claude / codex とも同名フィールドを
///   持つ。持たない CLI（agy 等）は自然に nil ＝文言なし）。
func agentMessage(state: String, stdin obj: [String: Any]?) -> (text: String, source: String)? {
  guard let obj else { return nil }
  switch state {
  case "waiting":
    if let message = truncateMessage(obj["message"] as? String) {
      return (message, "notification")
    }
    guard let input = obj["tool_input"] as? [String: Any],
      let questions = input["questions"] as? [[String: Any]],
      let question = truncateMessage(questions.first?["question"] as? String)
    else { return nil }
    return (question, "tool")
  case "done":
    return truncateMessage(obj["last_assistant_message"] as? String).map { ($0, "tool") }
  default:
    return nil
  }
}

/// セッション終了の理由。Claude Code の SessionEnd hook が stdin JSON の `reason`（`clear` / `logout` /
/// `prompt_input_exit` / `other`）で運ぶ。他の hook・他の CLI は持たないので自然に nil。文言と同じ
/// 無害化を通す——Orbe はこれをセッションログに書き、`orb session log` が端末へ流すため。
func endReason(from obj: [String: Any]?) -> String? {
  truncateMessage(obj?["reason"] as? String)
}

/// 文言の整形。C0 制御文字（改行・タブ以外）を落とし、trim して空なら nil、1000 文字で切る（表示は
/// 3 行 clamp。制御ソケットの 1 行上限〔ControlLineFramer 1MiB〕に対する防御でもあり、十分下回る）。
/// 制御文字を落とすのは、文言がエージェント（＝untrusted な入力を読む LLM）の生成文で、`orb agent
/// prompt` の stdout として操作者の端末へ生で流れるため——ESC 列が端末に解釈されると行の上書きに
/// よる出力の偽装や OSC の副作用が成立する。正当な応答が制御文字を要する場面は無い。
func truncateMessage(_ s: String?) -> String? {
  guard let s else { return nil }
  let printable = s.unicodeScalars.filter { $0.value >= 0x20 || $0 == "\n" || $0 == "\t" }
  let trimmed = String(String.UnicodeScalarView(printable))
    .trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return nil }
  return String(trimmed.prefix(1000))
}
