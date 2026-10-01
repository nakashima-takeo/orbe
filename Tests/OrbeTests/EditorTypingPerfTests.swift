import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// エディターの打鍵の main の仕事の計測。`ORBE_EDITOR_PERF=1` のときだけ走る——時間はマシンと環境で変わるので通常の
/// テストでは見ない。release で `scripts/perf-editor.sh` が回し、目標（→ docs/testing/test-architecture.md）と並べる。
/// 結果は `PERF` で始まる行に出す。main の仕事は main のスレッドの CPU 時間で数える（壁時計の時間は機械の混み具合で
/// 膨らむので参考に出すだけ）。
@MainActor
final class EditorTypingPerfTests: OrbeTestCase {
  override func setUpWithError() throws {
    try super.setUpWithError()
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["ORBE_EDITOR_PERF"] == "1", "ORBE_EDITOR_PERF=1 で走る")
  }

  /// 打鍵 1 回で文書と Orbe 側が main でする仕事——編集の通知を受けてから、文書と配り先（検索・出現・プロジェクト検索）の
  /// 処理が戻るまで——を、大きさを変えた文書（64KB / 1MB / 8MB）で並べる。git 管理下（baseline あり）の回も測る。面の
  /// 編集係の仕事は含まない（それは `keystroke-main`）。中央値が文書の大きさに比例して増えないこと。
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
        type(into: opened)
        reportPerf(
          label, tracked ? "typing-main (baseline あり)" : "typing-main", timer.times, digits: 3)
        opened.document.surface.delegate = opened.document
        opened.window.orderOut(nil)
      }
    }
  }

  /// 打鍵 1 回の main の仕事——キーの出来事を受けてから、面の編集係・文書・Orbe の配り先（検索・出現・プロジェクト検索）が
  /// 戻るまでの main のスレッドの CPU 時間。p99 1ms 以下（200KB・1MB、git 管理下、1 万字近い長い行の行末）。壁時計の
  /// 時間は参考に出すだけにする（利用者が感じる遅れは打鍵→present の関門が見る）。描くのは描画スレッド。ライブ変換は、
  /// IME の呼び出し 1 回と、IME がその直後に読み返す未確定の範囲・未確定と選択の矩形・未確定の上の点の下の字を合わせて
  /// 1 回と数え、同じく main のスレッドの CPU 時間で見る。変換の続き（2 回目以降と確定）は 3 つとも p99 1ms 以下。変換の
  /// 始まり（最初の呼び出し）は未確定の先頭の x を出すために行を 1 回組むので、普通の行（200KB・1MB）で p99 1ms 以下、
  /// 長い行は値を出すだけ。プロセスで最初の 1 打鍵と最初の変換（入力の仕組みの初期化を含む）は数えないので、測る文書を
  /// 開く前に別の文書で打つ。
  func testKeystrokeMainTime() throws {
    let warm = try openEditor("warm\n")
    warm.document.surface.responder.keyDown(with: .key("/", []))
    try compose(into: warm, count: 20)
    warm.window.orderOut(nil)
    let long = String(repeating: "x", count: 9_990) + "\n" + Self.swiftSource(bytes: 20_000)
    for (label, text) in [
      ("200KB", Self.swiftSource(bytes: 200_000)), ("1MB", Self.swiftSource(bytes: 1_000_000)),
      ("long-line", long),
    ] {
      let opened = try openEditor(text)
      opened.document.baseline = text
      XCTAssertTrue(opened.document.waitUntilCaughtUp(timeout: 60))
      let row = label == "long-line" ? 0 : opened.document.text.lineCount / 3
      let caret = label == "long-line" ? 9_990 : opened.document.text.lineStart(row + 5) + 4
      opened.document.surface.selectedRange = NSRange(location: caret, length: 0)
      opened.document.surface.reveal(NSRange(location: caret, length: 0), policy: .center)
      var cpu: [Double] = []
      var wall: [Double] = []
      for character in String(repeating: "let value = compute(offset) ok ", count: 3) {
        let began = (clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID), CACurrentMediaTime())
        opened.document.surface.responder.keyDown(with: .key(String(character), []))
        cpu.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - began.0) / 1e6)
        wall.append((CACurrentMediaTime() - began.1) * 1000)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
      }
      reportPerf(label, "keystroke-main (baseline あり)", cpu, digits: 3)
      reportPerf(label, "keystroke-main-wall (参考)", wall, digits: 3)
      let sorted = cpu.sorted()
      XCTAssertLessThanOrEqual(
        sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))], 1,
        "\(label): 打鍵 1 回の main のスレッドの CPU 時間の p99")
      let composing = try compose(into: opened)
      reportPerf(
        label, "composition-main 続き (baseline あり)", composing.continuing.cpu, digits: 3)
      reportPerf(
        label, "composition-main 始まり (baseline あり)", composing.starting.cpu, digits: 3)
      reportPerf(
        label, "composition-main-wall 続き (参考)", composing.continuing.wall, digits: 3)
      reportPerf(
        label, "composition-main-wall 始まり (参考)", composing.starting.wall, digits: 3)
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

  /// 1/3 の位置の行に 30 字打つ。
  private func type(into opened: OpenedEditor) {
    let document = opened.document
    let caret = document.text.lineStart(document.text.lineCount / 3 + 5) + 4
    document.surface.selectedRange = NSRange(location: caret, length: 0)
    document.surface.reveal(NSRange(location: caret, length: 0), policy: .center)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    for character in "let value = compute(offset) ok" {
      document.surface.responder.keyDown(with: .key(String(character), []))
      RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
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

/// 編集の通知を文書へ流し、その呼び出しが戻るまでの main のスレッドの CPU 時間（ms）を記録する delegate。
@MainActor
final class EditTimer: TextSurfaceDelegate {
  let inner: EditorDocument
  private(set) var times: [Double] = []

  init(inner: EditorDocument) { self.inner = inner }

  func surface(_ surface: any TextSurface, didChange edits: [TextEdit]) {
    let began = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    inner.surface(surface, didChange: edits)
    times.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - began) / 1e6)
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
  func surfaceContent(_ surface: any TextSurface) -> SurfaceContent {
    inner.surfaceContent(surface)
  }
}
