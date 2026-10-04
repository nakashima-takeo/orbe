import XCTest

@testable import Orbe

/// agent の札の経過（「12分」「3時間」「2日」）の単位の切り替わりを固定する。
///
/// 壊れると何が起きるか: 半日動き続けている agent が「720分」と出て、どれだけ放っているか一目で分からない。
/// 単位の境で 1 つ下の単位に戻ると、経過が縮んだように見える。
final class TaskElapsedTextTests: OrbeTestCase {
  private let since = Date(timeIntervalSince1970: 1_800_000_000)

  private func label(afterMinutes minutes: Double) -> String {
    TaskElapsedText.label(
      since: since, now: since.addingTimeInterval(minutes * 60),
      l10n: LocalizationStore(language: .ja))
  }

  func testMinutesUnderAnHourHoursUnderADayThenDays() {
    XCTAssertEqual(label(afterMinutes: 0), "0分")
    XCTAssertEqual(label(afterMinutes: 59.9), "59分")
    XCTAssertEqual(label(afterMinutes: 60), "1時間")
    XCTAssertEqual(label(afterMinutes: 24 * 60 - 1), "23時間")
    XCTAssertEqual(label(afterMinutes: 24 * 60), "1日")
    XCTAssertEqual(label(afterMinutes: 3 * 24 * 60 + 100), "3日")
  }
}
