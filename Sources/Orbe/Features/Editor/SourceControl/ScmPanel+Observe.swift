import Foundation

/// 根のサービスと worktree の状態の知らせを、パネルの観測へ届ける。
extension ScmPanel: RootFilesObserver {
  func rootFiles(_ files: RootFiles, filesDidChange change: RootFiles.Change) {
    resolveManaged()
  }

  func rootFilesStatusDidChange(_ files: RootFiles) {
    statusDidChange()
  }

  func rootFiles(_ files: RootFiles, versionDidChange version: RootFiles.Version) {}

  func rootFilesGitStateDidChange(_ files: RootFiles, remoteRefsChanged: Bool) {
    resolveManaged()
    readGraphAndHead(remoteRefsMayHaveMoved: remoteRefsChanged)
  }
}

/// 操作の 1 段目の終わりは `ScmPanel+Commit`（範囲に数える自分の書き込み）。
extension ScmPanel: SourceControlObserver {
  /// 自分のネット操作の終わりは remote 追跡 ref を動かしうる（push は HEAD を動かさないので、前の値を残すと push の直後に
  /// amend・取り消しが押せる）。HEAD を動かす操作は、HEAD の違いで分からないになる。
  func sourceControl(_ control: SourceControl, operationDidFinish kind: SourceControl.Kind) {
    readGraphAndHead(remoteRefsMayHaveMoved: kind.isNetwork)
  }
}
