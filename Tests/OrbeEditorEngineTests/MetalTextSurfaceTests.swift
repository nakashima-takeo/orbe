import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 新しい面の契約——文書の写しを引いて描く・見えている範囲の通知・main の操作のスクロール・外観に従う色・読むだけ。
/// 壊れると俯瞰と構文色の見えている範囲が本文とずれる、⌘F の次・前で一致が見えない、印や色や字が古い本文で描かれる、
/// ライト・ダークを切り替えても字が前の外観の色のまま、打鍵で本文が変わる。
@MainActor
final class MetalTextSurfaceTests: EngineTestCase {
  private func lines(_ count: Int, width: Int = 10) -> String {
    (0..<count).map { "line \($0) " + String(repeating: "x", count: width) }.joined(separator: "\n")
      + "\n"
  }

  /// 結ばれたとき・役割が届いたときに写しを引き、その版は文書の版。
  func testPullsTheDocumentsContent() throws {
    let opened = try open("let a = 1\nlet b = \"s\"\n")
    let content = try XCTUnwrap(opened.surface.material.read().content)
    XCTAssertEqual(content.version, opened.document.version)
    XCTAssertEqual(content.text.length, opened.document.text.length)
    XCTAssertFalse(content.roles.roles(in: NSRange(location: 0, length: 20)).isEmpty, "役割が届いている")
  }

  /// `scroll(toTop:)` と `viewport` は互いに逆——先頭の行・隠れている割合・可視行数を今の面と同じ意味で返す。
  func testViewportIsTheInverseOfScrollToTop() throws {
    let opened = try open(lines(300), size: CGSize(width: 800, height: 604))
    let text = opened.document.text
    opened.surface.scroll(toTop: text.lineStart(50), hiddenFraction: 0.25)
    let viewport = opened.surface.viewport
    XCTAssertEqual(viewport.firstVisible, text.lineStart(50))
    XCTAssertEqual(viewport.hiddenFraction, 0.25, accuracy: 1e-9)
    XCTAssertEqual(viewport.visibleLines, 600.0 / 18, accuracy: 1e-9, "上端の余白を除いた高さ")
    XCTAssertEqual(opened.document.viewportLines.first, 50.25, accuracy: 1e-9)
  }

  /// 最終行が最上段に来るまで送れ、それより先は止まる。
  func testScrollsUntilTheLastLineIsAtTheTop() throws {
    let opened = try open(lines(100), size: CGSize(width: 800, height: 604))
    opened.document.scroll(toFirstLine: 1_000)
    XCTAssertEqual(opened.document.viewportLines.first, 100, accuracy: 1e-9, "末尾の空行が最上段")
  }

  /// 見えるところまで最小限スクロールする——縦に見えていれば縦は動かず、横に隠れていれば横だけ寄る。
  func testScrollToVisibleMovesMinimally() throws {
    let opened = try open(lines(100, width: 300), size: CGSize(width: 800, height: 604))
    let text = opened.document.text
    let target = text.lineStart(10) + 280
    opened.surface.scrollToVisible(NSRange(location: target, length: 1))
    XCTAssertEqual(opened.surface.viewport.firstVisible, 0, "縦は見えているので動かない")
    XCTAssertGreaterThan(opened.surface.viewport.hiddenColumns, 0, "横に寄る")
    let columns = opened.surface.viewport
    XCTAssertLessThanOrEqual(281, columns.hiddenColumns + columns.visibleColumns + 0.5)
    opened.surface.scrollToVisible(NSRange(location: text.lineStart(80), length: 0))
    XCTAssertEqual(opened.surface.viewport.hiddenColumns, 0, "行頭へ戻る")
    XCTAssertGreaterThan(opened.document.viewportLines.first, 40, "下の行が見えるまで送る")
  }

  /// 行を見えている高さの中央へ置く（アニメーションしない）。
  func testScrollToCenterPlacesTheLineInTheMiddle() throws {
    let opened = try open(lines(300), size: CGSize(width: 800, height: 604))
    opened.surface.scrollToCenter(opened.document.text.lineStart(150))
    let (first, visible) = opened.document.viewportLines
    XCTAssertEqual(first + visible / 2, 150.5, accuracy: 0.01)
  }

