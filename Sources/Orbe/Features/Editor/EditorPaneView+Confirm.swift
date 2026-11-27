import AppKit

/// 面の中の確認——面の最前面の host に幕とダイアログを出し、出ている間は host がフォーカスを持つ。窓のシートと違い、窓の
/// キーとフォーカスを止めないので、面のほかの経路が幕の裏へキーとフォーカスを動かさないようにする仕事は、面が持つ:
/// host の配下は本体のフォーカスに数えない（本体が替わってもフォーカスを動かさない）、フォーカスが host の外へ移ったら
/// キャンセルで閉じる、host にフォーカスがある間の ⌘ つきのキーは窓のキーだけを通す（→ `EditorPaneView+Keys`）、面が
/// 隠れた・画面や根が替わったらキャンセルで閉じる。閉じたら、きっかけが求めれば、出す前の場所へフォーカスを戻す。
/// 出ている間、面のアクセシビリティの子は確認の host だけ——幕の裏（上のバー・本体・左の列）を VoiceOver から隠す。
extension EditorPaneView {
  func wireConfirm() {
    confirm.onShow = { [weak self] in self?.confirmDidShow() }
    confirm.onClose = { [weak self] dismissal in self?.confirmDidClose(dismissal) }
  }

  func confirmRoot() -> EditorConfirmRoot {
    EditorConfirmRoot(
      confirm: confirm, localization: localization,
      translucency: translucency ?? ChromeTranslucency())
  }

  /// フォーカスが面の中の確認の host の配下にあるか。
  var focusIsInConfirm: Bool {
    guard let responder = window?.firstResponder as? NSView else { return false }
    return responder.isDescendant(of: confirmHost)
  }

  /// 出した。一覧の器とポップアップを閉じ、出す前のフォーカスの場所（ポップアップが開いていれば、それを開く前の場所）を
  /// 覚え、一覧のためのフォーカスの預かりを終え、host を見せてフォーカスを移し、面の中身が替わったことをアクセシビリティに
  /// 知らせてから、フォーカスの行き先の見張りを始める
  /// ——外へ移ったらキャンセルで閉じ（フォーカスには触れない）、窓そのものへ落ちたらキャンセルで閉じて覚えた場所へ戻す。
  private func confirmDidShow() {
    let place = popup.isOpen ? popupReturn : focusPlace
    if itemList.isOpen { itemList.close(.otherOpened) }
    popup.close(.otherOpened)
    confirmReturn = place
    endListFocusHold()
    confirmHost.isHidden = false
    confirmHost.didShow()
    needsLayout = true
    layoutSubtreeIfNeeded()
    window?.makeFirstResponder(confirmHost)
    NSAccessibility.post(
      element: self, notification: .layoutChanged, userInfo: [.uiElements: [confirmHost]])
    confirmFocusWatch = watchFocus(
      in: confirmHost, onLeave: { [weak self] in self?.confirm.close(.focusLeft) },
      onFall: { [weak self] in self?.confirm.close(.itemGone) })
  }

  /// 閉じた。見張りをやめ、きっかけが求めれば覚えた場所へフォーカスを戻してから、host を隠す——フォーカスを持ったまま
  /// 隠すと、フォーカスが窓へ落ちる。
  private func confirmDidClose(_ dismissal: EditorDismissal) {
    confirmFocusWatch = nil
    containerDidClose(dismissal)
    if dismissal.returnsFocus { returnFocus(to: confirmReturn) }
    confirmHost.didClose()
    confirmHost.isHidden = true
    NSAccessibility.post(element: self, notification: .layoutChanged)
  }

  override func accessibilityChildren() -> [Any]? {
    confirm.isShown ? [confirmHost] : super.accessibilityChildren()
  }
}
