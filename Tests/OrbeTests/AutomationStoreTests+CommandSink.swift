import XCTest

@testable import Orbe

/// 出力先のコマンドの定義・書き換え・回の ID。取得元も段も任意で、上限は 1〜60 分。書き換えの後も全件を見直さない——見直すと
/// 指示文を 1 文字直しただけで、今の集合の全件がコマンドに渡り直す。
///
/// 壊れると何が起きるか: 投稿のコマンドが書き換えのたびに全件へ二重に走る。上限の省略と 2 の書き換えで走っている回が止まる。
/// 再起動で回の ID が変わり、やり直しの回をコマンドが別の回と読む。
extension AutomationStoreTests {
  private func commandDefinition(
    timeoutMinutes: Int? = nil, directory: String? = nil
  ) -> AutomationDefinition {
    var definition = Self.definition()
    definition.source = nil
    definition.steps = []
    definition.sink = AutomationRunnerTests.commandSink(
      directory: directory, timeoutMinutes: timeoutMinutes)
    return definition
  }

  func testACommandSinkNeedsNoSourceOrStepsAndChecksItsCommand() throws {
    let store = try store()
    XCTAssertNoThrow(try store.replace(1, with: commandDefinition(timeoutMinutes: 60)))
    var everything = Self.definition(coverage: .everything)
    everything.sink = AutomationRunnerTests.commandSink()
    XCTAssertNoThrow(try store.replace(1, with: everything), "取得の性質は 3 種とも受ける")

    for (label, definition, message) in [
      ("上限 0", commandDefinition(timeoutMinutes: 0), "sink: timeoutMinutes must be 1 to 60"),
      ("上限 61", commandDefinition(timeoutMinutes: 61), "sink: timeoutMinutes must be 1 to 60"),
      (
        "相対の作業ディレクトリ", commandDefinition(directory: "tmp"),
        "sink: directory is not an absolute path"
      ),
    ] {
      XCTAssertThrowsError(try store.replace(1, with: definition), label) {
        XCTAssertEqual($0 as? AutomationError, .invalid(message), label)
      }
    }
    var blank = commandDefinition()
    blank.sink = AutomationRunnerTests.commandSink("  ")
    XCTAssertThrowsError(try store.replace(1, with: blank)) {
      XCTAssertEqual($0 as? AutomationError, .invalid("sink: command is empty"))
    }
  }

  /// 出力先がコマンドなら、何をするかを書き換えても全件見直しの印を立てない。タスク候補の見直しで立っていた印もコマンドへ
  /// 替えた時点で下ろし、タスク候補へ戻すと出力先が変わったので立てる。
  func testReviewAllFollowsTheNewSink() throws {
    let store = try store()
    _ = try store.replace(1, with: Self.definition(instruction: "別の指示"))
    XCTAssertTrue(store.automation(1)!.reviewAll)

    var command = Self.definition(instruction: "別の指示")
    command.sink = AutomationRunnerTests.commandSink()
    XCTAssertTrue(try store.replace(1, with: command).reworked)
    XCTAssertFalse(store.automation(1)!.reviewAll, "コマンドへ替えたら前からの印も下ろす")

    command.steps = [Self.judgeStep("さらに別の指示")]
    XCTAssertTrue(try store.replace(1, with: command).reworked)
    XCTAssertFalse(store.automation(1)!.reviewAll, "コマンドは書き換えても見直さない")

    XCTAssertTrue(try store.replace(1, with: Self.definition()).reworked)
    XCTAssertTrue(store.automation(1)!.reviewAll)
  }

  /// 上限は省略を 2 と解いて比べる。値が変われば走っている回を止める。
  func testTheTimeoutIsComparedResolved() throws {
    let store = try store()
    _ = try store.replace(1, with: commandDefinition())
    XCTAssertFalse(try store.replace(1, with: commandDefinition(timeoutMinutes: 2)).reworked)
    XCTAssertFalse(try store.replace(1, with: commandDefinition()).reworked)
    XCTAssertTrue(try store.replace(1, with: commandDefinition(timeoutMinutes: 3)).reworked)
  }

  /// 回の ID は数え始めから作り、保存の精度に通してから使う——再起動で読み直しても同じ値。回が記録されると変わる。
  func testTheRunIdSurvivesARestartAndMovesWhenARunIsRecorded() throws {
    let store = AutomationStore(file: nil)
    let created = try store.create(commandDefinition(), now: t0.addingTimeInterval(0.000_4))
    var automation = created
    automation.lastRunAt = t0.addingTimeInterval(0.123_456)
    let data = try AutomationWire.encoder().encode(automation)
    let reloaded = try AutomationWire.decoder.decode(Automation.self, from: data)

    XCTAssertEqual(reloaded.runId, automation.runId)
    XCTAssertEqual(automation.runId, "1-1800000000123")
    XCTAssertNotEqual(automation.runId, created.runId)
  }

  /// 知らない出力先は、Swift の型名を出さずに言える種類で断る。
  func testAnUnknownSinkKindIsRefusedByNamingTheKinds() throws {
    for json in [#"{"kind": "mail"}"#, #"{"kind": "command"}"#] {
      XCTAssertThrowsError(
        try AutomationWire.decoder.decode(AutomationSink.self, from: Data(json.utf8)), json)
    }
    XCTAssertThrowsError(
      try AutomationWire.decoder.decode(AutomationSink.self, from: Data(#"{"kind": "mail"}"#.utf8))
    ) {
      guard case .dataCorrupted(let context) = $0 as? DecodingError else { return XCTFail("\($0)") }
      XCTAssertEqual(context.debugDescription, "pass taskCandidates, command or report")
    }
    XCTAssertThrowsError(
      try AutomationWire.decoder.decode(
        AutomationSinkReport.self, from: Data(#"{"kind": "mail"}"#.utf8))
    ) {
      guard case .dataCorrupted(let context) = $0 as? DecodingError else { return XCTFail("\($0)") }
      XCTAssertEqual(context.debugDescription, "pass taskCandidates, command or report")
    }
  }
}
