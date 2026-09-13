import XCTest

@testable import Orbe

/// デバウンスの境界を実時間ゼロで測る——後追い 200ms、最初の保留から 1s の上限、取り出した後は空。
/// 壊れると外部変更の通知が遅れる・ビルド中に一切出ない・同じ変化が二度届く。
final class BatchDebounceTests: OrbeTestCase {
  private let t0 = Date(timeIntervalSinceReferenceDate: 1000)

  private func batch(_ path: String, git: Bool = false) -> RepoWatcher.Batch {
    RepoWatcher.Batch(paths: [path], gitChanged: git, scanAll: false)
  }

  func testTrailingDebounceFollowsTheLatestChange() {
    var debounce = BatchDebounce()
    XCTAssertNil(debounce.dueDate, "保留が無ければ期限も無い")
    XCTAssertEqual(debounce.note(batch("/a"), at: t0), t0.addingTimeInterval(0.2))
    XCTAssertNil(debounce.flush(at: t0.addingTimeInterval(0.1)), "期限前は出さない")
    XCTAssertEqual(
      debounce.note(batch("/b"), at: t0.addingTimeInterval(0.15)), t0.addingTimeInterval(0.35),
      "続く変化で後ろへずれる")
    XCTAssertNil(debounce.flush(at: t0.addingTimeInterval(0.3)))
    XCTAssertEqual(
      debounce.flush(at: t0.addingTimeInterval(0.35)),
      RepoWatcher.Batch(paths: ["/a", "/b"], gitChanged: false, scanAll: false), "積んだ変化は 1 つに畳む")
    XCTAssertNil(debounce.dueDate, "取り出せば空")
    XCTAssertTrue(debounce.pending.isEmpty)
  }

  func testMaximumDelayCapsAContinuousStream() {
    var debounce = BatchDebounce()
    var now = t0
    var due = debounce.note(batch("/0"), at: now)
    for i in 1...20 {
      now = t0.addingTimeInterval(Double(i) * 0.15)
      due = debounce.note(batch("/\(i)", git: i == 7), at: now)
      XCTAssertLessThanOrEqual(due, t0.addingTimeInterval(1.0), "上限を超えて延びない（\(i) 回目）")
      XCTAssertNil(debounce.flush(at: min(now, t0.addingTimeInterval(0.99))))
    }
    XCTAssertEqual(due, t0.addingTimeInterval(1.0))
    let flushed = debounce.flush(at: t0.addingTimeInterval(1.0))
    XCTAssertEqual(flushed?.paths.count, 21)
    XCTAssertEqual(flushed?.gitChanged, true)
    XCTAssertEqual(
      debounce.note(batch("/again"), at: t0.addingTimeInterval(1.05)), t0.addingTimeInterval(1.25),
      "次の変化から新しい窓が始まる")
  }
}
