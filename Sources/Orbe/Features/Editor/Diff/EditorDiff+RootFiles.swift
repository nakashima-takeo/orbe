import Foundation

/// 根のサービスの知らせ——作業ツリーのファイル・status・入れ子の git dir・版の本文の変化で、中身を作り直す。
extension EditorDiff {
  /// 作業ツリーのファイルが変わった——作業ツリー diff は、新しい側（文書・消えた・表示できない）を読み直す。
  func rootFiles(_ files: RootFiles, filesDidChange change: RootFiles.Change) {
    guard id.kind == .workingTree, change.includes(id.root + "/" + id.path) else { return }
    workingStale = true
    sourcesDidChange()
  }

  /// status が変わった——競合の出入り・ステージ済みの rename の元パス・作業ツリーのサブモジュールの中の変化。
  func rootFilesStatusDidChange(_ files: RootFiles) {
    files.setVersions(interests, for: self)
    forgetSubmoduleHead()
    sourcesDidChange()
  }

  /// 入れ子の git dir が変わった（監視の 1 バッチに 1 回）——作業ツリーのサブモジュールが取り出しているコミットを読み直す
  /// （中で続けてコミットしても、親の status は「コミットが動いた」のまま変わらない）。
  func rootFilesNestedGitStateDidChange(_ files: RootFiles) {
    guard case .directory? = working else { return }
    forgetSubmoduleHead()
    sourcesDidChange()
  }

  func rootFiles(_ files: RootFiles, versionDidChange version: RootFiles.Version) {
    sourcesDidChange()
  }
}
