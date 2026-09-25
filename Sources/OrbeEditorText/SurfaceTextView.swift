import AppKit
import OrbeEditorCore
import STTextView

/// first responder の出入りを契約へ上げ、URL の ⌘クリックと ⌘押下中の指カーソルを持つ STTextView。上流の
/// `mouseDown` は shift・control・option を読み ⌘ は読まないので、⌘だけを付けたクリックを先取りしても
/// 衝突しない（⌘⇧・⌥⌘・⌃⇧⌘ は上流の選択操作に渡す）。当たりは描画と同じ geometry（`VisibleLines`）で解く。
/// 開くのは mouse-up——押した URL の上で離せば開き、ドラッグして外れれば何もしない（macOS の慣習）。
/// その間は上流に渡さず、選択を伸ばさない。
final class SurfaceTextView: STTextView {
  var onFocusChange: ((Bool) -> Void)?
  var onOpenLink: ((URL) -> Void)?
  var caretSize = CGSize(width: 1, height: 14)
  /// ⌘で押した URL（離すまで）。
  private var pendingLink: PendingLink?
  /// 押してから離すまでにこれ以上動けばドラッグ。
  private static let clickSlop: CGFloat = 4

  private struct PendingLink {
    let url: URL
    let locationInWindow: NSPoint
  }

  /// キャレット——選択の動く側の端（TextKit 2 は前へ伸ばした選択を upstream の向きで持つ）。
  var caretLocation: Int {
    let range = textSelection
    let upstream = textLayoutManager.textSelections.first?.affinity == .upstream
    return range.length > 0 && upstream ? range.location : NSMaxRange(range)
  }

  /// 選択を置く。`upstream` なら動く側の端は先頭（前へ伸ばした選択）。
  func select(_ range: NSRange, upstream: Bool) {
    guard let textRange = NSTextRange(range, in: textContentManager) else { return }
    textLayoutManager.textSelections = [
      NSTextSelection(
        range: textRange, affinity: upstream ? .upstream : .downstream, granularity: .character)
    ]
    needsLayout = true
  }

  /// Esc（変換中でない。変換中は input context が先に飲む）は面では使わない——上流は補完を開くが、面は補完を持たない。
  /// 上の responder へ渡し、載せる側が使えるようにする。
  override func cancelOperation(_ sender: Any?) {
    nextResponder?.tryToPerform(#selector(cancelOperation(_:)), with: sender)
  }

  /// 押している間に view が窓から外れると mouse-up は届かない（文書の切り替えが面を外す）ので、ラッチは
  /// 次の押下でも解く。input context へは上流と同じく先に通すが、同じイベントを 2 回渡さない（上流に落ちる
  /// クリックは上流が通す）。
  override func mouseDown(with event: NSEvent) {
    pendingLink = nil
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if flags.contains(.command), flags.isDisjoint(with: [.shift, .option, .control]),
      event.clickCount == 1,
      let url = VisibleLines(textView: self).link(at: convert(event.locationInWindow, from: nil))
    {
      guard (inputContext?.handleEvent(event) ?? false) == false else { return }
      pendingLink = PendingLink(url: url, locationInWindow: event.locationInWindow)
      return
    }
    super.mouseDown(with: event)
  }

  override func mouseDragged(with event: NSEvent) {
    guard pendingLink == nil else { return }
    super.mouseDragged(with: event)
  }

  override func mouseUp(with event: NSEvent) {
    guard let pending = pendingLink else {
      super.mouseUp(with: event)
      return
    }
    pendingLink = nil
    let moved = hypot(
      event.locationInWindow.x - pending.locationInWindow.x,
      event.locationInWindow.y - pending.locationInWindow.y)
    guard moved <= Self.clickSlop,
      VisibleLines(textView: self).link(at: convert(event.locationInWindow, from: nil))
        == pending.url
    else { return }
    onOpenLink?(pending.url)
  }

  /// 指カーソルは ⌘ を押している間だけ。上流はスクロール・編集でカーソル矩形を捨てないので、面が layout の
  /// たびに捨て直す。
  override func resetCursorRects() {
    super.resetCursorRects()
    guard NSEvent.modifierFlags.contains(.command) else { return }
    let geometry = VisibleLines(textView: self)
    for line in geometry.lines(in: visibleRect) {
      for link in geometry.links(in: line) { addCursorRect(link.frame, cursor: .pointingHand) }
    }
  }

  override func flagsChanged(with event: NSEvent) {
    window?.invalidateCursorRects(for: self)
    super.flagsChanged(with: event)
  }

  /// End（fn+→）は最後の 1 画面を見せる。上流は文書の下端へ送り clip の上限で縮まる前提で、最終行を最上段まで送れる
  /// 範囲では最終行だけが残ってしまう（VS Code も最終行を下端に出すだけ）。上流の relocate と layout は上流に任せる。
  override func scrollToEndOfDocument(_ sender: Any?) {
    super.scrollToEndOfDocument(sender)
    let height = enclosingScrollView?.contentView.bounds.height ?? visibleRect.height
    scroll(CGPoint(x: visibleRect.minX, y: max(0, frame.maxY - height)))
  }

  override func becomeFirstResponder() -> Bool {
    let result = super.becomeFirstResponder()
    if result { onFocusChange?(true) }
    return result
  }

  override func resignFirstResponder() -> Bool {
    let result = super.resignFirstResponder()
    if result { onFocusChange?(false) }
    return result
  }
}

/// viewport のレイアウト完了を受けるプラグイン。
struct ViewportPlugin: STPlugin {
  let onLayout: (NSTextRange?) -> Void

  func setUp(context: any Context) {
    context.events.onDidLayoutViewport(onLayout)
  }
}
