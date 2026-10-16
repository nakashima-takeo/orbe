import Foundation

/// 根のサービスからの通知。(a)(d) はデバウンス後すぐ、(b) は status が返った時点、(c) は版の本文の取り直しの完了後に届く。
@MainActor
protocol RootFilesObserver: AnyObject {
  /// (a) 根の下でファイルが変わった（git dir の中は含まない）。
  func rootFiles(_ files: RootFiles, filesDidChange change: RootFiles.Change)
  /// (b) status が新しくなった（git 管理下のみ）。
  func rootFilesStatusDidChange(_ files: RootFiles)
  /// (c) 関心を申告した版の本文の状態が変わった（その版に無くなった・取れなくなったも含む）。
  func rootFiles(_ files: RootFiles, versionDidChange version: RootFiles.Version)
  /// (d) git の状態（ref・HEAD・index など git dir の中）が変わった（監視の 1 バッチに 1 回。取りこぼしでも）。status
  /// に映らない ref だけの変化（upstream を付けない push・ブランチの作成や削除）も届く。
  func rootFilesGitStateDidChange(_ files: RootFiles)
}

extension RootFilesObserver {
  func rootFilesGitStateDidChange(_ files: RootFiles) {}
}
