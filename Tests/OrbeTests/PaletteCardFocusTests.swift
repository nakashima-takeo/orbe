import AppKit
import XCTest

@testable import Orbe

/// `PaletteCard` の focus 宛先常設（入力欄を `fieldVisible` に依らず mount し続ける）の検証。
///
/// 宛先が同じ更新 pass で新規 mount されると SwiftUI はその pass で当てた `@FocusState` を取りこぼし、
/// first responder が常設のカード器に残る。器は `fieldVisible` のとき ←→↵ を入力欄へ委ねて `.ignored`
/// を返すため、**↑↓ だけ効いて ↵（決定）と →（ドリルイン）が誰にも届かない**状態になる
/// ——ドリルイン→Esc 復帰でパレットが半死にした退行がこれ。実キーイベントを並べない窓へ流して固定する。
@MainActor
final class PaletteCardFocusTests: PaletteCardWindowTestCase {
  /// パレットモデルが `setMode` で行う立て下げ（選択・クエリ・入力欄可視・行・focusToken）の順序を再現する。載せた後に
  /// 呼ぶときは、載せた窓を渡す。渡した窓では、モデルを変えた後の更新まで走らせる。
  private func setMode(
    _ model: PaletteModel, fieldVisible: Bool, breadcrumb: String?, rows: Int,
    in window: NSWindow? = nil
  ) {
    model.selected = 0
    model.query = ""
    model.fieldVisible = fieldVisible
    model.fieldIsFilter = fieldVisible
    model.breadcrumb = breadcrumb
    model.rows = (0..<rows).map { .init(label: "row\($0)") }
    model.focus()
    if let window { flush(window) }
  }

  /// ドリルイン（入力欄なし）→ Esc 復帰（入力欄あり）の後も ↵ と → が入力欄へ届く。
  /// 入力欄が新規 mount されると focus を取りこぼし、この 2 つだけが死ぬ（↑↓ は器が捕捉するので生き残る）。
  func testKeyIntentsSurviveDrillInAndBack() {
    var log: [String] = []
    let model = PaletteModel()
    model.onDown = { log.append("down") }
    model.onActivate = { log.append("activate") }
    model.onRight = {
      log.append("right")
      return true
    }
    setMode(model, fieldVisible: true, breadcrumb: nil, rows: 5)
    let window = mount(model)
    model.focus()  // 提示元が次 tick で focus を再確定する経路（パレットを開く定石）
    flush(window)

    log = []
    send(125, "\u{F701}", to: window)  // ↓
    send(124, "\u{F703}", to: window)  // →
    send(36, "\r", to: window)  // ↵
    XCTAssertEqual(log, ["down", "right", "activate"], "前提: 入力欄ありモードで 3 キーとも届く")

    setMode(model, fieldVisible: false, breadcrumb: "‹ parent", rows: 3, in: window)  // ドリルイン
    log = []
    send(125, "\u{F701}", to: window)
    send(124, "\u{F703}", to: window)
    send(36, "\r", to: window)
    XCTAssertEqual(log, ["down", "right", "activate"], "入力欄なしモードでは器が 3 キーとも捕捉する")

    setMode(model, fieldVisible: true, breadcrumb: nil, rows: 5, in: window)  // Esc 復帰
    log = []
    send(125, "\u{F701}", to: window)
    send(124, "\u{F703}", to: window)
    send(36, "\r", to: window)
    XCTAssertEqual(
      log, ["down", "right", "activate"],
      "復帰後も ↵（決定）と →（ドリルイン）が届く＝入力欄が新規 mount されず focus を取りこぼさない")
  }

  /// 復帰後に打鍵で絞り込めること（focus が入力欄に在ることの直接の証拠）。
  func testTypingReachesFieldAfterDrillInAndBack() {
    let model = PaletteModel()
    setMode(model, fieldVisible: true, breadcrumb: nil, rows: 5)
    let window = mount(model)
    model.focus()
    flush(window)

    setMode(model, fieldVisible: false, breadcrumb: "‹ parent", rows: 3, in: window)
    setMode(model, fieldVisible: true, breadcrumb: nil, rows: 5, in: window)
    send(0, "a", to: window)
    XCTAssertEqual(model.query, "a", "復帰後の打鍵が絞り込み欄へ届く")
  }
}
