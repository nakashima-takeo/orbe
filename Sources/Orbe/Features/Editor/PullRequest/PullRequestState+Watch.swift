import Foundation

/// PR ごとの状態の、中身を読み直すきっかけ——見られている間だけ、PR のリポジトリの根のサービスとソース管理を観測する。
/// worktree の今の PR がこの PR を見ていなくても（パネルを隠した・ブランチを切り替えた）、PR の diff が本体に
/// 出ていて面が見えている間は追従する。
extension PullRequestState {
  /// 見られていて、リポジトリが結ばれていれば、その根の根のサービスとソース管理を観測する（既に観測していれば、根が
  /// 替わったときだけ結び直す）。
  func observe() {
    guard isWatched, let repo else { return }
    let root = GitWorktreeRoot.normalizedPath(repo.root)
    if let files, files.root == root { return }
    unobserve()
    let files = RootFiles.shared(for: root)
    self.files = files
    files.addObserver(self)
    SourceControl.shared(for: root).addObserver(self)
  }

  func unobserve() {
    guard let files else { return }
    files.removeObserver(self)
    SourceControl.shared(for: files.root).removeObserver(self)
    self.files = nil
  }

  /// PR の先頭のブランチの追跡 ref と、ベースブランチの追跡 ref（中身が読めていて、remote が分かっているものだけ）。
  var trackedRefs: [String] {
    guard let content else { return [] }
    var refs: [String] = []
    if let headRemote { refs.append("refs/remotes/\(headRemote)/\(content.headRefName)") }
    if let baseTrackingRef { refs.append(baseTrackingRef) }
    return refs
  }

  /// ベースブランチの追跡 ref（PR が置かれたリポジトリを指す remote の下。中身が読めていない・remote が分からなければ nil）。
  var baseTrackingRef: String? {
    guard let fetchRemote, let content else { return nil }
    return "refs/remotes/\(fetchRemote)/\(content.baseRefName)"
  }
}

/// リモート追跡の ref が動いたかもしれない——この PR の追跡 ref の値が変わっていたときだけ読み直す。
extension PullRequestState: RootFilesObserver {
  func rootFiles(_ files: RootFiles, filesDidChange change: RootFiles.Change) {}

  func rootFilesStatusDidChange(_ files: RootFiles) {}

  func rootFiles(_ files: RootFiles, versionDidChange version: RootFiles.Version) {}

  func rootFilesGitStateDidChange(_ files: RootFiles, remoteRefsChanged: Bool) {
    guard remoteRefsChanged else { return }
    tracking.check { [weak self] in self?.reload() }
  }
}

/// PR のリポジトリで Orbe の中のネット操作（プッシュ・プル・フェッチ・同期・公開・コミットしてプッシュ）が終わったら
/// 読み直す。
extension PullRequestState: SourceControlObserver {
  func sourceControl(
    _ control: SourceControl, firstStepDidFinish operation: SourceControl.Operation,
    outcome: SourceControl.FirstStepOutcome
  ) {}

  func sourceControl(_ control: SourceControl, operationDidFinish kind: SourceControl.Kind) {
    guard kind.isNetwork else { return }
    reload()
  }
}
