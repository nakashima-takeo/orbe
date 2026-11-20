import Foundation

/// PR の diff の出どころ——古い側は PR のマージベースのコミットの版（rename なら元のパス）、新しい側は PR の先頭のコミットの
/// 版。両側とも読むだけ。diff を開いたときの PR の、PR ごとの状態を持ち続け、ブランチを切り替えても同じ PR の diff を出す。PR に push が
/// あって両端が変わったら、新しい両端の版の本文を読み直す。両端が変わらない間（中身の読み直し・確認済みの切り替え）は、
/// 読んだ本文で同じ答えを返し続ける。
@MainActor
final class EditorDiffPullRequest: EditorDiffSource {
  let id: EditorDiff.Key
  let state: PullRequestState
  var onChange: ((EditorDiff.SourceChange) -> Void)?
  /// 読み終えた両端と、その答え。
  private var read: (ends: PullRequestState.DiffEnds, resolution: EditorDiff.Resolution)?
  /// 読んでいる両端。
  private var reading: PullRequestState.DiffEnds?

  init(id: EditorDiff.Key, state: PullRequestState) {
    self.id = id
    self.state = state
    state.addObserver(self)
    state.beginWatching()
  }

  deinit {
    let state = self.state
    MainActor.assumeIsolated {
      state.removeObserver(self)
      state.endWatching()
    }
  }

  func resolve() -> EditorDiff.Resolution {
    switch state.bounds {
    case .none, .fetching: return .wait
    case .failed(_, .commitsMissing): return .unavailable(.pullRequestCommitsMissing)
    case .failed(_, .unrelated): return .unavailable(.pullRequestUnrelated)
    case .failed(_, .unreadable): return .unavailable(.failed)
    case .ready(_, let ends):
      if let read, read.ends == ends { return read.resolution }
      load(ends)
      return .wait
    }
  }

  /// 両端が揃い、その両端の版の本文から作った答えを返せる状態か。
  var isCaughtUp: Bool {
    guard case .ready(_, let ends) = state.bounds else { return false }
    return read?.ends == ends
  }

  /// 両側の本文 `texts` を読んだ両端（最後に読んだ両端の本文でなければ nil）。
  func ends(of texts: EditorDiff.SideTexts) -> PullRequestState.DiffEnds? {
    guard let read, case .revisions(let sides) = read.resolution, sides == texts else { return nil }
    return read.ends
  }

  /// 両端 `ends` の古い側と新しい側の版の本文を読み、読み終えたら diff を作り直させる。
  private func load(_ ends: PullRequestState.DiffEnds) {
    guard reading != ends, let repo = state.repo else { return }
    reading = ends
    let path = id.path
    repo.version(of: ends.renames[path] ?? path, atCommit: ends.mergeBase) { [weak self] old in
      repo.version(of: path, atCommit: ends.head) { [weak self] new in
        guard let self, reading == ends else { return }
        reading = nil
        read = (ends, Self.resolution(old: old, new: new))
        onChange?(.material)
      }
    }
  }

  /// 両側の版から答えを決める。サブモジュールは「Subproject commit」の行で見せ（作業ツリー diff・ステージ済み diff と
  /// 同じ）、ファイルとサブモジュールの置き換えは丸ごとの置き換え。
  private static func resolution(old: GitVersionText, new: GitVersionText) -> EditorDiff.Resolution
  {
    var texts: [String?] = []
    for version in [old, new] {
      switch version {
      case .failed: return .unavailable(.failed)
      case .absent: texts.append(nil)
      case .submodule(let commit): texts.append(EditorDiff.subproject(commit))
      case .present(let data):
        guard let text = String(data: data, encoding: .utf8) else { return .unavailable(.notText) }
        texts.append(text)
      }
    }
    guard texts[0] != nil || texts[1] != nil else { return .unavailable(.nowhere) }
    let sides = EditorDiff.SideTexts(old: texts[0], new: texts[1])
    return replaces(old, new) ? .revisionsReplacing(sides) : .revisions(sides)
  }

  /// 片側がファイルの本文で、もう片側がサブモジュール（ファイルとサブモジュールの置き換え）。
  private static func replaces(_ old: GitVersionText, _ new: GitVersionText) -> Bool {
    switch (old, new) {
    case (.present, .submodule), (.submodule, .present): true
    default: false
    }
  }
}

/// PR の両端が変わったら diff を作り直させる（両端が同じなら、読んだ本文で同じ答えを返す）。
extension EditorDiffPullRequest: PullRequestStateObserver {
  func pullRequestStateDidChange(_ state: PullRequestState) {
    onChange?(.material)
  }
}
