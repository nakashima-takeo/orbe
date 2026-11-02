import Foundation
import OrbeTestSupport
import XCTest

@testable import Orbe

/// 実 `orb automation try` / `trial` を子プロセスで起こし、試走を始めて読むまでを固定する。
///
/// 壊れると何が起きるか: `try` が範囲・行・limit・書く前の定義を落とすと、AI が指したのと違う試走が黙って走る。`try` が試走の
/// ID を出さないと、`trial` で読めない。`trial --wait` が時間切れを 0 で返すと、AI は途中の結果を終わった結果と読む。
extension OrbeCliAutomationProcessTests {
  /// 取得（手段は走れば 3 秒かかる）→ 処理（`cat` で素通し）→ 副作用（走れば `marker` を作る）。
  private func trialDefinition(marker: URL) -> String {
    #"{"name": "試す", "nodes": ["#
      + #"{"key": "fetch", "name": "取る", "trigger": {"kind": "manual"}, "coverage": "currentSet", "#
      + #""command": "sleep 3"}, "#
      + #"{"key": "note", "name": "写す", "trigger": {"kind": "arrival"}, "from": ["fetch"], "#
      + #""command": "cat"}, "#
      + #"{"key": "send", "name": "送る", "trigger": {"kind": "arrival"}, "from": ["note"], "#
      + #""deliver": "none", "command": "cat >/dev/null; touch '\#(marker.path)'"}]}"#
  }

  /// `try` は与える行（`--rows` のファイル）・limit・範囲を運んで試走の ID を出し、`trial <trialId> --wait` は試走の終わりまで待って
  /// ノードごとの結果を出す。副作用は走らず、渡るはずだった行の数が人向けの 1 行に出る。
  func testTryCarriesRowsLimitAndRangeAndTrialWaitsForTheResult() throws {
    let control = try startControlProcess()
    let marker = TestScratch.caseDir.appendingPathComponent("sent")
    let id = run(control, ["set"], stdin: trialDefinition(marker: marker))
    let rows = TestScratch.caseDir.appendingPathComponent("rows.jsonl")
    try ["b", "c"].map { (key: String) -> String in
      #"{"id":"\#(key)","link":"https://x.test/\#(key)","body":"\#(key)","#
        + #""time":"2026-01-01T00:00:00Z"}"#
    }.joined(separator: "\n").write(to: rows, atomically: true, encoding: .utf8)

    let trialId = run(control, ["try", id, "--rows", rows.path, "--limit", "1"])
    XCTAssertNotNil(Int(trialId), trialId)
    let trial = try XCTUnwrap(
      control.orbJSON(["automation", "trial", trialId, "--wait"])["trial"] as? [String: Any])
    XCTAssertEqual(trial["automationId"] as? Int, Int(id))
    let nodes = try XCTUnwrap(trial["nodes"] as? [[String: Any]])
    func firstRun(_ key: String) -> [String: Any]? {
      (nodes.first { $0["key"] as? String == key }?["runs"] as? [[String: Any]])?.first
    }
    func ids(_ rows: Any?) -> [String]? {
      (rows as? [[String: Any]])?.compactMap { $0["id"] as? String }
    }
    XCTAssertEqual(
      ids((firstRun("fetch")?["given"] as? [String: Any])?["rows"]), ["1:b"],
      "取得のノードの ID の接頭（新しい DB の最初のノード）")
    XCTAssertEqual(ids((firstRun("send")?["held"] as? [String: Any])?["rows"]), ["1:b"])
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "副作用のコマンドは走らない")
    let lines = run(control, ["trial", trialId]).split(separator: "\n")
    XCTAssertTrue(lines.contains("fetch\tgiven\tgiven 1 rows"), "\(lines)")
    XCTAssertEqual(lines.last, "send\theld\theld 1 rows")

