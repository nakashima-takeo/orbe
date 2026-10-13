import XCTest

@testable import Orbe

/// 次の時刻の規則（「数え始めより後の最初の回」1 つ）と値の検証。番人も使い手の画面（「次は 7 分後」）もこの関数を読む。
///
/// 壊れると何が起きるか。スリープ明けに過ぎた回の数だけ走る、または 1 回も走らない。cron の予定が眠っていた間に過ぎた時刻を
/// 起きてから回す、または予約の発火で回るべき回を飛ばす。cron の時刻がタイムゾーンや夏時間でずれる。期限を過ぎた待ちが
/// 最後の確認を走らせてから外れる。秒単位の間隔で外部のサービスを叩き続ける。
final class BackgroundTimingTests: OrbeTestCase {
  private func calendar(_ zone: String) throws -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
    return calendar
  }

  /// `calendar` のタイムゾーンで読む「yyyy-MM-dd HH:mm」。
  private func date(_ calendar: Calendar, _ text: String) throws -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return try XCTUnwrap(formatter.date(from: text))
  }

  private func cron(_ expression: String) throws -> BackgroundTiming {
    .cron(try BackgroundCron(expression))
  }

  // MARK: - 間隔

  func testIntervalRunsOneIntervalAfterAnchor() {
    let anchor = Date(timeIntervalSince1970: 1_000_000)

    let next = BackgroundTiming.every(300).next(
      after: anchor, deadline: nil, now: anchor, calendar: .current)

    XCTAssertEqual(next, .run(anchor.addingTimeInterval(300)))
  }

  /// 何回分過ぎていても、返るのは「数え始めの 1 間隔後」の 1 回だけ（過ぎている＝今すぐ 1 回）。
  func testOverdueIntervalIsOneOccurrenceNotACatchUp() {
    let anchor = Date(timeIntervalSince1970: 1_000_000)
    let now = anchor.addingTimeInterval(3600)

    let next = BackgroundTiming.every(60).next(
      after: anchor, deadline: nil, now: now, calendar: .current)

    XCTAssertEqual(next, .run(anchor.addingTimeInterval(60)))
  }

  /// 時計が戻って数え始めが未来にあれば、今から数える（画面の「次は」も番人と同じ答えになる）。
  func testAnchorInTheFutureCountsFromNow() {
    let now = Date(timeIntervalSince1970: 1_000_000)

    let next = BackgroundTiming.every(600).next(
      after: now.addingTimeInterval(86400), deadline: nil, now: now, calendar: .current)

    XCTAssertEqual(next, .run(now.addingTimeInterval(600)))
  }

  // MARK: - cron

  func testCronPicksTheFirstMatchAfterAnchor() throws {
    let tokyo = try calendar("Asia/Tokyo")
    let anchor = try date(tokyo, "2026-10-10 10:00")

    let next = try cron("0 9,13 * * *").next(
      after: anchor, deadline: nil, now: anchor, calendar: tokyo)

    XCTAssertEqual(next, .run(try date(tokyo, "2026-10-10 13:00")))
  }

  /// 数え始めちょうどの時刻は含めない（走った回をもう 1 度走らせない）。
  func testCronIsStrictlyAfterAnchor() throws {
    let tokyo = try calendar("Asia/Tokyo")
    let anchor = try date(tokyo, "2026-10-10 13:00")

    let next = try cron("0 9,13 * * *").next(
      after: anchor, deadline: nil, now: anchor, calendar: tokyo)

    XCTAssertEqual(next, .run(try date(tokyo, "2026-10-11 09:00")))
  }

  /// 日・曜日・月・時・分はすべて「かつ」。金曜 9:00 の次の平日 9:00 は月曜。
  func testCronWeekdaysSkipTheWeekend() throws {
    let tokyo = try calendar("Asia/Tokyo")
    let anchor = try date(tokyo, "2026-10-09 09:00")

    let next = try cron("0 9 * * 1-5").next(
      after: anchor, deadline: nil, now: anchor, calendar: tokyo)

    XCTAssertEqual(next, .run(try date(tokyo, "2026-10-12 09:00")))
  }

  func testCronWithinARangeOfHours() throws {
    let tokyo = try calendar("Asia/Tokyo")
    let expression = try cron("*/10 9-18 * * 1-5")

    let lastOfFriday = try date(tokyo, "2026-10-09 18:50")
    let mondayMorning = try date(tokyo, "2026-10-12 09:05")

    XCTAssertEqual(
      expression.next(after: lastOfFriday, deadline: nil, now: lastOfFriday, calendar: tokyo),
      .run(try date(tokyo, "2026-10-12 09:00")))
    XCTAssertEqual(
      expression.next(after: mondayMorning, deadline: nil, now: mondayMorning, calendar: tokyo),
      .run(try date(tokyo, "2026-10-12 09:10")))
  }

  /// 該当時刻を過ぎて起きたら（Mac が眠っていた・Orbe が落ちていた）、その回は回さず次の該当時刻を待つ。
  func testCronDoesNotRunATimePassedBeforeTheCurrentMinute() throws {
    let tokyo = try calendar("Asia/Tokyo")
    let anchor = try date(tokyo, "2026-10-09 08:00")
    let now = try date(tokyo, "2026-10-09 09:01")

    let next = try cron("0 9 * * 1-5").next(
      after: anchor, deadline: nil, now: now, calendar: tokyo)

    XCTAssertEqual(next, .run(try date(tokyo, "2026-10-12 09:00")))
  }

  /// 今の分に入っている該当時刻は今の回として返す——予約は該当時刻ちょうどに発火し、数え直す時点の今はわずかに過ぎている。
  func testCronRunsTheMatchInTheCurrentMinute() throws {
    let tokyo = try calendar("Asia/Tokyo")
    let anchor = try date(tokyo, "2026-10-09 08:00")
    let nine = try date(tokyo, "2026-10-09 09:00")

    let next = try cron("0 9 * * 1-5").next(
      after: anchor, deadline: nil, now: nine.addingTimeInterval(59), calendar: tokyo)

    XCTAssertEqual(next, .run(nine))
  }

  /// cron の時刻は、その時点のタイムゾーンで数える。
  func testCronCountsInTheGivenTimeZone() throws {
    let tokyo = try calendar("Asia/Tokyo")
    let utc = try calendar("UTC")
    let anchor = try date(utc, "2026-10-10 00:00")

    let inTokyo = try cron("0 9 * * *").next(
      after: anchor, deadline: nil, now: anchor, calendar: tokyo)
    let inUTC = try cron("0 9 * * *").next(after: anchor, deadline: nil, now: anchor, calendar: utc)

    XCTAssertEqual(inTokyo, .run(try date(tokyo, "2026-10-11 09:00")))
    XCTAssertEqual(inUTC, .run(try date(utc, "2026-10-10 09:00")))
  }

  /// 夏時間で存在しない時刻は、次に存在する時刻へずらす（その日を飛ばさない）。
  func testCronTimeInDSTGapMovesToNextValidTime() throws {
    let newYork = try calendar("America/New_York")
    let anchor = try date(newYork, "2026-03-08 00:00")

    let next = try cron("30 2 * * *").next(
      after: anchor, deadline: nil, now: anchor, calendar: newYork)

    XCTAssertEqual(next, .run(try date(newYork, "2026-03-08 03:00")))
  }

  /// 2 月 29 日だけの式は閏年に来る。
  func testCronOnLeapDayWaitsForTheLeapYear() throws {
    let utc = try calendar("UTC")
    let anchor = try date(utc, "2026-03-01 00:00")

    let next = try cron("0 0 29 2 *").next(
      after: anchor, deadline: nil, now: anchor, calendar: utc)

    XCTAssertEqual(next, .run(try date(utc, "2028-02-29 00:00")))
  }

  // MARK: - 期限

  func testDeadlineBeforeNextOccurrenceExpires() {
    let anchor = Date(timeIntervalSince1970: 1_000_000)
    let deadline = anchor.addingTimeInterval(30)

    let next = BackgroundTiming.every(60).next(
      after: anchor, deadline: deadline, now: anchor, calendar: .current)

    XCTAssertEqual(next, .expire(deadline))
  }

  func testDeadlineAtTheOccurrenceExpires() {
    let anchor = Date(timeIntervalSince1970: 1_000_000)
    let deadline = anchor.addingTimeInterval(60)

    let next = BackgroundTiming.every(60).next(
      after: anchor, deadline: deadline, now: anchor, calendar: .current)

    XCTAssertEqual(next, .expire(deadline))
  }

  /// 過ぎていた回も、期限が今以前なら走らせずに「期限が来た」。
  func testOverdueOccurrenceWithPassedDeadlineExpiresWithoutRunning() {
    let anchor = Date(timeIntervalSince1970: 1_000_000)
    let deadline = anchor.addingTimeInterval(600)
    let now = anchor.addingTimeInterval(3600)

    let next = BackgroundTiming.every(60).next(
      after: anchor, deadline: deadline, now: now, calendar: .current)

    XCTAssertEqual(next, .expire(deadline))
  }

  func testOverdueOccurrenceBeforeFutureDeadlineRuns() {
    let anchor = Date(timeIntervalSince1970: 1_000_000)
    let now = anchor.addingTimeInterval(3600)

    let next = BackgroundTiming.every(60).next(
      after: anchor, deadline: now.addingTimeInterval(60), now: now, calendar: .current)

    XCTAssertEqual(next, .run(anchor.addingTimeInterval(60)))
  }

  // MARK: - 値の検証

  func testIntervalShorterThanOneMinuteIsRejected() {
    XCTAssertThrowsError(try BackgroundTiming.every(59).validate()) {
      XCTAssertEqual($0 as? BackgroundJobError, .intervalTooShort)
    }
    XCTAssertNoThrow(try BackgroundTiming.every(60).validate())
  }

  /// 7 日より長い間隔は断る。極端な値を予定に入れると、番人の時計を組む時点で桁あふれして落ち、保存した受信が
  /// 起動のたびに落とす。
  func testIntervalLongerThanSevenDaysIsRejected() {
    for interval: TimeInterval in [7 * 86400 + 60, 2e17 * 60] {
      XCTAssertThrowsError(try BackgroundTiming.every(interval).validate()) {
        XCTAssertEqual($0 as? BackgroundJobError, .intervalTooLong)
      }
    }
    XCTAssertNoThrow(try BackgroundTiming.every(7 * 86400).validate())
  }

  func testCommandJobIsValidated() {
    XCTAssertThrowsError(try BackgroundJob.command(.init(script: "  ")).validate()) {
      XCTAssertEqual($0 as? BackgroundJobError, .emptyCommand)
    }
    XCTAssertThrowsError(
      try BackgroundJob.command(.init(script: "true", directory: "relative")).validate()
    ) {
      XCTAssertEqual($0 as? BackgroundJobError, .relativeDirectory)
    }
  }

  func testAgentJobIsValidated() {
    let call = BackgroundAgentCall(cli: "claude", model: "haiku", tools: ["Read"], prompt: "hi")
    func error(_ edit: (inout BackgroundAgentCall) -> Void) -> BackgroundJobError? {
      var edited = call
      edit(&edited)
      do {
        try BackgroundJob.agent(edited).validate()
        return nil
      } catch {
        return error
      }
    }

    XCTAssertNil(error { _ in })
    XCTAssertEqual(error { $0.cli = "gemini" }, .unknownAgent("gemini"))
    XCTAssertEqual(error { $0.model = " " }, .emptyModel)
    XCTAssertEqual(error { $0.prompt = "\n" }, .emptyPrompt)
    XCTAssertEqual(error { $0.tools = ["Read", ""] }, .emptyToolName)
  }
}
