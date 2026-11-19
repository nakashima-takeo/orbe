import AppKit

/// PR のパネルの結線——行から PR の diff を開く・ツリーかリストかのアプリ全体の選択・焦点。
extension EditorPaneView {
  static func pullRequestList(_ panel: PrPanel) -> RowList<PrListSource> {
    RowList(source: PrListSource(panel: panel), rowHeight: Theme.Layout.editorScmRow)
  }

  func wirePullRequest() {
    pullRequest.onOpenDiff = { [weak self] key, opening in self?.openScmDiff(key, opening) }
    pullRequest.onFocusWillClose = { [weak self] in
      guard let self, focusIsInPullRequest else { return }
      reclaimSidebarFocus()
    }
    pullRequest.filesAsTree = { [weak self] in self?.sidebar.pullRequestFilesAsTree ?? true }
    pullRequest.onViewAsTree = { [weak self] asTree in
      self?.sidebar.setPullRequestFilesAsTree(asTree)
    }
  }

  /// PR のパネルが見えている（サイドバーが開いていて、PR のパネルを出している）。
  var showsPullRequest: Bool { sidebar.isOpen && sidebar.panel == .pullRequest }

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

  /// 焦点が PR のパネルの列か全体へのコメント欄にあるか。
  var focusIsInPullRequest: Bool {
    showsPullRequest && focusIsInSidebar
      && (pullRequest.isListFocused || pullRequest.isReviewFieldFocused)
  }
}