    let ranged = try XCTUnwrap(
      control.orbJSON(["automation", "try", id, "--from", "note", "--to", "note"])["trial"]
        as? [String: Any])
    XCTAssertEqual(ranged["from"] as? [String], ["note"])
    XCTAssertEqual(ranged["to"] as? [String], ["note"])
    let unreadable = control.orb(["automation", "try", id, "--rows", rows.path + ".missing"])
    XCTAssertEqual(unreadable.status, 2, unreadable.stderr)
    XCTAssertTrue(unreadable.stderr.contains("--rows cannot read"), unreadable.stderr)
    let blank = TestScratch.caseDir.appendingPathComponent("blank.jsonl")
    try "\n  \n".write(to: blank, atomically: true, encoding: .utf8)
    let empty = control.orb(["automation", "try", id, "--rows", blank.path])
    XCTAssertEqual(empty.status, 2, empty.stderr)
    XCTAssertTrue(empty.stderr.contains("has no rows"), empty.stderr)
  }

  /// `try --definition` は標準入力の定義（`set` と同じ JSON）を書く前の定義として試す: `<id>` が無ければ新しい定義、あれば
  /// `--version` からの書き換え。どちらも本番の自動化を変えない。定義の誤りは `set` と同じく control が断る（exit 1）。
  func testTryDefinitionTriesTheDefinitionOnStdinWithoutWritingIt() throws {
    let control = try startControlProcess()
    let marker = TestScratch.caseDir.appendingPathComponent("sent")
    let definition = trialDefinition(marker: marker)
    let rows = TestScratch.caseDir.appendingPathComponent("rows.jsonl")
    try #"{"id":"b","link":"https://x.test/b","body":"b","time":"2026-01-01T00:00:00Z"}"#
      .write(to: rows, atomically: true, encoding: .utf8)

    let new = run(control, ["try", "--definition", "--rows", rows.path], stdin: definition)
    let tried = try XCTUnwrap(
      control.orbJSON(["automation", "trial", new, "--wait"])["trial"] as? [String: Any])
    XCTAssertNil(tried["automationId"])
    XCTAssertNil(tried["failure"])
    XCTAssertEqual(
      (tried["nodes"] as? [[String: Any]])?.map { $0["key"] as? String }, ["fetch", "note", "send"])
    XCTAssertTrue(control.target.automationStore.automations.isEmpty)

    let id = run(control, ["set"], stdin: definition)
    var listed = try XCTUnwrap(control.target.automationStore.automation(Int(id)!)?.definition)
    listed.name = "直す"
    let renamed = try XCTUnwrap(
      String(bytes: AutomationWire.encoder().encode(listed), encoding: .utf8))
    let rewrite = run(
      control, ["try", id, "--version", "1", "--definition", "--rows", rows.path], stdin: renamed)
    let rewritten = try XCTUnwrap(
      control.orbJSON(["automation", "trial", rewrite, "--wait"])["trial"] as? [String: Any])
    XCTAssertEqual(rewritten["automationId"] as? Int, Int(id))
    XCTAssertNil(rewritten["failure"])
    XCTAssertEqual(control.target.automationStore.automation(Int(id)!)?.name, "試す")
    XCTAssertEqual(control.target.automationStore.automation(Int(id)!)?.version, 1)

    let broken = control.orb(["automation", "try", "--definition"], stdin: #"{"name": "x"}"#)
    XCTAssertEqual(broken.status, 1)
    XCTAssertTrue(broken.stderr.contains("error -32602: missing nodes"), broken.stderr)
  }

  /// `trial --wait` は、試走が `--timeout-ms` までに終わらなければ exit 124。
  func testTrialWaitExits124WhenTheTrialOutlastsTheTimeout() throws {
    let control = try startControlProcess()
    let id = run(
      control, ["set"],
      stdin: trialDefinition(marker: TestScratch.caseDir.appendingPathComponent("sent")))
    let trialId = run(control, ["try", id])

    let outcome = control.orb(["automation", "trial", trialId, "--wait", "--timeout-ms", "300"])
    XCTAssertEqual(outcome.status, 124, outcome.stderr)
  }
}
