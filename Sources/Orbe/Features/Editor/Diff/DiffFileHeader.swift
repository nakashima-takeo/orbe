import Foundation

/// 差分のファイルの見出しに出すもの。本体が diff の間、その diff のファイル 1 つについて、左の列の一覧の持ち主（ソース管理
/// パネルの状態・PR ごとの状態）が持つ事実と、新しい側の文書が未保存かどうかから導く（見出しのための状態は持たない）。
struct DiffFileHeader: Equatable {
  /// 根からの相対のフォルダ（末尾の `/` を含む。根の直下なら空）とファイル名。
  let folder: String
  let name: String
  /// 状態の字（一覧にそのファイルが無ければ nil）。
  let badge: GitStatus.Badge?
  /// 新しい側の文書が未保存。
  let isDirty: Bool
  /// 「ファイルを開く」を押せる。
  let canOpenFile: Bool
  /// 確認済み（確認済みの部品を出さないなら nil）。
  let viewed: Bool?

  /// 一覧の持ち主から読んだ、そのファイルの事実。
  enum Facts: Equatable {
    /// Changes: ソース管理パネルの、その区分・そのパスの行（無ければ nil）と、diff が新しい側に文書を使っているか。
    case changes(ScmChanges.File?, usesDocument: Bool)
    /// PR: PR ごとの状態が持つ変更ファイルのうち、そのパスの変化の種類（変更ファイルに無ければ nil）と、確認済みか。
    case pullRequest(GitHubPullRequestContent.Change?, isViewed: Bool)
  }

  /// diff の識別 `key` のファイルの見出し。`isDirty` は新しい側の文書の未保存（作業ツリー diff のときだけ効く）。
  init(_ key: EditorDiff.Key, facts: Facts, isDirty: Bool) {
    let slash = key.path.lastIndex(of: "/")
    folder = slash.map { String(key.path[...$0]) } ?? ""
    name = slash.map { String(key.path[key.path.index(after: $0)...]) } ?? key.path
    switch facts {
    case .changes(let file, let usesDocument):
      badge = file?.badge
      self.isDirty = key.kind == .workingTree && isDirty
      canOpenFile = file?.opensAsFile ?? usesDocument
      viewed = nil
    case .pullRequest(let change, let isViewed):
      badge = change.map(GitStatus.Badge.init)
      self.isDirty = false
      canOpenFile = change != .deleted
      viewed = change == nil ? nil : isViewed
    }
  }
}

extension GitStatus.Badge {
  /// PR の変化の種類から決める状態の字——追加は A、ほかは M（ソース管理と同じ 2 色の印に寄せる）。
  init(_ change: GitHubPullRequestContent.Change) {
    self = change == .added ? .added : .modified
  }
}
