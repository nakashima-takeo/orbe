import AppKit

/// 俯瞰（ミニマップ・縦横のスクロールバー）の区画の押下を受ける、面の view の子。面の view と同じ大きさで重なるが、当たる
/// のは俯瞰の区画の上だけ（本文の上は面の view が受ける）。焦点を取らないので、俯瞰を押しても窓は焦点を面へ移さない——
/// 検索バーで打っていた続きが本文に入らない。押下とドラッグは面の view の入口へそのまま渡し、ホイールと右クリックは
/// 応答の連鎖で面の view へ流れる。描かない（層の中身を持たない）。
final class OverviewHitView: NSView {
  override var acceptsFirstResponder: Bool { false }
  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override func updateLayer() {}

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let face = superview as? MetalTextView, face.overview.area(at: point) != nil else {
      return nil
    }
    return self
  }

  override func mouseDown(with event: NSEvent) { superview?.mouseDown(with: event) }
  override func mouseDragged(with event: NSEvent) { superview?.mouseDragged(with: event) }
  override func mouseUp(with event: NSEvent) { superview?.mouseUp(with: event) }
}
