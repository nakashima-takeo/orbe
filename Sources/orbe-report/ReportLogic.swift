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

/// state == "done" かつ background_tasks に status == "running" が 1 つでもあれば "working"。
/// それ以外（欠落・空配列・キャスト失敗を含む）は state をそのまま返す（誤 working には倒れない）。
func effectiveState(_ state: String, stdin obj: [String: Any]?) -> String {
  guard state == "done",
    let tasks = obj?["background_tasks"] as? [[String: Any]],
    tasks.contains(where: { ($0["status"] as? String) == "running" })
  else { return state }
  return "working"
}

/// hook payload からユーザーへ見せる文言を抽出する（無ければ nil）。state は effectiveState 適用後
/// （done→working 読み替え後は文言なし＝working は文言を持たない）。フィールド形は実 payload 準拠:
/// - waiting: claude Notification の `message`、無ければ PreToolUse(AskUserQuestion) の
///   `tool_input.questions[0].question`（先頭の質問文）。
/// - done: Stop payload の `last_assistant_message`（claude / codex とも同名フィールドを持つ。
///   持たない CLI（agy 等）は自然に nil ＝文言なし）。
func agentMessage(state: String, stdin obj: [String: Any]?) -> String? {
  guard let obj else { return nil }
  switch state {
  case "waiting":
    if let message = truncateMessage(obj["message"] as? String) { return message }
    guard let input = obj["tool_input"] as? [String: Any],
      let questions = input["questions"] as? [[String: Any]]
    else { return nil }
    return truncateMessage(questions.first?["question"] as? String)
  case "done":
    return truncateMessage(obj["last_assistant_message"] as? String)
  default:
    return nil
  }
}

/// 文言の整形。trim して空なら nil、1000 文字で切る（表示は 3 行 clamp。制御ソケットの
/// 1 行上限〔ControlLineFramer 1MiB〕に対する防御でもあり、十分下回る）。
func truncateMessage(_ s: String?) -> String? {
  guard let trimmed = s?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
  else { return nil }
  return String(trimmed.prefix(1000))
}
