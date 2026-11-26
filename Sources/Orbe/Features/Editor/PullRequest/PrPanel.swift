import AppKit

/// PR のパネルの面ごとの状態——worktree の今の PR（`BranchPullRequest`）を見ること、列の行の組、区分・フォルダ・説明の
/// 開閉、選択、列の焦点、ファイルごとのコメント数の覚え。PR の事実（どの PR か・中身・確認済み・両端）は 2 つの状態が持ち、ここは見せ方だけ。
///
/// 面が見えている間（`isTracking`）は worktree の今の PR がどの PR かを追い（上のバーの番号）、PR の画面を出している間
/// （`isShown`。左の列を閉じていても）は PR の中身も読む——GitHub に問い合わせるのは、このどちらかの間だけ。列の行は、
/// PR の中身・ツリーかリストか・開閉で決まり、そのどれかが変わったときに 1 か所（`rebuild`）で組み直す（確認済みは描くときに
/// 状態から読む）。選択は常に見えている行にある——組み直した後に選んでいた行が無ければ、そこで選び直す（ソース管理の
/// 変更の列と同じ）。区分とフォルダの開閉・選択は面ごとで永続しない。ツリーかリストかはアプリ全体で 1 つ
/// （`EditorSidebarState`）。
@MainActor @Observable
final class PrPanel {
  /// 根（正準形）。
  let root: String
  /// worktree の今の PR。
  let pullRequest: BranchPullRequest
  /// 説明が開いている。
  var isDescriptionOpen = true
  private(set) var closed: Set<PrSection> = []
  private(set) var closedFolders: Set<String> = []
  /// 今の行の組（PR が無い・中身がまだ無ければ空）。
  private(set) var layout = PrLayout.empty
  private(set) var selection: PrRowID?
  private(set) var isListFocused = false
  /// 焦点を入れる要求（当てたら外す）。
  private(set) var focusRequest = false

  /// 列が消える直前（行の組が空になる。まだ窓に居るうち）。焦点がパネルの列にあれば、面の本文へ移す。
  @ObservationIgnored var onFocusWillClose: () -> Void = {}
  /// 行の diff を開く。
  @ObservationIgnored var onOpenDiff: (EditorDiff.Key, ScmPanel.Opening) -> Void = { _, _ in }
  /// worktree の今の PR が替わった・その PR の状態が変わった（行の組を組み直した後）。
  @ObservationIgnored var onPullRequestChange: () -> Void = {}
  /// 列の状態（`listState`）が変わった（変わった後の main の回で知らせる）。
  @ObservationIgnored var onListStateChange: () -> Void = {}
  /// 変更ファイルをツリーで見せるか（アプリ全体の選択を読む）と、ツリーかリストかを選んだ（アプリ全体の選択へ書く）。
  @ObservationIgnored var filesAsTree: () -> Bool = { true }
  @ObservationIgnored var onViewAsTree: (Bool) -> Void = { _ in }
  /// URL をブラウザで開く。
  @ObservationIgnored var onOpenURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
  /// ファイルごとのコメントの数と、それを数えたレビューのやりとり。
  @ObservationIgnored private var counted: CommentCounts?

  /// ファイルごとのコメントの数（PR の状態 `state`・そのレビューのやりとりの版 `version`・diff の両端 `ends`（分からなければ
  /// 先頭のコミット `head`）で数えた）。
  private struct CommentCounts {
    let state: ObjectIdentifier
    let version: Int
    let head: String
    let ends: PullRequestState.DiffEnds?
    let counts: [String: Int]
  }
  /// キーで行へ動いたときの開きの間引き。
  @ObservationIgnored let navigation = RowNavigationThrottle()
  /// 行の組の元（同じ元なら組み直さない）と、組み直した回数。
  @ObservationIgnored private var builtFrom: LayoutKey?
  private var builtVersion = 0

  private struct LayoutKey: Equatable {
    let content: GitHubPullRequestContent?
    let asTree: Bool
    let closed: Set<PrSection>
    let closedFolders: Set<String>
  }

  /// 面が見えている間 true。立てると worktree の今の PR がどの PR かを追い始め、知らせを受ける。下ろすとやめる（先に
  /// `isShown` を下ろす）。
  @ObservationIgnored var isTracking = false {
    didSet {
      guard isTracking != oldValue else { return }
      if isTracking {
        pullRequest.addObserver(self)
        pullRequest.beginTracking()
        rebuild()
      } else {
        pullRequest.removeObserver(self)
        pullRequest.endTracking()
      }
    }
  }

