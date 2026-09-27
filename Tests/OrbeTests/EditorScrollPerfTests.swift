import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// エディターのスクロールと打鍵の計測。`ORBE_EDITOR_PERF=1` のときだけ走る——時間はマシンと環境で変わるので通常の
/// テストでは見ない。release・実アプリ相当の小さな環境で `scripts/perf-editor.sh` が回し、目標（→
/// docs/testing/test-architecture.md）と並べる。結果は `PERF` で始まる行に出す。
@MainActor
final class EditorScrollPerfTests: OrbeTestCase {
  override func setUpWithError() throws {
    try super.setUpWithError()
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["ORBE_EDITOR_PERF"] == "1", "ORBE_EDITOR_PERF=1 で走る")
  }

  func test1MB() throws { try run(label: "1MB", bytes: 1_000_000) }

  func test200KB() throws { try run(label: "200KB", bytes: 200_000) }

  /// 打鍵 1 回で文書と Orbe 側が main でする仕事——編集の通知を受けてから、文書と配り先（俯瞰・検索・出現）の処理が
  /// 戻るまで——を、大きさを変えた文書（64KB / 1MB / 8MB）で並べる。git 管理下（baseline あり）の回も測る。テキスト
  /// エンジン自身の仕事（TextKit の layout と描画）は含まない（それは `typing`）。
  func testTypingMainTimeAcrossSizes() throws {
    for (label, bytes) in [("64KB", 64_000), ("1MB", 1_000_000), ("8MB", 8_000_000)] {
      let text = Self.swiftSource(bytes: bytes)
      for tracked in [false, true] {
        let opened = try openEditor(text)
        if tracked {
          opened.document.baseline = text
          XCTAssertTrue(opened.document.waitUntilCaughtUp(timeout: 60))
        }
        let timer = EditTimer(inner: opened.document)
        opened.document.surface.delegate = timer
        _ = type(into: opened)
        reportPerf(
          label, tracked ? "typing-main (baseline あり)" : "typing-main", timer.times, digits: 3)
        opened.document.surface.delegate = opened.document
        opened.window.orderOut(nil)
      }
    }
  }

  /// 新しい面（Metal）の打鍵 1 回の main の仕事——キーの出来事を受けてから、面の編集係・文書・Orbe の配り先（検索・出現・
  /// 俯瞰への知らせ）が戻るまでの main のスレッドの CPU 時間。p99 1ms 以下（200KB・1MB、git 管理下、1 万字近い長い行の
  /// 行末）。壁時計の時間は機械の混み具合で膨らむので参考に出すだけにする（利用者が感じる遅れは打鍵→present の関門が
  /// 見る）。描くのは描画スレッド。ライブ変換は、IME の呼び出し 1 回と、IME がその直後に読み返す未確定の範囲・未確定と
  /// 選択の矩形・未確定の上の点の下の字を合わせて 1 回と数え、同じく main のスレッドの CPU 時間で見る。変換の続き（2 回目
  /// 以降と確定）は 3 つとも p99 1ms 以下。変換の始まり（最初の呼び出し）は未確定の先頭の x を出すために行を 1 回組むので、
  /// 普通の行（200KB・1MB）で p99 1ms 以下、長い行は値を出すだけ。プロセスで最初の 1 打鍵と最初の変換（入力の仕組みの
  /// 初期化を含む）は数えないので、測る文書を開く前に別の文書で打つ。
  func testMetalTypingMainTime() throws {
    let metal = EditorEngineChoice(
      metal: true, elasticScroll: true, fontSmoothing: true, language: .ja)
    let warm = try openEditor("warm\n", engine: metal)
    warm.document.surface.responder.keyDown(with: .key("/", []))
    try compose(into: warm, count: 20)
    warm.window.orderOut(nil)
    let long = String(repeating: "x", count: 9_990) + "\n" + Self.swiftSource(bytes: 20_000)
    for (label, text) in [
      ("200KB", Self.swiftSource(bytes: 200_000)), ("1MB", Self.swiftSource(bytes: 1_000_000)),
      ("long-line", long),
    ] {
      let opened = try openEditor(text, engine: metal)
      opened.document.baseline = text
      XCTAssertTrue(opened.document.waitUntilCaughtUp(timeout: 60))
      let row = label == "long-line" ? 0 : opened.document.text.lineCount / 3
      opened.document.scroll(toFirstLine: CGFloat(row))
      opened.document.surface.selectedRange = NSRange(
        location: label == "long-line" ? 9_990 : opened.document.text.lineStart(row + 5) + 4,
        length: 0)
      var cpu: [Double] = []
      var wall: [Double] = []
      for character in String(repeating: "let value = compute(offset) ok ", count: 3) {
        let began = (clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID), CACurrentMediaTime())
        opened.document.surface.responder.keyDown(with: .key(String(character), []))
        cpu.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - began.0) / 1e6)
        wall.append((CACurrentMediaTime() - began.1) * 1000)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
      }
      reportPerf(label, "metal-typing-main (baseline あり)", cpu, digits: 3)
      reportPerf(label, "metal-typing-main-wall (参考)", wall, digits: 3)
      let sorted = cpu.sorted()
      XCTAssertLessThanOrEqual(
        sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))], 1,
        "\(label): 打鍵 1 回の main のスレッドの CPU 時間の p99")
      let composing = try compose(into: opened)
      reportPerf(
        label, "metal-composition-main 続き (baseline あり)", composing.continuing.cpu, digits: 3)
      reportPerf(
        label, "metal-composition-main 始まり (baseline あり)", composing.starting.cpu, digits: 3)
      reportPerf(
        label, "metal-composition-main-wall 続き (参考)", composing.continuing.wall, digits: 3)
      reportPerf(
        label, "metal-composition-main-wall 始まり (参考)", composing.starting.wall, digits: 3)
      XCTAssertLessThanOrEqual(
        Self.p99(composing.continuing.cpu), 1,
        "\(label): 変換の続きの呼び出し 1 回（読み返し込み）の main のスレッドの CPU 時間の p99")
      if label != "long-line" {
        XCTAssertLessThanOrEqual(
          Self.p99(composing.starting.cpu), 1,
          "\(label): 変換の始まりの呼び出し 1 回（読み返し込み）の main のスレッドの CPU 時間の p99")
      }
      opened.window.orderOut(nil)
    }
  }

  /// main の仕事の時間（ms）——main のスレッドの CPU 時間（関門が見る）と壁時計の時間（参考）。
  private struct MainTimes {
    var cpu: [Double] = []
    var wall: [Double] = []
  }

  /// ライブ変換を再生し、IME の呼び出しとその直後の読み返し 1 回ごとの main の仕事を、変換の始まりと続きに分けて返す——
  /// 未確定が 1 打鍵ごとに 1 字伸びて全体が置き換わり（文節を 1 つ選んでいる）、20 字目で確定する、を `count` 打鍵ぶん。
  @discardableResult
  private func compose(into opened: OpenedEditor, count: Int = 60) throws -> (
    starting: MainTimes, continuing: MainTimes
  ) {
    let client = try XCTUnwrap(opened.document.surface.responder as? NSTextInputClient)
    let whole = NSRange(location: NSNotFound, length: 0)
    var starting = MainTimes()
    var continuing = MainTimes()
    for k in 0..<count {
      let length = k % 20 + 1
      let reading = String(repeating: "か", count: length)
      let began = (clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID), CACurrentMediaTime())
      if length == 20 {
        client.insertText(reading, replacementRange: whole)
      } else {
        client.setMarkedText(
          reading, selectedRange: NSRange(location: length / 2, length: (length + 1) / 2),
          replacementRange: whole)
      }
      let marked = client.markedRange()
      if marked.location != NSNotFound {
        let rect = client.firstRect(forCharacterRange: marked, actualRange: nil)
        _ = client.firstRect(forCharacterRange: client.selectedRange(), actualRange: nil)
        _ = client.characterIndex(for: NSPoint(x: rect.midX, y: rect.midY))
      }
      let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - began.0) / 1e6
      let wall = (CACurrentMediaTime() - began.1) * 1000
      if length == 1 {
        starting.cpu.append(cpu)
        starting.wall.append(wall)
      } else {
        continuing.cpu.append(cpu)
        continuing.wall.append(wall)
      }
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return (starting, continuing)
  }

  private static func p99(_ times: [Double]) -> Double {
    let sorted = times.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
  }

  /// 1200×800 の窓に Swift の文書を開き、裏の仕事（文書全体の構文色）が追いついてから測る。速いドラッグは開いた
  /// ばかりの文書で、打鍵・ホイール・打鍵の後の速いドラッグは別に開き直した文書で測る。文書を端から端まで通した後の
  /// 打鍵も参考に出す（TextKit が段落を覚えるので、開いたばかりの文書より重い）。
  private func run(label: String, bytes: Int) throws {
    let text = Self.swiftSource(bytes: bytes)
    let dragged = try openEditor(text)
    print(
      "PERF", label, "env", ProcessInfo.processInfo.environment.count, "lines",
      dragged.document.text.lineCount, "bytes", dragged.document.text.length)
    drag(label, "fast-drag", dragged)
    reportPerf(label, "typing-after-drag (参考)", type(into: dragged))
    dragged.window.orderOut(nil)

    let typed = try openEditor(text)
    reportPerf(label, "typing", type(into: typed))
    let recolored = recolor(into: typed)
    reportPerf(label, "typing-recolor", recolored.redraw)
    reportPerf(label, "typing-catch-up (参考)", recolored.catchUp)
    let clip = try XCTUnwrap(typed.document.surface.responder.enclosingScrollView).contentView
    let times = (0..<60).map { _ in
      frame(typed.pane) {
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + 36))
        clip.enclosingScrollView?.reflectScrolledClipView(clip)
      }
    }
    reportPerf(label, "wheel", times)
    drag(label, "fast-drag-after-typing", typed)
    reportPerf(label, "scrollbar-draw (一致の多い検索)", scrollbarDraws(typed))
    typed.window.orderOut(nil)
  }

  /// 速いドラッグを 3 回。
  private func drag(_ label: String, _ name: String, _ opened: OpenedEditor) {
    let rounds = (1...3).map { _ in fastDrag(opened.pane, opened.document) }
    print(
      "PERF", label, name, "updates/s min", String(format: "%.1f", rounds.min() ?? 0), "rounds",
      rounds.map { String(format: "%.1f", $0) }.joined(separator: " "))
  }

  /// 1/3 の位置の行に 30 字打つ。1 字ごとの時間（ms）。
  private func type(into opened: OpenedEditor) -> [Double] {
    let document = opened.document
    let middle = document.text.lineCount / 3
    document.scroll(toFirstLine: CGFloat(middle))
    document.surface.selectedRange = NSRange(
      location: document.text.lineStart(middle + 5) + 4, length: 0)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    var times: [Double] = []
    for character in "let value = compute(offset) ok" {
      times.append(
        frame(opened.pane) {
          document.surface.responder.keyDown(with: .key(String(character), []))
        })
      RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
    return times
  }

  /// 打鍵の後、裏から役割が届いてから行う描き直し（1 字ごと、ms）——打鍵のコマとは別に main に載る仕事。役割が変わらない
  /// 打鍵では描き直すものが無い。参考に、打鍵から裏の仕事（文書全体の役割）が追いつくまでの時間も返す。
  private func recolor(into opened: OpenedEditor) -> (redraw: [Double], catchUp: [Double]) {
    let document = opened.document
    document.surface.selectedRange = NSRange(
      location: document.text.lineStart(document.text.lineCount / 3 + 7) + 4, length: 0)
    _ = frame(opened.pane) {}
    var redraw: [Double] = []
    var catchUp: [Double] = []
    for character in "let value = compute(offset) ok" {
      let began = Date()
      _ = frame(opened.pane) {
        document.surface.responder.keyDown(with: .key(String(character), []))
      }
      XCTAssertTrue(document.waitUntilCaughtUp(timeout: 60))
      catchUp.append(Date().timeIntervalSince(began) * 1000)
      redraw.append(frame(opened.pane) {})
    }
    return (redraw, catchUp)
  }

  /// 一致の多い検索（1MB で上限の 19,999 件、200KB で約 1.5 万件）を開いたまま、スクロールバーを 30 回描き直す（1 回ごと、
  /// ms）。
  private func scrollbarDraws(_ opened: OpenedEditor) -> [Double] {
    let pane = opened.pane
    pane.showSearch()
    pane.search.setNeedle("e")
    XCTAssertTrue(opened.document.waitUntilCaughtUp(timeout: 60))
    XCTAssertGreaterThan(
      pane.search.matches.count, OverviewRuler.approximateFindMatchCount, "前提: 一致が多い")
    let bar = pane.scrollbar
    let times = (0..<30).map { _ in frame(bar) { bar.needsDisplay = true } }
    pane.closeSearch()
    return times
  }

  /// スクロールバーのつまみを 2 秒で上端から下端まで、8ms ごとにドラッグする。本文の先頭の行が変わった回数を毎秒で返す。
  private func fastDrag(_ pane: EditorPaneView, _ document: EditorDocument) -> Double {
    let bar = pane.scrollbar
    document.scroll(toFirstLine: 0)
    pane.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    let start = NSPoint(x: bar.bounds.midX, y: (bar.geometry?.sliderPosition ?? 0) + 5)
    bar.mouseDown(with: bar.mouseEvent(.leftMouseDown, at: start))
    var updates = 0
    var last = document.viewportLines.first
    let began = Date()
    while Date().timeIntervalSince(began) < 2 {
      let progress = Date().timeIntervalSince(began) / 2
      let y = start.y + CGFloat(progress) * (bar.bounds.height - 30)
      bar.mouseDragged(
        with: bar.mouseEvent(.leftMouseDragged, at: NSPoint(x: start.x, y: y)))
      RunLoop.main.run(until: Date().addingTimeInterval(0.008))
      pane.displayIfNeeded()
      let first = document.viewportLines.first
      if first != last {
        updates += 1
        last = first
      }
    }
    bar.mouseUp(
      with: bar.mouseEvent(.leftMouseUp, at: NSPoint(x: start.x, y: bar.bounds.height)))
    return Double(updates) / 2
  }

  /// 操作 1 回を layout と描画まで含めて測る（ms）。
  private func frame(_ view: NSView, _ body: () -> Void) -> Double {
    let began = Date()
    body()
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    return Date().timeIntervalSince(began) * 1000
  }

  /// `bytes` を超えるまで同じ形の宣言を連ねた Swift の本文（1MB で 43,261 行）。
  static func swiftSource(bytes: Int) -> String {
    let unit = """
      struct Item {
        let name: String
        var offset: Int = 0  // counter
        func render(into buffer: inout [String]) {
          buffer.append("\\(name): \\(offset)")
        }
      }

      """
    var text = ""
    var k = 0
    while text.utf8.count < bytes {
      k += 1
      text += unit.replacingOccurrences(of: "Item", with: "Item\(k)")
    }
    return text
  }
}

