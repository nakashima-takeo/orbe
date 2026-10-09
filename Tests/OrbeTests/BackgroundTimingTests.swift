import XCTest

@testable import Orbe

/// 次の時刻の規則（「数え始めより後の最初の回」1 つ）と値の検証。番人も使い手の画面（「次は 7 分後」）もこの関数を読む。
///
/// 壊れると何が起きるか。スリープ明けに過ぎた回の数だけ走る、または 1 回も走らない。毎日の時刻がタイムゾーンや夏時間で
/// ずれる。期限を過ぎた待ちが最後の確認を走らせてから外れる。秒単位の間隔で外部のサービスを叩き続ける。
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

  private func daily(_ times: (Int, Int)...) -> BackgroundTiming {
    .daily(Set(times.map { BackgroundTimeOfDay(hour: $0.0, minute: $0.1) }))
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

  // MARK: - 毎日の時刻

  func testDailyPicksTheFirstTimeAfterAnchor() throws {
    let tokyo = try calendar("Asia/Tokyo")
    let anchor = try date(tokyo, "2026-10-10 10:00")

    let next = daily((9, 0), (13, 0)).next(
      after: anchor, deadline: nil, now: anchor, calendar: tokyo)

    XCTAssertEqual(next, .run(try date(tokyo, "2026-10-10 13:00")))
  }

  /// 数え始めちょうどの時刻は含めない（走った回をもう 1 度走らせない）。
  func testDailyIsStrictlyAfterAnchor() throws {
    let tokyo = try calendar("Asia/Tokyo")
    let anchor = try date(tokyo, "2026-10-10 13:00")

    let next = daily((9, 0), (13, 0)).next(
      after: anchor, deadline: nil, now: anchor, calendar: tokyo)

    XCTAssertEqual(next, .run(try date(tokyo, "2026-10-11 09:00")))
  }

  /// 毎日の時刻は、その時点のタイムゾーンで数える。
  func testDailyCountsInTheGivenTimeZone() throws {
    let tokyo = try calendar("Asia/Tokyo")
    let utc = try calendar("UTC")
    let anchor = try date(utc, "2026-10-10 00:00")

    let inTokyo = daily((9, 0)).next(after: anchor, deadline: nil, now: anchor, calendar: tokyo)
    let inUTC = daily((9, 0)).next(after: anchor, deadline: nil, now: anchor, calendar: utc)

    XCTAssertEqual(inTokyo, .run(try date(tokyo, "2026-10-11 09:00")))
    XCTAssertEqual(inUTC, .run(try date(utc, "2026-10-10 09:00")))
  }

  /// 夏時間で存在しない時刻は、次に存在する時刻へずらす（その日を飛ばさない）。
  func testDailyTimeInDSTGapMovesToNextValidTime() throws {
    let newYork = try calendar("America/New_York")
    let anchor = try date(newYork, "2026-03-08 00:00")

    let next = daily((2, 30)).next(after: anchor, deadline: nil, now: anchor, calendar: newYork)

    XCTAssertEqual(next, .run(try date(newYork, "2026-03-08 03:00")))
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

  func testDailyTimesAreValidated() {
    XCTAssertThrowsError(try BackgroundTiming.daily([]).validate()) {
      XCTAssertEqual($0 as? BackgroundJobError, .noTimesOfDay)
    }
    XCTAssertThrowsError(try daily((24, 0)).validate()) {
      XCTAssertEqual($0 as? BackgroundJobError, .invalidTimeOfDay)
    }
    XCTAssertThrowsError(try daily((9, 60)).validate()) {
      XCTAssertEqual($0 as? BackgroundJobError, .invalidTimeOfDay)
    }
    XCTAssertNoThrow(try daily((0, 0), (23, 59)).validate())
  }

  func testDuplicateDailyTimesCollapse() {
    XCTAssertEqual(daily((9, 0), (9, 0)), daily((9, 0)))
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
