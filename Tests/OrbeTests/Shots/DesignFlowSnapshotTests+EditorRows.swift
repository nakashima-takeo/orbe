import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// 差し込みの flow（fixture は gallery と同じ `EditorCodeFixtures` の長い文書）。ミニマップを出さない構成の本物のコードに、
/// 文書に無い行（先頭の前・途中・最終行の後）と試しのスレッドの区画（見本 D 節の構成——枠・影・頭・アバター・折り返す
/// 日本語の本文とインラインコード・関連コミット・返信の入力欄と 2 つのボタン）を置き、下の行・行番号・git の印が差し込みの
/// 高さだけ下がること、縦に送ると区画が本文と一緒に動き上端の影が区画の上に出ること、ボタンのホバー、区画の文の選択
/// （焦点のある色）と焦点の無い色の本文の選択、入力欄が主で日本語の未確定の文字がある状態、横に送ると区画は動かず横
/// スクロールバーが区画の上に出ること、最後まで送ると最終行の後の差し込みが最上段に来ること、light の外観の区画を撮る。
extension DesignFlowSnapshotTests {
  func testEditorRows() throws {
    let (scene, document) = try longScene()
    defer { scene.cleanup() }
    let flow = RowsFlow(surface: try engine(document), document: document) {
      self.settleFades(scene.pane)
    }
    try hostedFlow(
      "editor_rows", scene,
      steps: [
        ("inserted", flow.insert),
        ("scrolled", { flow.scroll(toFirstLine: 34.5) }),
        ("thread", flow.showThread),
        ("hover", flow.hover),
        ("selection", flow.select),
        ("composing", flow.compose),
        ("scrolled_right", flow.scrollRight),
        ("end", flow.scrollToEnd),
        ("thread_light", flow.showThreadInLight),
      ])
  }
}

/// 差し込みの flow の各ステップ。
@MainActor
private struct RowsFlow {
  let surface: MetalTextSurface
  let document: EditorDocument
  let thread = SampleThreadZone.sample(line: 41, id: "flow-reply")
  let settleFades: () -> Void

  init(surface: MetalTextSurface, document: EditorDocument, settleFades: @escaping () -> Void) {
    self.surface = surface
    self.document = document
    self.settleFades = settleFades
    thread.surface = surface
  }

  private var zone: ObjectIdentifier { ObjectIdentifier(thread) }
  private var lineHeight: Double { Double(surface.config.lineHeight) }
  private var zoneTop: Double { surface.rows.top(ofBlock: surface.rows.block(ofZone: zone) ?? 0) }

  private func settle() {
    surface.flush()
    settleFades()
  }

  /// 区画の中の点の、面の view の座標。
  private func point(_ local: CGPoint) -> CGPoint {
    CGPoint(
      x: surface.surfaceLayout.text.minX + local.x,
      y: surface.config.topInset + CGFloat(zoneTop - surface.scrollPosition.y) + local.y)
  }

  func insert() {
    let removed = { (lines: [String]) in lines.map(InsertedLine.init) }
    surface.setPresentation(SurfacePresentation(showsMinimap: false))
    surface.setRows(
      SurfaceRows(insertions: [
        RowInsertion(line: 0, content: .lines(removed(["// removed header"]))),
        RowInsertion(
          line: 6,
          content: .lines(removed(["  private var cache: [Int: Int] = [:]", "  // removed"]))),
        RowInsertion(line: 40, content: .zone(thread)),
        RowInsertion(
          line: document.text.lineCount, content: .lines(removed(["// removed footer"]))),
      ]))
    settle()
  }

  func scroll(toFirstLine line: CGFloat) {
    surface.scroll(toFirstLine: line)
    settle()
  }

  func showThread() {
    scroll(toFirstLine: CGFloat((zoneTop - 3 * lineHeight) / lineHeight))
  }

  func hover() {
    let button = surface.zones[zone]?.hits.buttons.first { $0.id == SampleThreadZone.resolve }
    surface.hover(at: button.map { point(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) })
    settle()
  }

  /// 本文の 2 行を選んだ後に、コメントの本文の 1 行目の途中から 2 行目の途中までを選ぶ（区画の文が主——焦点のある色、
  /// 本文の選択は焦点の無い色）。
  func select() {
    surface.hover(at: nil)
    surface.updateFocus(true)
    let text = document.text
    surface.selectedRange = NSRange(
      location: text.lineStart(37), length: text.lineEnd(38) - text.lineStart(37))
    guard let entry = surface.zones[zone] else { return XCTFail("前提: 区画がある") }
    let lines = entry.hits.lines.filter { $0.text == AnyHashable("body-0") }
    guard lines.count >= 2 else { return XCTFail("前提: 本文が 2 行以上に折り返す") }
    surface.inputScope {
      surface.beginZoneSelection(
        entry, text: lines[0].text, offset: lines[0].range.location + 5, clicks: 1,
        extending: false)
      surface.extendZoneSelection(
        to: point(CGPoint(x: lines[1].origin.x + 60, y: lines[1].origin.y - 4)))
    }
    settle()
  }

  /// 入力欄を主にし、文の末尾で日本語を変換している状態（IME の呼び出しを面へ流す）。
  func compose() {
    surface.focus(thread.field)
    let site = surface.fields[thread.field.id]
    surface.inputScope {
      site?.editor.select(CursorList(Cursor(thread.field.text.length)), reveal: .none)
    }
    surface.textView.setMarkedText(
      "へんしん", selectedRange: NSRange(location: 4, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    settle()
  }

  /// 区画の下端の近くを見せて横に送る（区画は横に動かず、横スクロールバーが区画の上に出る）。
  func scrollRight() {
    surface.commitMarkedText()
    let viewport = surface.scrollState().limits.viewport.y
    surface.scroll(toFirstLine: CGFloat((zoneTop - viewport + 120) / lineHeight))
    surface.scroll(toX: 40 * surface.config.cell)
    settle()
  }

  func scrollToEnd() {
    surface.scroll(toX: 0)
    scroll(toFirstLine: .greatestFiniteMagnitude)
  }

  /// 窓を light の外観にして区画を見せる（区画の色は面の外観で解き直す）。
  func showThreadInLight() {
    surface.view.window?.appearance = NSAppearance(named: .aqua)
    showThread()
  }
}
