import AppKit
import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// diff の計測。`ORBE_EDITOR_PERF=1` のときだけ走る（`scripts/perf-editor.sh` が回す）。1MB の Swift の大きな書き換え
/// ——編集の数が diff の上限の近く・上限越え・全行——で、裏の行差分の時間（上限の値の根拠）と、並びを作って面に置く main の
/// 仕事（diff を開く・取り直すとき）を記録し、作業ツリー diff の中の打鍵 1 回の main の仕事を測る。結果は `PERF` で
/// 始まる行に出す。
@MainActor
final class EditorDiffPerfTests: OrbeTestCase {
  override func setUpWithError() throws {
    try super.setUpWithError()
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["ORBE_EDITOR_PERF"] == "1", "ORBE_EDITOR_PERF=1 で走る")
    try XCTSkipIf(RenderThread.device == nil, "Metal の装置が無い環境では面を作らない")
  }

  func testLargeRewrite() throws {
    let source = EditorTypingPerfTests.swiftSource(bytes: 1_000_000)
    let lines = source.components(separatedBy: "\n")
    let changing = { (every: Int) in
      lines.enumerated().map { $0 % every == 3 ? $1 + " // changed" : $1 }.joined(separator: "\n")
    }
    let cases = [
      ("1MB edits near the bound", source, changing(9)),
      ("1MB edits over the bound", source, changing(4)),
      ("1MB whole rewrite", source, lines.map { $0 + " // rewritten" }.joined(separator: "\n")),
    ]
    for (label, old, new) in cases {
      let (oldRope, newRope) = (TextRope(old), TextRope(new))
      var started = CACurrentMediaTime()
      let hunks = LineDiff.hunks(old: oldRope, new: newRope, limit: EditorDiff.hunkLimit)
      let background = CACurrentMediaTime() - started
      let gutter = LineDiff.hunks(old: oldRope, new: newRope, limit: LineDiff.gutter)

      let url = try caseFile("\(UUID().uuidString).swift", new)
      let surface = try XCTUnwrap(
        makeMetalTextSurface(style: EditorStyle.make(), omittedLabel: { "\($0)" })
          as? MetalTextSurface)
      let document = EditorDocument(
        url: url, contents: try EditorDocument.read(url), surface: surface,
        registry: LanguageRegistry(queriesRoot: nil))
      let source = RevisionDocument(
        text: old, name: url, registry: LanguageRegistry(queriesRoot: nil))
      surface.viewStateDidChange(size: CGSize(width: 900, height: 700), scale: 2, visible: false)
      surface.setPresentation(DiffStyle.inline)
      started = CACurrentMediaTime()
      var rows = DiffRows.inline(hunks, new: DiffRows.Side(newRope))
      rows.source = source
      surface.setRows(rows)
      surface.flush()
      let place = CACurrentMediaTime() - started
      print(
        "PERF diff", label, "lines", oldRope.lineCount, "/", newRope.lineCount, "hunks",
        hunks.count, "(gutter limit", gutter.count, ") background line diff", ms(background),
        "main rows place", ms(place), "insertions", surface.rows.count)
      withExtendedLifetime((document, source)) {}
    }
  }

  /// 作業ツリー diff の中の打鍵 1 回の main の仕事——キーの出来事を受けてから、面の編集係・文書と、diff を含む Orbe の
  /// 配り先が戻るまでの main のスレッドの CPU 時間。1MB の Swift で、変更が数十か所の普通の diff と、編集の数が上限に近い
  /// diff を、インラインと並列で、変えていない行に字と Enter（行の数を変える）を打って測る。普通の diff は p99 1ms 以下、
  /// 上限に近い diff は記録する。プロセスで最初の 1 打鍵（入力の仕組みの初期化を含む）は数えないので、測る前に別の文書で
  /// 打つ。開いた文書の最初の打鍵は、未保存への切り替わり（セッションの知らせから面の組み直しまで）を 1 回だけ含み、
  /// ほかの部分も 2 打鍵目以降の 2〜5 倍かかって 0.38〜3ms になる（2 打鍵目以降は普通の diff で 1ms 未満）ので、
  /// `diff keystroke-main` から外して（関門も、上限に近い diff の記録も、外した後の値で見る）参考に別に出す。
  func testTypingInAWorkingTreeDiff() throws {
    let warm = try openEditor("warm\n")
    warm.document.surface.responder.keyDown(with: .key("/", []))
    warm.window.orderOut(nil)
    let source = EditorTypingPerfTests.swiftSource(bytes: 1_000_000)
    let lines = source.components(separatedBy: "\n")
    let changing = { (every: Int) in
      lines.enumerated().map { $0 % every == 3 ? $1 + " // changed" : $1 }.joined(separator: "\n")
    }
    let repo = try TempGitRepo()
    try repo.write("big.swift", source)
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "big"]).isSuccess)
    for (label, working, gated) in [
      ("1MB diff tens of changes", changing(1000), true),
      ("1MB diff edits near the bound", changing(9), false),
    ] {
      try repo.write("big.swift", working)
      for mode in [EditorDiff.Mode.inline, .side] {
        let name = "\(label) \(mode)"
        let cpu = try typeInWorkingTreeDiff(repo, mode: mode, name)
        let steady = Array(cpu.dropFirst())
        print("PERF", name, "diff first-keystroke-main (参考)", String(format: "%.3f", cpu[0]))
        reportPerf(name, "diff keystroke-main", steady, digits: 3)
        guard gated else { continue }
        let sorted = steady.sorted()
        XCTAssertLessThanOrEqual(
          sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))], 1,
          "\(name): 打鍵 1 回の main のスレッドの CPU 時間の p99")
      }
    }
  }

  /// `repo` の big.swift の作業ツリー diff を見せ方 `mode` で開き、変えていない行に字と Enter を打って、打鍵ごとの main の
  /// スレッドの CPU 時間（ms）を返す。後の計測に裏の仕事を残さない——文書が追いついてから diff を閉じ、pane を窓から外して
  /// 根のサービス（監視と git）を放す。
  private func typeInWorkingTreeDiff(
    _ repo: TempGitRepo, mode: EditorDiff.Mode, _ name: String
  ) throws -> [Double] {
    let queries = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let tab = TerminalTab.alone(
      cwd: repo.root, editorSurfaces: EditorSurfaces(queriesRoot: queries))
    // 左の列を開いた窓で、本体の幅が並列の境の値より狭い（インライン）・広い（並列）。
    let window = mountEditor(tab, width: mode == .side ? 1400 : 1200, height: 800)
    tab.group.view.editor.configure(
      translucency: ChromeTranslucency(), localization: LocalizationStore(language: .ja),
      fontResolver: ChromeFontResolver(), sidebar: EditorSidebarState())
    let key = EditorDiff.Key(root: repo.root, path: "big.swift", kind: .workingTree)
    defer {
      tab.group.editor.closeDiff(on: .changes)
      window.orderOut(nil)
      window.contentView = nil
    }
    let diff = try tab.group.editor.openDiff(key)
    pumpMain(
      until: { diff.content == .ready && diff.placement == .placed }, timeout: 60,
      "\(name): 並びが出る")
    let document = try XCTUnwrap(diff.document)
    XCTAssertTrue(pumpUntilCaughtUp(document))
    let surface = document.surface
    window.makeFirstResponder(surface.responder)
    let text = document.text
    var row = text.lineCount / 3 + 1
    let line = { (row: Int) in
      text.substring(
        NSRange(location: text.lineStart(row), length: text.lineEnd(row) - text.lineStart(row))
      ).trimmingCharacters(in: .newlines)
    }
    while line(row).hasSuffix(" // changed") { row += 1 }
    XCTAssertFalse(
      document.hunks.contains { $0.newLines.contains(row) }, "\(name): 前提: 打つのは変えていない行")
    let caret = text.lineStart(row) + 4
    surface.selectedRange = NSRange(location: caret, length: 0)
    surface.reveal(NSRange(location: caret, length: 0), policy: .center)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    var cpu: [Double] = []
    for key in Array("let value = compute(offset) ok").map(String.init) + ["\r", "x", "\r"] {
      let began = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
      surface.responder.keyDown(with: .key(key, []))
      cpu.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - began) / 1e6)
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    XCTAssertTrue(pumpUntilCaughtUp(document))
    return cpu
  }

  private func ms(_ seconds: Double) -> String { String(format: "%.1fms", seconds * 1000) }
}
