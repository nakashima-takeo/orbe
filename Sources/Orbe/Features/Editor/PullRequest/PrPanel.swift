import AppKit

/// PR のパネルの面ごとの状態——worktree の今の PR（`BranchPullRequest`）を見ること、列の行の組、区分・フォルダ・説明の
/// 開閉、選択、列の焦点。PR の事実（どの PR か・中身・確認済み・両端）は 2 つの状態が持ち、ここは見せ方だけ。
///
/// パネルを出している間（`isShown`）だけ worktree の今の PR を見る——GitHub に問い合わせるのは見ている間だけ。列の行は、
/// PR の中身・ツリーかリストか・開閉で決まり、変わったときだけ組み直す（確認済みは描くときに状態から読む）。区分と
/// フォルダの開閉・選択は面ごとで永続しない。ツリーかリストかはアプリ全体で 1 つ（`EditorSidebarState`）。
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
  private(set) var selection: PrRowID?
  private(set) var isListFocused = false
  /// 焦点を入れる要求（当てたら外す）。
  private(set) var focusRequest = false

  /// 行の diff を開く。
  @ObservationIgnored var onOpenDiff: (EditorDiff.Key, ScmPanel.Opening) -> Void = { _, _ in }
  /// 変更ファイルをツリーで見せるか（アプリ全体の選択を読む）と、ツリーかリストかを選んだ（アプリ全体の選択へ書く）。
  @ObservationIgnored var filesAsTree: () -> Bool = { true }
  @ObservationIgnored var onViewAsTree: (Bool) -> Void = { _ in }
  /// URL をブラウザで開く。
  @ObservationIgnored var onOpenURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
  /// キーで行へ動いたときの開きの間引き。
  @ObservationIgnored let navigation = RowNavigationThrottle()
  /// 組んだ行と、その元（同じ元なら組み直さない）。
  @ObservationIgnored private var built: (key: LayoutKey, layout: PrLayout)?
  @ObservationIgnored private var builtVersion = 0

  private struct LayoutKey: Equatable {
    let content: GitHubPullRequestContent
    let asTree: Bool
    let closed: Set<PrSection>
    let closedFolders: Set<String>
  }

  /// パネルを出している間 true。立てると worktree の今の PR を見始め、下ろすと見るのをやめる。
  @ObservationIgnored var isShown = false {
    didSet {
      guard isShown != oldValue else { return }
      if isShown {
        pullRequest.beginWatching()
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
  }

  /// 今の PR の状態（PR があるときだけ）。
  var state: PullRequestState? { pullRequest.state }

  /// 変更ファイルをツリーで見せるか。
  var asTree: Bool { filesAsTree() }

  // MARK: - 行

  /// 今の行の組（PR が無い・中身がまだ無ければ空）。元が変わったときだけ組み直す。
  var layout: PrLayout {
    guard let content = state?.content else { return .empty }
    let key = LayoutKey(
      content: content, asTree: asTree, closed: closed, closedFolders: closedFolders)
    if let built, built.key == key { return built.layout }
    let layout = PrLayout.build(
      content, asTree: asTree, closed: closed, closedFolders: closedFolders)
    built = (key, layout)
    builtVersion += 1
    return layout
  }

  /// 列が読み直す版——行の組か確認済みが変わるたびに変わる（確認済みは行を組み直さず、見えている行を描き直す）。
  var rowsVersion: Int {
    _ = layout
    var hasher = Hasher()
    hasher.combine(builtVersion)
    hasher.combine(state.map(ObjectIdentifier.init))
    hasher.combine(state?.viewedVersion)
    return hasher.finalize()
  }

  // MARK: - 開閉・選択・焦点

  func isOpen(_ section: PrSection) -> Bool { !closed.contains(section) }

  func toggle(_ section: PrSection) {
    if closed.contains(section) { closed.remove(section) } else { closed.insert(section) }
  }

  func toggleFolder(_ path: String) {
    if closedFolders.contains(path) {
      closedFolders.remove(path)
    } else {
      closedFolders.insert(path)
      if case .file(let file)? = selection, file.hasPrefix(path + "/") { selection = .folder(path) }
    }
  }

  func select(_ id: PrRowID?) {
    guard id?.isSelectable ?? true else { return }
    selection = id
  }

  func requestFocus() { focusRequest = true }

  func focusRequestDidApply() { focusRequest = false }

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

  /// 再読込——今のブランチの PR を引き直し、PR があればその中身も読み直す。
  func refresh() {
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
