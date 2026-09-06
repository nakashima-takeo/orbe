import Foundation
import XCTest

@testable import OrbeSessionLog

/// L1 の素材。時刻は基準からの秒で組み、同一性は sessionId だけ変える。
enum Fixture {
  static let base = Date(timeIntervalSince1970: 1_800_000_000)

  static func opened(_ id: String, at seconds: TimeInterval, rootPath: String = "/repo")
    -> SessionEvent
  {
    SessionEvent(
      ts: base.addingTimeInterval(seconds), kind: .opened,
      workspace: .init(name: "ws", rootPath: rootPath), cwd: rootPath + "/src",
      agent: .init(command: "claude", sessionId: id))
  }

  static func closed(
    _ id: String, at seconds: TimeInterval, origin: SessionEvent.CloseOrigin = .process,
    reason: String? = nil, rootPath: String = "/repo"
  ) -> SessionEvent {
    SessionEvent(
      ts: base.addingTimeInterval(seconds), kind: .closed(origin: origin, reason: reason),
      workspace: .init(name: "ws", rootPath: rootPath), cwd: rootPath + "/src",
      agent: .init(command: "claude", sessionId: id))
  }

  static func tempFile(_ name: String = "agent-sessions.jsonl") throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("orbe-sessionlog-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent(name)
  }
}
