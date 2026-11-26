import AppKit
import OrbeEditorCore

/// ソース管理パネルの結線——行から diff・ファイルを開く・破棄の確認・親を畳むときの焦点・列の ⌘↑（コミットのポップアップを
/// 開く）。
extension EditorPaneView {
  func wireSourceControl() {
    scm.onOpenDiff = { [weak self] key, opening in self?.openScmDiff(key, opening) }
    scm.onChangesDidApply = { [weak self] emptied in self?.changesDidApply(emptied: emptied) }
    scm.onOpenFile = { [weak self] url in self?.open(url, as: .pinned) }
    scm.onDiscard = { [weak self] files in self?.confirmDiscard(files) }
    scm.onListStateChange = { [weak self] in self?.reconcileWithLists() }
    scm.onRepositoryWillClose = { [weak self] in
      guard let self, focusIsInSourceControl else { return }
      reclaimSidebarFocus()
    }
    scm.autoFetchEnabled = { [weak self] in self?.settings()[SettingKeys.scmAutoFetch] ?? false }
    commitPopup.language = { [weak self] in self?.localization.language ?? .systemDefault }
  }

  /// ソース管理の件数と行の組が差し替わった。件数が 1 以上から 0 になったら Changes の diff を閉じ、本体の diff を整合させ、
  /// 開いている変更ファイルの一覧の中身を作り直す。
  private func changesDidApply(emptied: Bool) {
    if emptied { group?.editor.closeDiff(on: .changes) }
    reconcileWithLists()
    refreshCurrentItem()
  }

  /// 面の workspace の実効設定が変わった（裏の fetch を欲しがるか決め直す）。
  func settingsDidChange() {
    scm.decideAutoFetch()
  }

  /// ソース管理パネルが見えている（左の列が開いていて、ソース管理のパネルを出している）。
  var showsSourceControl: Bool { sidebar.isOpen && shell.panel == .sourceControl }

  /// 焦点がソース管理パネルの変更の列（列のために面が預かっている焦点を含む）にあるか。
  var focusIsInSourceControl: Bool {
    showsSourceControl && focusIsInSidebar && (scm.isListFocused || heldListFocus == .changes)
  }

  /// 行の diff を開き、その種類の画面（作業ツリー・ステージ済みは Changes、PR は PR）を選ぶ。開けなければ beep し、画面を
  /// 選ばない。本文へ焦点を移す開き方でなければ焦点に触らない（列に残る。遅れて走るキーの開きが、その間に人が移した焦点を
  /// 奪わない）。
  func openScmDiff(_ key: EditorDiff.Key, _ opening: ScmPanel.Opening) {
    guard let group else { return }
    do {
      try openDiff(key)
    } catch {
      NSSound.beep()
      return
    }
    group.editor.selectScreen(key.kind.screen)
    if opening.focusesText {
      layoutSubtreeIfNeeded()
      focusEditor()
    }
  }

  /// 破棄。戻すパスを含めば面の中の確認を出し、「破棄」で、確認した中身（見えていた行と行き先）をそのまま渡す（確定までに
  /// status が変わっても、根のサービスが呼んだ時点の index で選び直し、見えていた行き先と違えば断る）。ゴミ箱へ移すものだけなら
  /// そのまま。
  func confirmDiscard(_ files: [ScmChanges.File]) {
    let scm = self.scm
    let content = ScmDiscardGate.content(files)
    guard ScmDiscardGate.needsConfirmation(files) else {
      scm.discard(content)
      return
    }
    confirm.show(ScmDiscardGate.confirmation(files, language: localization.language)) {
      scm.discard(content)
    }
  }

  /// 変更の列の ⌘↑——どの行を選んでいても、何も選んでいなくても、コミットのポップアップを開く（開いていれば何もしない）。
  /// 扱ったら true。
  func handleSourceControlKey(_ event: NSEvent) -> Bool {
    guard focusIsInSourceControl, scm.isListFocused else { return false }
    let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
    guard flags == [.command], event.specialKey == .upArrow else { return false }
    popup.open(commitPopup)
    return true
  }
}