/// 編集の通知を文書へ流し、その呼び出しが戻るまでの時間（ms）を記録する delegate。
@MainActor
private final class EditTimer: TextSurfaceDelegate {
  let inner: EditorDocument
  private(set) var times: [Double] = []

  init(inner: EditorDocument) { self.inner = inner }

  func surface(_ surface: any TextSurface, didChange edits: [TextEdit]) {
    let began = DispatchTime.now().uptimeNanoseconds
    inner.surface(surface, didChange: edits)
    times.append(Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000)
  }
  func surface(_ surface: any TextSurface, focusDidChange focused: Bool) {
    inner.surface(surface, focusDidChange: focused)
  }
  func surfaceDidChangeViewport(_ surface: any TextSurface) {
    inner.surfaceDidChangeViewport(surface)
  }
  func surfaceDidChangeSelection(_ surface: any TextSurface) {
    inner.surfaceDidChangeSelection(surface)
  }
  func surface(_ surface: any TextSurface, rolesIn range: NSRange) -> [HighlightSpan] {
    inner.surface(surface, rolesIn: range)
  }
  func surfaceLineCount(_ surface: any TextSurface) -> Int { inner.surfaceLineCount(surface) }
  func surface(_ surface: any TextSurface, lineContaining offset: Int) -> Int {
    inner.surface(surface, lineContaining: offset)
  }
  func surface(_ surface: any TextSurface, rangeOfLine line: Int) -> NSRange {
    inner.surface(surface, rangeOfLine: line)
  }
  func surfaceContent(_ surface: any TextSurface) -> SurfaceContent {
    inner.surfaceContent(surface)
  }
}
