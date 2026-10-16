import XCTest

@testable import Orbe

/// cron 式の解析——受ける記法と、断る式とその理由。
///
/// 壊れると何が起きるか。AI が書いた正しい式が断られる、または壊れた式が保存されて一度も回らない。日と曜日の両方を絞った式が
/// 通ると、標準 cron では「どちらか一致」で回る式を Orbe が「かつ」で数え、AI の意図と違う日に回る。
final class BackgroundCronTests: OrbeTestCase {
  private func parse(_ expression: String) throws -> BackgroundCron {
    try BackgroundCron(expression)
  }

  private func error(_ expression: String) -> BackgroundCronError? {
    do {
      _ = try BackgroundCron(expression)
      return nil
    } catch {
      return error
    }
  }

  func testFieldsAreParsedIntoSets() throws {
    let monthly = try parse("*/15 9-17/4 1,15 * *")
    let weekly = try parse("0 9 * 4-6 mon-fri")

    XCTAssertEqual(monthly.minutes, [0, 15, 30, 45])
    XCTAssertEqual(monthly.hours, [9, 13, 17])
    XCTAssertEqual(monthly.days, [1, 15])
    XCTAssertEqual(monthly.months, Set(1...12))
    XCTAssertEqual(monthly.weekdays, Set(0...6))
    XCTAssertEqual(weekly.days, Set(1...31))
    XCTAssertEqual(weekly.months, [4, 5, 6])
    XCTAssertEqual(weekly.weekdays, [1, 2, 3, 4, 5])
  }

  /// `a/n` は a から欄の最大まで。英名は大文字小文字を問わない。曜日の 7 は日曜。
  func testStepsFromAValueNamesAndSevenAsSunday() throws {
    XCTAssertEqual(try parse("5/20 * * * *").minutes, [5, 25, 45])
    XCTAssertEqual(try parse("0 0 * JAN,Dec *").months, [1, 12])
    XCTAssertEqual(try parse("0 0 * * 5-7").weekdays, [5, 6, 0])
    XCTAssertEqual(try parse("0 0 * * SUN").weekdays, [0])
  }

  /// 式は前後の空白を除いて受けたまま持つ（保存・一覧・式のままの表示に使う）。
  func testExpressionIsKeptAsWritten() throws {
    XCTAssertEqual(try parse("  0  9 * *\t1-5 \n").expression, "0  9 * *\t1-5")
  }

  func testRejectedExpressions() {
    let cases: [(String, BackgroundCronError)] = [
      ("0 9 * *", .fieldCount),
      ("0 0 9 * * *", .fieldCount),
      ("@daily", .fieldCount),
      ("60 * * * *", .invalidField(.minute, "60")),
      ("0 24 * * *", .invalidField(.hour, "24")),
      ("0 0 0 * *", .invalidField(.day, "0")),
      ("0 0 * 13 *", .invalidField(.month, "13")),
      ("0 0 * * 8", .invalidField(.weekday, "8")),
      ("0 18-9 * * *", .invalidField(.hour, "18-9")),
      ("*/0 * * * *", .invalidField(.minute, "*/0")),
      ("1,,2 * * * *", .invalidField(.minute, "1,,2")),
      ("+5 * * * *", .invalidField(.minute, "+5")),
      ("0 9 L * *", .invalidField(.day, "L")),
      ("0 9 15W * *", .invalidField(.day, "15W")),
      ("0 9 ? * 1", .invalidField(.day, "?")),
      ("0 9 * * 1#2", .invalidField(.weekday, "1#2")),
      ("0 9 * * mon-fry", .invalidField(.weekday, "mon-fry")),
      ("0 9 1 * 1", .dayAndWeekday),
      ("0 9 1-31 * 1-5", .dayAndWeekday),
      ("0 9 31 2,4 *", .neverMatches),
    ]
    for (expression, expected) in cases {
      XCTAssertEqual(error(expression), expected, expression)
    }
  }

  /// 日を絞った式は、絞った月のどれかにその日があれば受ける（2 月 29 日は閏年に来る）。
  func testDayThatExistsInSomeMonthIsAccepted() {
    XCTAssertNil(error("0 0 29 2 *"))
    XCTAssertNil(error("0 0 31 1-2 *"))
  }
}
