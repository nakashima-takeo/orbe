import AppKit

/// PR のパネルの結線——行から PR の diff を開く・ツリーかリストかのアプリ全体の選択・焦点。
extension EditorPaneView {
  static func pullRequestList(_ panel: PrPanel) -> RowList<PrListSource> {
    RowList(source: PrListSource(panel: panel), rowHeight: Theme.Layout.editorScmRow)
  }

  func wirePullRequest() {
    pullRequest.onOpenDiff = { [weak self] key, opening in self?.openScmDiff(key, opening) }
    pullRequest.onListWillClose = { [weak self] in
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

  /// 焦点が PR のパネルの列にあるか。
  var focusIsInPullRequest: Bool {
    showsPullRequest && focusIsInSidebar && pullRequest.isListFocused
  }
}
