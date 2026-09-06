import Foundation
import OrbeSessionLog

/// `agent-sessions.jsonl` の Orbe プロセス内の唯一の書き手。起動時にファイルを読み、保持規則
/// （30 日・5MB）で剪定し、変化があれば原子的に書き直した結果をメモリに保つ。以後の追記はメモリと
/// ファイルの両方へ積むので、パレットと `restore_sessions` はメモリを、`session_log` はファイルを
/// 読んでも同じものが見える。書けなくてもタブ操作は止めない（NSLog のみ）。
final class AgentSessionLog {
  /// テスト用に置き場を差し替える（`TestIsolation.beginCase` が毎テスト張る）。本番は nil。
  static var fileURLOverride: URL?

  static var fileURL: URL? {
    fileURLOverride ?? StateDir.base()?.appendingPathComponent("agent-sessions.jsonl")
  }

  private(set) var events: [SessionEvent] = []

  init(now: Date = Date()) {
    guard let url = Self.fileURL else { return }
    do {
      let all = try SessionLogReader.read(url).events
      let kept = SessionLogRetention.prune(all, now: now)
      if kept.count != all.count { try SessionLogWriter.rewrite(kept, to: url) }
      events = kept
    } catch {
      NSLog("[session-log] load failed: \(error)")
    }
  }

  func record(_ event: SessionEvent) {
    events.append(event)
    guard let url = Self.fileURL else { return }
    do {
      try SessionLogWriter.append(event, to: url)
    } catch {
      NSLog("[session-log] append failed: \(error)")
    }
  }

  /// その sessionId の最後のイベント（ファイル順）。無ければ nil＝ログが知らない同一性。
  func lastEvent(sessionId: String) -> SessionEvent? {
    events.last { $0.sessionId == sessionId }
  }
}
