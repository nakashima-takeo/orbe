import AppKit
import GhosttyKit

// MARK: - NSTextInputClient（IME 連携）

/// interpretKeyEvents から呼ばれる IME プロトコル実装。
/// 状態（markedText / keyTextAccumulator）と preedit 反映（syncPreedit）は SurfaceView 本体が持つ。
extension SurfaceView: NSTextInputClient {
  func hasMarkedText() -> Bool { markedText.length > 0 }

  func markedRange() -> NSRange {
    markedText.length > 0
      ? NSRange(location: 0, length: markedText.length)
      : NSRange(location: NSNotFound, length: 0)
  }

  func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    let wasEmpty = markedText.length == 0
    switch string {
    case let s as NSAttributedString: markedText = NSMutableAttributedString(attributedString: s)
    case let s as String: markedText = NSMutableAttributedString(string: s)
    default: markedText = NSMutableAttributedString()
    }
    // preedit 開始（空→非空）で補完 popup を抑止する。未確定文字は $BUFFER に
    // 未反映のため confirmed buffer 基準の候補は誤誘導。確定で $BUFFER が動けば update が再表示する。
    if wasEmpty, markedText.length > 0 { completionEnd() }
    syncPreedit()
  }

  func unmarkText() {
    markedText = NSMutableAttributedString()
    syncPreedit()
  }

  func insertText(_ string: Any, replacementRange: NSRange) {
    let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    unmarkText()  // 確定したので preedit を消す
    if keyTextAccumulator != nil {
      keyTextAccumulator?.append(text)  // keyDown 経由は keyAction がキーとして送る
    } else if let surface = surfacePtr {
      // keyDown 外（音声入力・ペースト等）。テキストとして直接送る。
      text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
    }
  }

  func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
    -> NSAttributedString?
  {
    guard markedText.length > 0, let r = Range(range, in: markedText.string) else { return nil }
    return markedText.attributedSubstring(from: NSRange(r, in: markedText.string))
  }

  func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

  func characterIndex(for point: NSPoint) -> Int { NSNotFound }

  /// 候補ウィンドウの表示位置。libghostty の ime_point（surface 内・top-left 原点の
  /// カーソル矩形）を NSView（bottom-left）→ スクリーン座標へ変換して返す。
  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    guard let surface = surfacePtr, let window else { return .zero }
    var x = 0.0
    var y = 0.0
    var w = 0.0
    var h = 0.0
    ghostty_surface_ime_point(surface, &x, &y, &w, &h)
    let viewRect = NSRect(x: x, y: bounds.height - y - h, width: w, height: h)
    return window.convertToScreen(convert(viewRect, to: nil))
  }

  /// interpretKeyEvents 経由の Enter・Backspace 等は keyAction が生キーとして送るので、
  /// ここでは何もしない（未実装アクションの NSBeep も抑制する）。
  override func doCommand(by selector: Selector) {}

  /// markedText の現状を libghostty に preedit として反映する（ghostty が下線付きで描画）。
  func syncPreedit() {
    guard let surface = surfacePtr else { return }
    if markedText.length > 0 {
      let s = markedText.string
      s.withCString { ghostty_surface_preedit(surface, $0, UInt(s.utf8.count)) }
    } else {
      ghostty_surface_preedit(surface, nil, 0)
    }
  }
}
