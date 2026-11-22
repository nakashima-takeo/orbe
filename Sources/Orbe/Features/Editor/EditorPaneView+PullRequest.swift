import AppKit

/// PR のパネルの結線——行から PR の diff を開く・ツリーかリストかのアプリ全体の選択・焦点・パネルの中のキー（全体への
/// コメント欄の ⌘↵）。
extension EditorPaneView {
  static func pullRequestList(_ panel: PrPanel) -> RowList<PrListSource> {
    RowList(source: PrListSource(panel: panel), rowHeight: Theme.Layout.editorScmRow)
  }

  func wirePullRequest() {
    pullRequest.onOpenDiff = { [weak self] key, opening in self?.openScmDiff(key, opening) }
    pullRequest.onPullRequestChange = { [weak self] in
      self?.reconcileWithLists()
      self?.onPullRequestChange()
    }
    pullRequest.onListStateChange = { [weak self] in self?.reconcileWithLists() }
    pullRequest.onFocusWillClose = { [weak self] in
      guard let self, focusIsInPullRequest else { return }
      reclaimSidebarFocus()
    }
    pullRequest.filesAsTree = { [weak self] in self?.sidebar.pullRequestFilesAsTree ?? true }
    pullRequest.onViewAsTree = { [weak self] asTree in
      self?.sidebar.setPullRequestFilesAsTree(asTree)
    }
  }

  /// PR のパネルが見えている（左の列が開いていて、PR のパネルを出している）。
  var showsPullRequest: Bool { sidebar.isOpen && shell.panel == .pullRequest }

  /// PR のパネルの中のキー——全体へのコメント欄の ⌘↵ はレビューの送信（送れなければ音で断る）。変換中なら確定してから送る。
  /// 押し続けたキーリピートは食って何もしない。扱ったら true。
  func handlePullRequestKey(_ event: NSEvent) -> Bool {
    guard showsPullRequest, focusIsInSidebar, pullRequest.isReviewFieldFocused else { return false }
    guard event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.command]
    else { return false }
    switch event.specialKey {
    case .carriageReturn?, .enter?, .newline?:
      if event.isARepeat { return true }
      if !pullRequest.submitReview() { NSSound.beep() }
      return true
    default: return false
    }
  }

  /// 焦点が PR のパネルの列か全体へのコメント欄にあるか（列のために面が預かっている焦点を含む）。
  var focusIsInPullRequest: Bool {
    showsPullRequest && focusIsInSidebar
      && (pullRequest.isListFocused || pullRequest.isReviewFieldFocused
        || heldListFocus == .pullRequest)
  }
}