  /// PR の画面を出している間 true（追っている間だけ）。立てると PR の中身も読んで行を組み、下ろすと中身を読むのをやめる。
  @ObservationIgnored var isShown = false {
    didSet {
      guard isShown != oldValue else { return }
      if isShown {
        pullRequest.beginWatching()
        rebuild()
      } else {
        pullRequest.endWatching()
        panelDidHide()
      }
    }
  }

  init(root: String, source: PullRequestSource) {
    self.root = root
    pullRequest = BranchPullRequest.shared(for: root, source: source)
    navigation.open = { [weak self] in self?.openSelection(.browse) }
    observeListState(listState)
  }

  /// 今の PR の状態（PR があるときだけ）。
  var state: PullRequestState? { pullRequest.state }

  /// 変更ファイルをツリーで見せるか。
  var asTree: Bool { filesAsTree() }

  // MARK: - 行

  /// 行の組を、元（PR の中身・ツリーかリストか・開閉）が変わっていれば組み直し、選んでいた行が無くなっていれば選び直す
  /// ——畳んで隠れたなら、見えている祖先（畳んだフォルダか区分の見出し）へ、消えたなら変更ファイルの区分の同じ位置の行へ
  /// （開かない）。行の組が空になる（PR が無くなった・替わって中身がまだ無い）と列が消えるので、その前に知らせ、当てる列の
  /// 無い焦点の要求を捨てる（残すと、後で列が現れた瞬間に焦点を奪う）。
  func rebuild() {
    let content = state?.content
    let key = LayoutKey(
      content: content, asTree: asTree, closed: closed, closedFolders: closedFolders)
    guard key != builtFrom else { return }
    builtFrom = key
    let previous = layout
    if content == nil {
      if !previous.items.isEmpty { onFocusWillClose() }
      focusRequest = false
    }
    layout =
      content.map {
        PrLayout.build(
          $0, files: state?.changedFiles ?? .empty, asTree: key.asTree, closed: closed,
          closedFolders: closedFolders)
      } ?? .empty
    builtVersion += 1
    guard let selection, layout.index[selection] == nil else { return }
    self.selection = layout.reselect(selection, from: previous, isCollapsed: isCollapsed)
  }

  /// 行 `id`（区分の見出しかフォルダ）が畳まれている。
  private func isCollapsed(_ id: PrRowID) -> Bool {
    switch id {
    case .section(let section): closed.contains(section)
    case .folder(let path): closedFolders.contains(path)
    case .commit, .olderCommits, .file: false
    }
  }

  /// 列が読み直す版——行の組・確認済み・レビューのやりとり・diff の両端が変わるたびに変わる（確認済みとコメントの数は行を
  /// 組み直さず、見えている行を描き直す。コメントの数は diff の両端で置けるかが決まる）。
  var rowsVersion: Int {
    var hasher = Hasher()
    hasher.combine(builtVersion)
    hasher.combine(state.map(ObjectIdentifier.init))
    hasher.combine(state?.viewedVersion)
    hasher.combine(state?.reviewVersion)
    hasher.combine(state?.diffEnds)
    return hasher.finalize()
  }

  // MARK: - 開閉・選択・焦点

  func isOpen(_ section: PrSection) -> Bool { !closed.contains(section) }

  func toggle(_ section: PrSection) {
    if closed.remove(section) == nil { closed.insert(section) }
    rebuild()
  }

  func toggleFolder(_ path: String) {
    if closedFolders.remove(path) == nil { closedFolders.insert(path) }
    rebuild()
  }

  func select(_ id: PrRowID?) {
    guard id?.isSelectable ?? true else { return }
    selection = id
  }

  /// 変更ファイル `path` の行の祖先（変更ファイルの区分と、ツリーならフォルダ）を開いて組み直し、行が組に在れば選ぶ（中身が
  /// まだ無い・変更ファイルに無ければ選ばない）。選んだら true。
  func reveal(file path: String) -> Bool {
    for ancestor in PrLayout.ancestors(of: .file(path)) {
      switch ancestor {
      case .section(let section): closed.remove(section)
      case .folder(let folder): closedFolders.remove(folder)
      case .commit, .olderCommits, .file: break
      }
    }
    rebuild()
    guard layout.index[.file(path)] != nil else { return false }
    selection = .file(path)
    return true
  }

