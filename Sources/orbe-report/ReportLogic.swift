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