  /// 指の出来事の量はその場で位置に入り、見えている範囲はその呼び出しの中で文書へ知らされる。
  func testWheelEventNotifiesTheViewportSynchronously() throws {
    let opened = try open(lines(300), size: CGSize(width: 800, height: 604))
    var notified = 0
    opened.document.onViewportChange = { notified += 1 }
    let event = try XCTUnwrap(
      CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -90, wheel2: 0,
        wheel3: 0))
    opened.surface.view.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
    XCTAssertEqual(notified, 1)
    XCTAssertEqual(opened.document.viewportLines.first, 5, accuracy: 1e-9)
  }

  /// 読むだけ——打鍵・クリックで本文は変わらず、落ちない。
  func testKeysDoNotChangeTheText() throws {
    let opened = try open("let a = 1\n")
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = opened.surface.view
    window.makeFirstResponder(opened.surface.responder)
    for key in ["a", "\r", "\u{7f}"] {
      let event = try XCTUnwrap(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
          context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false,
          keyCode: 0))
      opened.surface.responder.keyDown(with: event)
    }
    XCTAssertFalse(opened.surface.responder.tryToPerform(Selector(("copy:")), with: nil))
    XCTAssertEqual(opened.document.version, 0)
    XCTAssertFalse(opened.document.isDirty)
    window.contentView = nil
  }

  /// 本文の丸ごとの置き換え（外部変更の差し替え）は文書へ渡り、戻ったら新しい写しを描く。キャレットは収まる。
  func testReplaceAllReachesTheDocument() throws {
    let opened = try open("0123456789\n")
    opened.surface.selectedRange = NSRange(location: 9, length: 0)
    opened.surface.replaceAll(with: "abc\n")
    XCTAssertEqual(opened.document.text.substring(NSRange(location: 0, length: 4)), "abc\n")
    XCTAssertEqual(opened.surface.material.read().content?.version, opened.document.version)
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 4, length: 0))
  }

  /// 外部変更の差し替えの後は、新しい本文をその本文で開いたときと同じ絵で描く（前の本文の行の組版を持ち越さない）。
  func testReplaceAllDrawsTheNewTextAsAFreshOpenDoes() throws {
    let old = (0..<30).map { "let value\($0) = \($0)" }
    var new = old
    new[3] = "let changed = \"three\""
    new.insert(contentsOf: ["// inserted", "// lines"], at: 10)
    new.remove(at: 20)
    let opened = try open(old.joined(separator: "\n") + "\n", size: CGSize(width: 400, height: 300))
    _ = opened.surface.snapshot()
    opened.surface.replaceAll(with: new.joined(separator: "\n") + "\n")
    XCTAssertTrue(opened.document.waitUntilCaughtUp())
    let fresh = try open(new.joined(separator: "\n") + "\n", size: CGSize(width: 400, height: 300))
    let replaced = try shoot(opened).bytes
    XCTAssertTrue(replaced == (try shoot(fresh).bytes), "開き直したのと同じ絵")
  }

  /// 外観（ライト・ダーク）が変われば、字の色を新しい外観で解き直して描く。
  func testAppearanceChangeRecolorsTheText() throws {
    var style = Self.style()
    style.textColor = NSColor(name: nil) {
      $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .white : .black
    }
    let opened = try open("value value value\n", name: "a.txt", style: style)
    let column = Int(opened.surface.config.columnWidth(lineCount: 2) * 2)
    func textInk() throws -> [UInt8] {
      let (bytes, width) = try shoot(opened)
      return stride(from: 0, to: bytes.count, by: 4).filter { ($0 / 4) % width >= column }
        .map { bytes[$0 + 1] }.filter { $0 != 128 }
    }
    XCTAssertGreaterThan(try textInk().max() ?? 0, 200, "ダークでは白い字")
    opened.surface.view.appearance = NSAppearance(named: .aqua)
    let light = try textInk()
    XCTAssertFalse(light.isEmpty)
    XCTAssertLessThan(light.max() ?? 255, 128, "ライトに変えると黒い字（灰色の地より暗い）")
  }

  /// 描く色空間は窓の色空間（AppKit が今の面を描く色空間）——層の色合わせの宛先・字の色・撮影の絵がそれに従い、窓の
  /// 色空間が変われば解き直す。窓に無ければ sRGB。
  func testDrawsInTheWindowsColorSpace() throws {
    let surface = try open("let a = 1\n").surface
    let srgb = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
    XCTAssertEqual(surface.material.read().space, srgb, "窓に無ければ sRGB")
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.contentView = nil }
    window.colorSpace = .displayP3
    window.contentView = surface.view
    XCTAssertEqual((surface.view.layer as? CAMetalLayer)?.colorspace, p3)
    XCTAssertEqual(surface.material.read().space, p3)
    let keyword = try XCTUnwrap(surface.material.read().palette?.roles[.keyword]).packed
    let expected = try XCTUnwrap(
      NSColor(srgbRed: 0.34, green: 0.61, blue: 0.84, alpha: 1).usingColorSpace(.displayP3))
    XCTAssertEqual(
      [0, 8, 16].map { Int((keyword >> $0) & 0xFF) },
      [expected.redComponent, expected.greenComponent, expected.blueComponent].map {
        Int(($0 * 255).rounded())
      }, "字の色は窓の色空間の値")
    XCTAssertEqual(surface.snapshot()?.colorSpace, p3, "撮影の絵も窓の色空間")
    // 窓が別の色空間の画面へ移ると AppKit が知らせる（色空間を直に置いただけでは知らせないので、同じ知らせを送る）。
    window.colorSpace = .sRGB
    surface.view.viewDidChangeBackingProperties()
    XCTAssertEqual(surface.material.read().space, srgb, "窓の色空間が変われば解き直す")
  }

  /// 本文が右にまだ続くか——描画スレッドが組んだ行で横の範囲が伸びたら、main の操作を待たずに知らせ直す。右端まで
  /// 送れば続かない。
  func testClipsRightTellsWhetherTheTextContinuesToTheRight() throws {
    let narrow = try open("short\n")
    _ = narrow.surface.snapshot()
    pump()
    XCTAssertFalse(narrow.surface.viewport.clipsRight)
    let wide = try open(String(repeating: "x", count: 300) + "\n")
    _ = wide.surface.snapshot()
    pump(until: { wide.surface.viewport.clipsRight }, "組んだ行で範囲が伸びれば知らせ直す")
    wide.surface.scroll(ScrollInput(timestamp: 0, delta: SIMD2(-10_000, 0), precise: false))
    XCTAssertFalse(wide.surface.viewport.clipsRight, "右端まで送れば続かない")
  }

  /// 外部変更の差し替えで、右へ送った横の位置は保つ——最も長い行は新しい写しを描いたコマで測り直し、その範囲に収める。
  func testReplaceAllKeepsTheHorizontalPositionUntilRemeasured() throws {
    let wide = String(repeating: "x", count: 300) + "\n"
    let opened = try open(wide)
    _ = opened.surface.snapshot()
    opened.surface.scrollToVisible(NSRange(location: 250, length: 0))
    let hidden = opened.surface.viewport.hiddenColumns
    XCTAssertGreaterThan(hidden, 0)
    opened.surface.replaceAll(with: "y" + wide)
    XCTAssertEqual(opened.surface.viewport.hiddenColumns, hidden, "差し替えただけでは動かない")
    _ = opened.surface.snapshot()
    pump()
    XCTAssertEqual(opened.surface.viewport.hiddenColumns, hidden, "測り直しても範囲の中なら保つ")
    opened.surface.replaceAll(with: "short\n")
    _ = opened.surface.snapshot()
    pump(until: { opened.surface.viewport.hiddenColumns == 0 }, "短くなれば新しい範囲に収める")
  }

  /// 行の印はオフセットで届き、引いた写しで行へ写す（区間の最後の字の行まで。削除は次の行の上端）。
  func testLineMarksAreMappedToRows() throws {
    let opened = try open("a\nb\nc\nd\n", waitForColors: false)
    opened.document.baseline = "a\nX\nc\nq\nd\n"
    XCTAssertTrue(opened.document.waitUntilCaughtUp())
    let marks = opened.surface.material.read().marks
    XCTAssertEqual(marks.bars, [RowMarks.Bar(rows: 1...1, kind: .modified)])
    XCTAssertEqual(marks.deletions, [RowMarks.Deletion(row: 3, atBottom: false)])
  }

  /// 面が閉じたら、描画スレッドが写しの最後の参照と面ごとの持ち物を手放す（大きな木の解放を main で行わない）——
  /// 描画スレッドが塞がっている間に閉じても、main では写しが残っている。
  func testClosingReleasesTheContentOnTheRenderThread() throws {
    var opened: Opened? = try open("let a = 1\n")
    let id = try XCTUnwrap(opened?.surface.id)
    let material = try XCTUnwrap(opened?.surface.material)
    XCTAssertNotNil(material.read().content)
    let blocked = DispatchSemaphore(value: 0)
    RenderThread.shared.perform { _ in blocked.wait() }
    opened = nil
    XCTAssertNotNil(material.read().content, "main では手放さない")
    blocked.signal()
    let slot = RenderThread.shared.performAndWait { $0.slot(id) == nil }
    XCTAssertTrue(slot, "描画スレッドが面の持ち物を捨てる")
    XCTAssertNil(material.read().content)
  }

  /// 灰色の地に描いた今の位置の 1 コマの画素（BGRA）と幅（px）。
  private func shoot(_ opened: Opened) throws -> (bytes: [UInt8], width: Int) {
    let id = opened.surface.id
    let gray = MTLClearColor(red: 128.0 / 255, green: 128.0 / 255, blue: 128.0 / 255, alpha: 1)
    let image = try XCTUnwrap(
      RenderThread.shared.performAndWait { Transfer(value: $0.snapshot(id, background: gray)) }
        .value)
    return (GlyphPixelTests.pixels(image), image.width)
  }

  /// 描画スレッドからの非同期の知らせを受けるまで main を回す（条件が無ければ 1 巡りだけ）。
  private func pump(
    until condition: () -> Bool = { true }, _ message: String = "", timeout: TimeInterval = 5
  ) {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    } while !condition() && Date() < deadline
    XCTAssertTrue(condition(), message)
  }
}
