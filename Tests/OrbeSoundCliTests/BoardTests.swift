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

  /// カタログ面は 1 行 = 1 案で、行見出しの案名の直後に列見出しと同じ順でイベントが並ぶ。
  /// ここが崩れても board は「それらしい」見た目のまま別の音を並べるので、人間は取り違えたまま
  /// 採否を決める——名前が全部載っているかだけでは捕まらない。
  func testCatalogRowsPairEachFamilysEventsInOrder() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-sound-board-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let html = try String(
      contentsOf: generateBoard(to: dir, rate: 8000, volume: 70), encoding: .utf8)

    var expected: [String] = []
    for family in NotificationSound.allCases {
      expected.append(family.rawValue)
      expected += AgentSoundEvent.allCases.map { "\(family.rawValue)/\($0.rawValue)" }
    }
    expected += Scratch.entries.map(\.name)

    XCTAssertEqual(
      try captures("class=\"fname\">([^<]*)<|data-name=\"([^\"]*)\"", in: html), expected,
      "行見出しとカードの並びが 案 → イベント順 になっていない")
    XCTAssertEqual(
      try captures("class=\"colhead\">([^<]*)<", in: html),
      AgentSoundEvent.allCases.map(\.rawValue), "列見出しがカードの並び順と食い違う")
  }

  /// 見取り図の高さは各音自身のピークで正規化する（小さい音でも上下いっぱいに開く）。
  /// 無音は 0 除算で NaN を属性へ流さず、中心線に潰れる。
  func testWavePointsNormalizeHeightAndCollapseSilence() {
    XCTAssertEqual(
      wavePoints([Float](repeating: 0.01, count: 100), buckets: 4),
      "0,1.0 1,1.0 2,1.0 3,1.0 3,31.0 2,31.0 1,31.0 0,31.0")
    XCTAssertEqual(
      wavePoints([Float](repeating: 0, count: 100), buckets: 2), "0,16.0 1,16.0 1,16.0 0,16.0")
  }

  /// 同じディレクトリへの再生成は上書きで通る（ブラウザのリロードだけで最新になる前提）。
  func testBoardRegeneratesInPlace() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-sound-board-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    _ = try generateBoard(to: dir, rate: 8000, volume: 70)
    XCTAssertNoThrow(try generateBoard(to: dir, rate: 8000, volume: 70))
  }

  /// 各マッチの最初に成立したキャプチャを、出現順に集める。
  private func captures(_ pattern: String, in text: String) throws -> [String] {
    let regex = try NSRegularExpression(pattern: pattern)
    let range = NSRange(text.startIndex..., in: text)
    return regex.matches(in: text, range: range).compactMap { match in
      (1..<match.numberOfRanges)
        .compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
        .first
    }
  }
}
