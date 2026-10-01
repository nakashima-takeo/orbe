import AppKit
import OrbeEditorCore

/// アウトラインの結線——文書にアウトラインが要るかを告げ、行の操作から本文へ飛ぶ。
extension EditorPaneView {
  func wireOutline() {
    outline.onJump = { [weak self] symbol, token, jump in
      self?.jumpToSymbol(symbol, token: token, jump: jump)
    }
  }

  /// アウトラインが見えている（開いていて、サイドバーがエクスプローラーを出していて、面が画面に見えている）。
  var showsOutline: Bool {
    sidebar.isOutlineOpen && sidebar.isOpen && sidebar.panel == .files && window != nil
      && !isHiddenOrHasHiddenAncestor
  }

  /// 焦点の文書にアウトラインが要るかを告げる（要るのは見えている間の焦点の文書だけ。閉じている間は何も取り出さない）。
  func updateOutlineWant() {
    document?.wantsOutline = showsOutline
  }

  /// 焦点がアウトライン（行の列か絞り込みの欄）にあるか。
  var focusIsInOutline: Bool {
    (window?.firstResponder as? NSView)?.isDescendant(of: outlineList) == true
  }

  /// シンボルへ飛ぶ——名前の頭（ダブルクリックは範囲全体）を選び、画面の外なら上寄せで見せ、画面の中なら縦は動かさない
  /// （`TextReveal.nearTopIfOutside`。VS Code の revealRangeNearTopIfOutsideViewport）。横は隠れていれば寄せる。Enter と
  /// ダブルクリックは焦点を本文へ移し、単クリックは焦点をアウトラインに残す。結果の印が今の結果と違えば何もしない（次の
  /// 結果で列が作り直される）。
  func jumpToSymbol(_ symbol: Int, token: OutlineToken, jump: EditorOutline.Jump) {
    guard let document else { return }
    let target: NSRange
    if jump == .range {
      guard let range = document.outlineRange(of: symbol, in: token) else { return }
      target = range
    } else {
      guard let name = document.outlineNameRange(of: symbol, in: token) else { return }
      target = NSRange(location: name.location, length: 0)
    }
    layoutSubtreeIfNeeded()
    document.surface.selectedRange = target
    document.surface.reveal(target, policy: .nearTopIfOutside)
    if jump != .name { window?.makeFirstResponder(document.surface.responder) }
  }
}
