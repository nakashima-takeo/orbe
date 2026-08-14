import XCTest

@testable import OrbeSound
@testable import orbe_sound

/// `orbe-sound board` の生成物の性質検証。ここが崩れると、聴き比べボードに音が欠けたまま
/// 人間の判定が進み、鳴らない・載らない音は作り直しの検討から静かに漏れる。
final class BoardTests: XCTestCase {

  /// 全エントリ（カタログ 24 + scratch）の WAV と、全エントリ名を含む index.html を書く。
  func testBoardWritesEveryEntryAndTheIndex() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-sound-board-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // レートは検証に十分な最低域まで下げ、テストを軽く保つ（生成経路はレートに依らない）。
    let index = try generateBoard(to: dir, rate: 8000, volume: 70)
    XCTAssertEqual(index.lastPathComponent, "index.html")

    let html = try String(contentsOf: index, encoding: .utf8)
    for family in NotificationSound.allCases {
      for event in AgentSoundEvent.allCases {
        let file = "\(family.rawValue)-\(event.rawValue).wav"
        XCTAssertTrue(
          FileManager.default.fileExists(atPath: dir.appendingPathComponent(file).path),
          "\(file) が書かれていない")
        XCTAssertTrue(html.contains(file), "index.html が \(file) を参照していない")
      }
    }
    for entry in Scratch.entries {
      XCTAssertTrue(
        FileManager.default.fileExists(
          atPath: dir.appendingPathComponent("\(entry.name).wav").path),
        "\(entry.name).wav が書かれていない")
      XCTAssertTrue(html.contains(entry.name), "index.html に \(entry.name) が載っていない")
    }
  }

  /// 同じディレクトリへの再生成は上書きで通る（ブラウザのリロードだけで最新になる前提）。
  func testBoardRegeneratesInPlace() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-sound-board-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    _ = try generateBoard(to: dir, rate: 8000, volume: 70)
    XCTAssertNoThrow(try generateBoard(to: dir, rate: 8000, volume: 70))
  }
}
