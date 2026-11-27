import Foundation

/// 根のサービスの知らせ——管理下かの判定・status（ブランチ名と HEAD）・リモート追跡の ref の変化。
extension BranchPullRequest: RootFilesObserver {
  func rootFiles(_ files: RootFiles, filesDidChange change: RootFiles.Change) {}

  func rootFiles(_ files: RootFiles, versionDidChange version: RootFiles.Version) {}

  func rootFilesDidResolve(_ files: RootFiles) {
    reload()
  }

  /// ブランチ名が変わったか、status を待っていた読み直しがあれば引き直す。HEAD だけが動いたなら、手元とのずれを数え直す。
  func rootFilesStatusDidChange(_ files: RootFiles) {
    let name = files.status?.branch?.name
    if name != branch || awaitingStatus { return reload() }
    head = files.status?.branch?.commit
    countDrift()
  }

  /// リモート追跡の ref が動いたかもしれない——このブランチの push 先か PR のベースブランチの追跡 ref の値が変わって
  /// いたときだけ読み直す（無関係なブランチが fetch で動くたびに GitHub へ問い合わせない）。問い合わせの最中なら、
  /// 終わった後に 1 回読み直す。
  func rootFilesGitStateDidChange(_ files: RootFiles, remoteRefsChanged: Bool) {
    guard remoteRefsChanged else { return }
    tracking.check { [weak self] in self?.reload() }
  }
}

/// Orbe の中のネット操作（プッシュ・プル・フェッチ・同期・公開・コミットしてプッシュ）が終わったら読み直す。
extension BranchPullRequest: SourceControlObserver {
  func sourceControl(
    _ control: SourceControl, firstStepDidFinish operation: SourceControl.Operation,
    outcome: SourceControl.FirstStepOutcome
  ) {}

  func sourceControl(_ control: SourceControl, operationDidFinish kind: SourceControl.Kind) {
    guard kind.isNetwork else { return }
    reload()
  }
}

/// PR の中身・両端が変わったら、手元とのずれを数え直し、受ける者へ知らせる。PR のベースブランチの追跡 ref が新しく
/// 分かったら、その値も覚える。
extension BranchPullRequest: PullRequestStateObserver {
  func pullRequestStateDidChange(_ state: PullRequestState) {
    readingFailuresDidChange()
    countDrift()
    notify()
    if let base = self.state?.baseTrackingRef, tracking.lacks(base) { tracking.record() }
  }
}
