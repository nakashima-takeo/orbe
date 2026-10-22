@testable import Orbe

extension GitCommitContent {
  /// ステージ済みが `paths` だけの中身（版と HEAD は問わない——そのパネルでステージし、HEAD を動かす書き込みが走っている
  /// 間と同じ）。
  static func staged(_ paths: String...) -> Self {
    GitCommitContent(head: .movedByOwnWrite, staged: [:], unknown: Set(paths), stagingFirst: [])
  }

  /// ステージ済みが無く、`rows` を先にステージする中身（HEAD は問わない）。
  static func staging(_ rows: [GitStatus.Row]) -> Self {
    GitCommitContent(head: .movedByOwnWrite, staged: [:], unknown: [], stagingFirst: rows)
  }

  /// 今の status から組んだ行がそのまま見えていたときの中身。
  @MainActor
  static func seen(_ status: GitStatus) -> Self {
    ScmOwnWrites().content(.build(status))
  }
}
