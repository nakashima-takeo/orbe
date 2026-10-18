@testable import Orbe

extension GitCommitContent {
  /// ステージ済みが `paths` だけの中身（版は問わない——そのパネルでステージした後と同じ）。
  static func staged(_ paths: String...) -> Self {
    GitCommitContent(staged: [:], unknown: Set(paths), stagingFirst: [])
  }

  /// ステージ済みが無く、`rows` を先にステージする中身。
  static func staging(_ rows: [GitStatus.Row]) -> Self {
    GitCommitContent(staged: [:], unknown: [], stagingFirst: rows)
  }

  /// 今の status から組んだ行がそのまま見えていたときの中身。
  @MainActor
  static func seen(_ status: GitStatus) -> Self {
    ScmOwnWrites().content(.build(status))
  }
}