  /// 列の状態。行があればある。無ければ、worktree の今の PR の答えを読んでいる・PR があってその中身を読んでいる間は
  /// これから来る、それ以外（PR が無い・表示できない・中身が無く読んでもいない）は無い。
  var listState: EditorListState {
    if !layout.items.isEmpty { return .rows }
    if case .reading = pullRequest.answer { return .coming }
    return state?.isReading == true ? .coming : .none
  }

  /// 列の状態を観測し、`reported` から変わったら知らせる。状態を決める値（行の組・worktree の今の PR の答え・PR の中身を
  /// 読んでいるか）はどれも観測するので、どの道で変わってもここが知らせる——答えが「読んでいる」から「PR が無い」「表示
  /// できない」へ変わっても、PR の状態は替わらないので、worktree の今の PR の知らせは出ない。
  private func observeListState(_ reported: EditorListState) {
    withObservationTracking {
      _ = listState
    } onChange: { [weak self] in
      DispatchQueue.main.async {
        guard let self else { return }
        let state = self.listState
        if state != reported { self.onListStateChange() }
        self.observeListState(state)
      }
    }
  }

  func requestFocus() { focusRequest = true }

  func focusRequestDidApply() { focusRequest = false }

  /// 列へ焦点を入れる要求が残っていれば取り消す。
  func cancelFocusRequest() { focusRequest = false }

  func focusDidChange(_ focused: Bool) {
    if !focused { navigation.drop() }
    isListFocused = focused
  }

  /// パネルが隠れた。待っている開きと焦点の要求を捨てる。
  func panelDidHide() {
    navigation.drop()
    isListFocused = false
    focusRequest = false
  }

  // MARK: - コメント

  /// ファイル `path` の、今の diff に置けるスレッド（`PullRequestState.canPlace`）のコメントの総数。レビューのやりとりか
  /// diff の両端が変わったときだけ数え直す（3,000 件のファイルでも、見えている行を描くたびにスレッドを数えない）。
  func commentCount(of path: String) -> Int {
    guard let state, let head = state.content?.headCommit else { return 0 }
    let id = ObjectIdentifier(state)
    let ends = state.diffEnds
    if counted?.state != id || counted?.version != state.reviewVersion || counted?.head != head
      || counted?.ends != ends
    {
      var counts: [String: Int] = [:]
      for thread in state.threads(at: head) ?? [] where state.canPlace(thread, in: ends) == true {
        counts[thread.path, default: 0] += thread.comments.count
      }
      counted = CommentCounts(
        state: id, version: state.reviewVersion, head: head, ends: ends, counts: counts)
    }
    return counted?.counts[path] ?? 0
  }

  // MARK: - 確認済み

  /// ファイル `path` の確認済みを切り替える。
  func toggleViewed(_ path: String) {
    guard let state else { return }
    state.setViewed(!state.isViewed(path), paths: [path])
  }

  /// フォルダの配下 `files` をまとめて切り替える——全部が確認済みなら全部外し、そうでなければ全部付ける。
  func toggleViewed(folder files: [String]) {
    guard let state else { return }
    let all = files.allSatisfy(state.isViewed)
    state.setViewed(!all, paths: files)
  }

  /// 配下 `files` の確認済みの数。
  func viewedCount(of files: [String]) -> Int {
    guard let state else { return 0 }
    return files.count(where: state.isViewed)
  }

  // MARK: - 道具

  /// 再読込——読みの失敗の閉じた印を外し、今のブランチの PR を引き直し、PR があればその中身も読み直す。
  func refresh() {
    pullRequest.clearReadingFailureDismissal()
    pullRequest.reload()
    state?.reload()
  }

  /// PR の GitHub のページをブラウザで開く。
  func openOnGitHub() {
    guard let url = state?.content.flatMap({ URL(string: $0.url) }) else { return }
    onOpenURL(url)
  }

  /// PR の作成ページをブラウザで開く（ブランチが GitHub に無いと確かめられた間は押せない）。
  func createPullRequest() {
    guard case .noPullRequest(let creation) = pullRequest.answer, creation.published != .no,
      let url = creation.url
    else { return }
    onOpenURL(url)
  }
}

/// worktree の今の PR が替わった・その PR の状態が変わったら、行の組を組み直す（中身が同じなら組み直さない）。
extension PrPanel: BranchPullRequestObserver {
  func branchPullRequestDidChange(_ pullRequest: BranchPullRequest) {
    rebuild()
    onPullRequestChange()
  }
}
