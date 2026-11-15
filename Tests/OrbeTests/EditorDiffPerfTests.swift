import AppKit
import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// diff の計測。`ORBE_EDITOR_PERF=1` のときだけ走る（`scripts/perf-editor.sh` が回す）。1MB の Swift の大きな書き換え
/// ——編集の数が diff の上限の近く・上限越え・全行——で、裏の行差分の時間（上限の値の根拠）と、並びを作って面に置く main の
/// 仕事（diff を開く・取り直すとき）を記録し、作業ツリー diff の中の打鍵 1 回の main の仕事を測って、`PERF` で始まる行に
/// 出す。
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

  /// 作業ツリー diff の中の打鍵 1 回の main の仕事——キーの出来事を受けてから、面の編集係・文書・diff（並びの置き直し）・
  /// 配り先が戻るまでの main のスレッドの CPU 時間。1MB の Swift で、変更が数十か所の普通の diff と、編集の数が上限に近い
  /// diff を、インラインと並列で、変えていない行に字と Enter（行の数を変える）を打って測る。普通の diff は p99 1ms 以下、
  /// 上限に近い diff は記録する。プロセスで最初の 1 打鍵（入力の仕組みの初期化を含む）は数えないので、測る前に別の文書で
  /// 打つ。
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
    let queries = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    for (label, working, gated) in [
      ("1MB diff tens of changes", changing(1000), true),
      ("1MB diff edits near the bound", changing(9), false),
    ] {
      try repo.write("big.swift", working)
      for mode in [EditorDiff.Mode.inline, .side] {
        let tab = TerminalTab.alone(
          cwd: repo.root, editorSurfaces: EditorSurfaces(queriesRoot: queries))
        let window = hostEditor(tab, width: 1200, height: 800)
        tab.group.view.editor.configure(
          translucency: ChromeTranslucency(), localization: LocalizationStore(language: .ja),
          fontResolver: ChromeFontResolver(), sidebar: EditorSidebarState(),
          diffModes: EditorDiffModeState(mode: mode))
        let diff = try tab.group.editor.openDiff(
          EditorDiff.Key(root: repo.root, path: "big.swift", kind: .workingTree), as: .pinned)
        pumpMain(
          until: { diff.content == .ready && diff.placement == .placed }, timeout: 60,
          "\(label): 並びが出る")
        let document = try XCTUnwrap(diff.document)
        XCTAssertTrue(pumpUntilCaughtUp(document))
        let surface = document.surface
        window.makeFirstResponder(surface.responder)
        let row = document.text.lineCount / 3 + 1
        let caret = document.text.lineStart(row) + 4
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
        let name = "\(label) \(mode)"
        reportPerf(name, "diff keystroke-main", cpu, digits: 3)
        if gated {
          let sorted = cpu.sorted()
          XCTAssertLessThanOrEqual(
            sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))], 1,
            "\(name): 打鍵 1 回の main のスレッドの CPU 時間の p99")
        }
        window.orderOut(nil)
      }
    }
  }

  private func ms(_ seconds: Double) -> String { String(format: "%.1fms", seconds * 1000) }
}
