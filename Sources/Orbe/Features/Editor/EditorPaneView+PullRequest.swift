import AppKit

/// PR のパネルとレビューのポップアップの結線——行から PR の diff を開く・ツリーかリストかのアプリ全体の選択・焦点・パネルの
/// 中のキー（列の ⌘↑）・未送信のコメントの行からその場所へ移る。
extension EditorPaneView {
  static func pullRequestList(_ panel: PrPanel) -> RowList<PrListSource> {
    RowList(source: PrListSource(panel: panel), rowHeight: Theme.Layout.editorScmRow)
  }

  func wirePullRequest() {
    pullRequest.onOpenDiff = { [weak self] key, opening in self?.openScmDiff(key, opening) }
    pullRequest.onPullRequestChange = { [weak self] in
      self?.reviewPopup.pullRequestDidChange()
      self?.reconcileWithLists()
      self?.refreshCurrentItem()
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
    reviewPopup.onReveal = { [weak self] comment in self?.reveal(comment) }
  }

  /// PR のパネルが見えている（左の列が開いていて、PR のパネルを出している）。
  var showsPullRequest: Bool { sidebar.isOpen && shell.panel == .pullRequest }

  /// PR のパネルの中のキー——列の ⌘↑ は、選択に依らず、レビューのポップアップを開くよう頼む（開けなければ何もしない）。
  /// 扱ったら true。
  func handlePullRequestKey(_ event: NSEvent) -> Bool {
    guard focusIsInPullRequest else { return false }
    guard event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.command],
      event.specialKey == .upArrow
    else { return false }
    reviewPopup.requestOpen()
    return true
  }

  /// 焦点が PR のパネルの列にあるか（列のために面が預かっている焦点を含む）。
  var focusIsInPullRequest: Bool {
    showsPullRequest && focusIsInSidebar
      && (pullRequest.isListFocused || heldListFocus == .pullRequest)
  }

  /// 未送信のコメント `comment` の場所へ移る——そのパスの PR の diff を、左の列の行を Enter で開くのと同じ口で開き（行を
  /// 選び、本文へ焦点を移す）、コメントの層に、そのスレッドを開いて、置いたらその行と押したコメントを見せるよう頼む。
  private func reveal(_ comment: PullRequestState.PendingComment) {
    guard let key = pullRequest.diffKey(of: comment.path) else { return }
    if pullRequest.reveal(file: comment.path) {
      pullRequest.openSelection(.commit)
    } else {
      openScmDiff(key, .commit)
    }
    guard let diff, diff.id == key else { return }
    diff.comments?.requestReveal(thread: comment.thread, comment: comment.id)
  }
}
