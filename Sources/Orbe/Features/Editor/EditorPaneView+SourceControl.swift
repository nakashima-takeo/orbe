import AppKit
import OrbeEditorCore

/// ソース管理パネルの結線——行から diff・ファイルを開く・破棄の確認・パネルの中のキー（メッセージ欄の ⌘↵・列の ⌘↑）。
extension EditorPaneView {
  func wireSourceControl() {
    scm.onOpenDiff = { [weak self] key, opening in self?.openScmDiff(key, opening) }
    scm.onOpenFile = { [weak self] url in self?.open(url, as: .pinned) }
    scm.onDiscard = { [weak self] files in self?.confirmDiscard(files) }
  }

  /// ソース管理パネルが見えている（サイドバーが開いていて、ソース管理のパネルを出している）。
  var showsSourceControl: Bool { sidebar.isOpen && sidebar.panel == .sourceControl }

  /// 焦点がソース管理パネルの中（メッセージ欄か列）にあるか。
  var focusIsInSourceControl: Bool {
    showsSourceControl && focusIsInSidebar && scm.focusedArea != nil
  }

  /// 行の diff を `opening` の開き方で開く。本文へ焦点を移す開き方でなければ焦点に触らない（列に残る。遅れて走るキーの開きが、
  /// その間に人が移した焦点を奪わない）。
  func openScmDiff(_ key: EditorDiff.Key, _ opening: ScmPanel.Opening) {
    guard let group else { return }
    do {
      _ = try group.editor.openDiff(key, as: opening.mode)
    } catch {
      NSSound.beep()
      return
    }
    tree.reveal(key.url)
    if opening.focusesText {
      layoutSubtreeIfNeeded()
      focusEditor()
    }
  }

  /// 破棄。追跡中を含めば確認のシートを出し、確認した行をそのまま渡す（応答までに status が変わっても、根のサービスが呼んだ
  /// 時点の index で選び直す）。未追跡だけならそのままゴミ箱へ。
  func confirmDiscard(_ files: [ScmChanges.File]) {
    let control = scm.control
    let rows = files.map(\.row)
    guard ScmDiscardGate.needsConfirmation(files), let window else {
      control.discard(rows)
      return
    }
    let alert = ScmDiscardGate.alert(files, language: localization.language)
    alert.beginSheetModal(for: window) { response in
      if ScmDiscardGate.shouldDiscard(response) { control.discard(rows) }
    }
  }

  /// ソース管理パネルの中のキー（メッセージ欄の ⌘↵・列の ⌘↑）。扱ったら true。
  ///
  /// ⌘↵ はコミットだけ——ボタンが同期・公開に替わっていてもネット操作は起こさず、コミットできなければ音で断る。変換中なら
  /// 確定してからコミットする（chrome キーと同じ規則）。
  func handleSourceControlKey(_ event: NSEvent) -> Bool {
    guard focusIsInSourceControl else { return false }
    let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
    guard flags == [.command] else { return false }
    switch event.specialKey {
    case .carriageReturn?, .enter?, .newline?:
      guard scm.focusedArea == .message else { return false }
      if let text = window?.firstResponder as? NSTextView, text.hasMarkedText() {
        text.unmarkText()
        text.inputContext?.discardMarkedText()
      }
      if scm.commitState.canCommit {
        scm.control.commit()
      } else {
        NSSound.beep()
      }
      return true
    case .upArrow?:
      guard scm.focusedArea == .list else { return false }
      scm.returnToMessageIfAtTop()
      return true
    default:
      return false
    }
  }
}
