import XCTest

@testable import Orbe

/// 詳細の期限の入力（「10/6」「2026-10-06」）の読み取りと、行・詳細に出す「10/6 月」の表示、時刻を
/// 暦日へ落とす規則を固定する。
///
/// 壊れると何が起きるか: 「10/6」と打った期限が去年や来年の同じ日になり、期限切れや遠い先の扱いになる。
/// 読めない入力が黙って別の日付になる。曜日や年がずれて、見えている期限と実際の期限が食い違う。
/// 今日を西暦以外の暦で数えると、期限が存在しない年（和暦なら 0007 年）で保存され、日によっては画面を
/// 開いた瞬間に落ちる。
final class TaskDueTextTests: OrbeTestCase {
  private let today = TaskItem.DueDate(year: 2025, month: 10, day: 4)!

  private func date(_ year: Int, _ month: Int, _ day: Int) -> TaskItem.DueDate {
    TaskItem.DueDate(year: year, month: month, day: day)!
  }

  func testMonthDayIsTheNearestSuchDayOnOrAfterToday() {
    XCTAssertEqual(TaskDueText.parse("10/6", today: today), date(2025, 10, 6))
    XCTAssertEqual(TaskDueText.parse("10/4", today: today), today, "今日は今日のまま")
    XCTAssertEqual(TaskDueText.parse("10/3", today: today), date(2026, 10, 3), "過ぎた日は来年")
    XCTAssertEqual(TaskDueText.parse(" 1/5 ", today: today), date(2026, 1, 5))
  }

  func testMonthDayThatDoesNotExistThisYearMovesToTheNextYearThatHasIt() {
    XCTAssertEqual(TaskDueText.parse("2/29", today: today), date(2028, 2, 29))
  }

  func testIsoDateIsTakenAsIsEvenInThePast() {
    XCTAssertEqual(TaskDueText.parse("2026-10-06", today: today), date(2026, 10, 6))
    XCTAssertEqual(TaskDueText.parse("2024-01-02", today: today), date(2024, 1, 2))
  }

  func testUnreadableTextIsRejected() {
    for text in ["あした", "13/1", "2/30", "10/", "10-6", "１０/６", "10/6/2025", "2025-10-6", ""] {
      XCTAssertNil(TaskDueText.parse(text, today: today), text)
    }
  }

  /// 暦日は利用者の暦に依らず西暦で数え、日付の変わり目だけをタイムゾーンで決める。
  func testCalendarDayIsTheGregorianDateInTheGivenTimeZone() throws {
    let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
    let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
    var gregorianTokyo = Calendar(identifier: .gregorian)
    gregorianTokyo.timeZone = tokyo
    let justAfterMidnightInTokyo = try XCTUnwrap(
      gregorianTokyo.date(from: DateComponents(year: 2025, month: 10, day: 4, hour: 0, minute: 30)))

    XCTAssertEqual(TaskItem.DueDate(justAfterMidnightInTokyo, timeZone: tokyo), date(2025, 10, 4))
    XCTAssertEqual(TaskItem.DueDate(justAfterMidnightInTokyo, timeZone: utc), date(2025, 10, 3))
    XCTAssertEqual(TaskItem.DueDate.today(justAfterMidnightInTokyo, timeZone: tokyo), today)
  }

  func testDateWithoutWeekdayAddsTheYearOnlyOutsideThisYearInTheSameFormAsTheDueLabel() {
    let weekdays = TaskDueText.weekdays(.ja)

    XCTAssertEqual(TaskDueText.date(date(2025, 10, 3), today: today), "10/3")
    XCTAssertEqual(TaskDueText.date(date(2024, 10, 3), today: today), "2024/10/3")
    XCTAssertEqual(
      TaskDueText.label(date(2024, 10, 3), today: today, weekdays: weekdays),
      "2024/10/3 木", "期限の札は同じ日付に曜日を足しただけ")
  }

  func testLabelShowsMonthDayAndWeekdayAndAddsTheYearOnlyOutsideThisYear() {
    let weekdays = TaskDueText.weekdays(.ja)

    XCTAssertEqual(TaskDueText.label(date(2025, 10, 6), today: today, weekdays: weekdays), "10/6 月")
    XCTAssertEqual(
      TaskDueText.label(date(2027, 1, 5), today: today, weekdays: weekdays), "2027/1/5 火")
  }

  func testWeekdayNamesFollowTheLanguage() {
    XCTAssertEqual(
      TaskDueText.label(date(2025, 10, 6), today: today, weekdays: TaskDueText.weekdays(.en)),
      "10/6 Mon")
  }
}
