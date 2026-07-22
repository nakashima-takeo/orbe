import AppKit
import SwiftUI

/// パレットの入力モダリティ。`.keyboard` 中はホバー追従を抑制し、スクロールで行がカーソル下へ来ても
/// 選択を奪わない。実マウス移動（`MouseMovedDetector`）でのみ `.pointer` へ移る。
/// 汎用パレット（`PaletteModel`）と Dispatch（`DispatchPaletteModel`）が共有する。
enum InputModality { case keyboard, pointer }

/// 選択インデックスと入力モダリティの束（ホバー追従ガードの本体・パレット共通）。
/// **ホバー以外の代入（キー移動・絞り込みでのリセット・タップ）は必ず `.keyboard` へ戻す**——
/// 選択を置いた側が意図を持っている以上、実マウス移動があるまでホバーに奪わせない。
/// 代入経路が増えても取りこぼさないよう、ガードは `index` の setter に集約する。
/// ホバー追従は代入でなく `hoverSelect(_:)` を通す（＝モダリティを維持する唯一の経路）。
struct ModalSelection {
  private var storage = 0

  var index: Int {
    get { storage }
    set {
      storage = newValue
      modality = .keyboard
    }
  }

  /// 初期値 `.keyboard`（開いた直後の初期選択を hover に奪われない）。実マウス移動で `.pointer`。
  var modality: InputModality = .keyboard

  /// ホバー開始による選択追従。`.pointer` のときだけ効き、モダリティは動かさない。
  mutating func hoverSelect(_ i: Int) {
    guard modality == .pointer else { return }
    storage = i
  }

  /// 裏の再取得で行がずれたときの選択の追い直し。ユーザの意図ではないのでモダリティは動かさない。
  mutating func restore(_ i: Int) { storage = i }
}

/// 窓全面を覆う透明 NSView。`.mouseMoved` トラッキングエリアで実ポインタ移動のみ拾い、`onMove` を呼ぶ。
/// スクロールで行がカーソル下を横切る SwiftUI onHover と違い、mouseMoved は物理移動でのみ発火するため、
/// パレットの入力モダリティ（キーボード↔ポインタ）を確実に区別できる（→ PaletteModel.InputModality）。
/// `hitTest` は nil を返してクリック/スクロールを背後へ素通りさせる（トラッキングは hitTest と独立）。
/// ライフサイクルはビューに束ね、パレット表示中のみ存在する（全体フラグやグローバルモニタを触らない）。
struct MouseMovedDetector: NSViewRepresentable {
  let onMove: () -> Void

  func makeNSView(context: Context) -> TrackingView {
    let view = TrackingView()
    view.onMove = onMove
    return view
  }

  func updateNSView(_ nsView: TrackingView, context: Context) {
    nsView.onMove = onMove
  }

  final class TrackingView: NSView {
    var onMove: () -> Void = {}

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      trackingAreas.forEach(removeTrackingArea)
      addTrackingArea(
        NSTrackingArea(
          rect: bounds,
          options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
          owner: self))
    }

    override func mouseMoved(with event: NSEvent) { onMove() }
  }
}
