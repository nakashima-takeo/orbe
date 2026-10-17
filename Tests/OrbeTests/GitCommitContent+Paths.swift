@testable import Orbe

extension GitCommitContent {
  /// 見えていたステージ済みが、rename でない `paths` の行だけの中身。
  static func staged(_ paths: String...) -> Self {
    .staged(paths.map { GitStatus.Row(path: $0, originalPath: nil) })
  }
}
