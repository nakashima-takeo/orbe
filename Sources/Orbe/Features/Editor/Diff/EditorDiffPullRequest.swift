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
    // 誰も見ていなかった PR なら、読み直す（ほかの者が見ている間は、その者のきっかけで読み直している）。
    let unwatched = !state.isWatched
    state.beginWatching()
    if unwatched { state.reload() }
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

  /// 両端 `ends` の古い側と新しい側の版の本文を読み、読み終えたら diff を作り直させる。
  private func load(_ ends: PullRequestState.DiffEnds) {
    guard reading != ends, let repo = state.repo else { return }
    reading = ends
    let path = id.path
    repo.version(of: ends.renames[path] ?? path, at: .commit(ends.mergeBase)) { [weak self] old in
      repo.version(of: path, at: .commit(ends.head)) { [weak self] new in
        guard let self, reading == ends else { return }
        reading = nil
        read = (ends, Self.resolution(old: old, new: new))
        onChange?(.material)
      }
    }
  }

  private static func resolution(old: GitVersionText, new: GitVersionText) -> EditorDiff.Resolution
  {
    var texts: [String?] = []
    for version in [old, new] {
      switch version {
      case .failed: return .unavailable(.failed)
      case .absent: texts.append(nil)
      case .present(let data):
        guard let text = String(data: data, encoding: .utf8) else { return .unavailable(.notText) }
        texts.append(text)
      }
    }
    guard texts[0] != nil || texts[1] != nil else { return .unavailable(.nowhere) }
    return .revisions(EditorDiff.SideTexts(old: texts[0], new: texts[1]))
  }
}

/// PR の両端が変わったら diff を作り直させる（両端が同じなら、読んだ本文で同じ答えを返す）。
extension EditorDiffPullRequest: PullRequestStateObserver {
  func pullRequestStateDidChange(_ state: PullRequestState) {
    onChange?(.material)
  }
}
