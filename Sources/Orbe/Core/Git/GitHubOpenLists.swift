import Foundation
import Observation

/// 開いた workspace のリポジトリの open な Issue・PR の一覧の置き場（@Observable・main のみ・アプリで 1 つ）で
/// あり、取得の合流点。値は保存せずメモリにだけ持ち、次に開いたときは前回の答えで先に描く。画面は一覧を
/// 写さずここを読む。
///
/// - **root → リポジトリ**: workspace の root で gh が既定とするリポジトリを解決し、root ごとに最後の答えを
///   覚える（先描き用）。新しい答えが前回と違えば、新しい名前の一覧に切り替わる。
/// - **リポジトリ → 一覧**: Issue・PR の一覧と、自分にレビューを頼んでいる PR の番号。一覧はページが届くたびに
///   伸び、上限まで取り終えるのに数十秒かかりうるので、取得は画面より長生きする。取得の持ち主をリポジトリ・
///   種別ごとにここへ置くことで、同じ一覧の取得は常に 1 本になり、画面を閉じても上限まで続く。
/// - **項目 → 書き込みの失敗**: 自分をアサイン・レビュアーにする書き込みの失敗。次に試すか成功すれば消える。
@Observable final class GitHubOpenLists {
  static let shared = GitHubOpenLists(source: .gh(.shared), viewer: .shared)

  /// GitHub への問い合わせと書き込み。どれもメインで返る。
  struct Source {
    var defaultRepository:
      (
        _ root: String,
        _ completion: @escaping (Result<GitHubRepoName, GitHubRepositoryUnavailable>) -> Void
      ) -> Void
    /// ページを `page` へ、終わりを `finished`（`true` = 取り終えた／`false` = 途中で失敗した）へ渡す。
    var openItems:
      (
        _ repo: GitHubRepoName, _ kind: GitHubItemKind,
        _ page: @escaping ([GitHubOpenItem]) -> Void, _ finished: @escaping (Bool) -> Void
      ) -> Void
    var reviewRequests:
      (_ repo: GitHubRepoName, _ completion: @escaping (GitHubReviewRequests?) -> Void) -> Void
    /// 応答の担当者か個人宛のレビュー依頼の login を返す（nil = 失敗）。
    var addSelf:
      (
        _ role: GitHubSelfRole, _ item: GitHubItemID, _ login: String,
        _ completion: @escaping ([String]?) -> Void
      ) -> Void

    static func gh(_ cli: GitHubCLI) -> Source {
      Source(
        defaultRepository: { cli.defaultRepository(root: $0, completion: $1) },
        openItems: { repo, kind, page, finished in
          switch kind {
          case .issue: cli.openIssues(repo: repo, page: page, finished: finished)
          case .pr: cli.openPullRequests(repo: repo, page: page, finished: finished)
          }
        },
        reviewRequests: { cli.reviewRequests(repo: $0, completion: $1) },
        addSelf: { cli.addSelf(as: $0, to: $1, login: $2, completion: $3) })
    }
  }

  /// root の解決の状態。
  enum Resolution: Equatable {
    case resolving
    case unavailable(GitHubRepositoryUnavailable)
    case resolved
  }

  struct Root: Equatable {
    var resolution: Resolution
    /// 最後に解決できたリポジトリ（解決中・使えない間も、先描きに使う）。
    var repo: GitHubRepoName?
  }

  /// 1 つの一覧の状態。
  struct List: Equatable {
    /// 作成の新しい順。nil = まだ取れていない（`[]` は 0 件）。
    var items: [GitHubOpenItem]?
    /// 取得中（伸びている途中）か。
    var growing = false
    /// 最後の取得が失敗したか。
    var failed = false
  }

  struct Repository: Equatable {
    var issues = List()
    var pullRequests = List()
    /// 自分（所属チームを含む）にレビューを頼んでいる PR の番号。nil = まだ取れていない。
    var reviewRequests: Set<Int>?

    func list(_ kind: GitHubItemKind) -> List { kind == .issue ? issues : pullRequests }
  }

  private(set) var roots: [String: Root]
  private(set) var repositories: [GitHubRepoName: Repository]
  /// 書き込みに失敗した項目と、そのときの役割。
  private(set) var writeFailures: [GitHubItemID: GitHubSelfRole] = [:]
  @ObservationIgnored private var refreshes: [RefreshKey: Refresh] = [:]
  @ObservationIgnored private var resolvingRoots: Set<String> = []
  @ObservationIgnored private var requestingReviews: Set<GitHubRepoName> = []
  @ObservationIgnored private let source: Source
  @ObservationIgnored private let viewer: GitHubViewer

  private struct RefreshKey: Hashable {
    let repo: GitHubRepoName
    let kind: GitHubItemKind
  }

  /// 1 本の取り直しの状態。
  private struct Refresh {
    /// 開始時点の一覧。まだ届いていない古い範囲をこれで埋める。
    var previous: [GitHubOpenItem]?
    /// 今回届いた分。
    var fresh: [GitHubOpenItem] = []
    /// この取得の間に差し込んだ書き換え（番号ごと）。後から届くページにも当てる。
    var patches: [Int: [(inout GitHubOpenItem) -> Void]] = [:]
  }

  init(
    roots: [String: Root] = [:], repositories: [GitHubRepoName: Repository] = [:],
    source: Source, viewer: GitHubViewer
  ) {
    self.roots = roots
    self.repositories = repositories
    self.source = source
    self.viewer = viewer
  }

  func repository(for root: String) -> GitHubRepoName? { roots[root]?.repo }

  /// root のリポジトリを解決し直し、その一覧 2 本と自分へのレビュー依頼を取り直す。進行中の解決・取得には
  /// 合流する。
  func open(root: String) {
    guard resolvingRoots.insert(root).inserted else { return }
    roots[root, default: Root(resolution: .resolving)].resolution = .resolving
    source.defaultRepository(root) { result in
      self.resolvingRoots.remove(root)
      switch result {
      case .success(let repo):
        self.roots[root] = Root(resolution: .resolved, repo: repo)
        self.refresh(repo, .issue)
        self.refresh(repo, .pr)
        self.refreshReviewRequests(repo)
      case .failure(let reason):
        self.roots[root, default: Root(resolution: .resolving)].resolution = .unavailable(reason)
      }
    }
  }

  /// 自分を項目の担当者かレビュアーに足す。成功したら応答の値でその 1 件だけを一覧に差し込み、失敗したら
  /// 項目に記録する（画面の寿命に依らない）。`completion` は成否。自分の login が分からなければ書かない。
  func addSelf(
    as role: GitHubSelfRole, to id: GitHubItemID, kind: GitHubItemKind,
    completion: @escaping (Bool) -> Void
  ) {
    guard let login = viewer.login else { return completion(false) }
    writeFailures[id] = nil
    source.addSelf(role, id, login) { people in
      guard let people, people.contains(where: { $0.lowercased() == login.lowercased() }) else {
        self.writeFailures[id] = role
        return completion(false)
      }
      self.patch(id, kind) { item in
        switch role {
        case .assignee: item.assignees = people
        case .reviewer: item.pullRequest?.reviewers = people
        }
      }
      if role == .reviewer { self.repositories[id.repo]?.reviewRequests?.insert(id.number) }
      completion(true)
    }
  }

  /// 規則:
  /// - ページ: 今回分に足し（今回分に既にある番号は先のものを残す）、前回の残りとつないだ一覧を書く。
  /// - 完了: 今回分で置き換える。
  /// - 失敗: それまでに書いたまま（届いた範囲＋前回の残り）。
  private func refresh(_ repo: GitHubRepoName, _ kind: GitHubItemKind) {
    let key = RefreshKey(repo: repo, kind: kind)
    guard refreshes[key] == nil else { return }
    refreshes[key] = Refresh(previous: repositories[repo]?.list(kind).items)
    update(repo, kind) {
      $0.growing = true
      $0.failed = false
    }
    source.openItems(
      repo, kind,
      { nodes in
        guard var refresh = self.refreshes[key] else { return }
        var seen = Set(refresh.fresh.map(\.number))
        refresh.fresh += nodes.filter { seen.insert($0.number).inserted }.map { node in
          refresh.patches[node.number, default: []].reduce(into: node) { $1(&$0) }
        }
        self.refreshes[key] = refresh
        self.update(repo, kind) {
          $0.items = Self.merge(fresh: refresh.fresh, previous: refresh.previous)
        }
      },
      { succeeded in
        guard let refresh = self.refreshes[key] else { return }
        self.refreshes[key] = nil
        self.update(repo, kind) {
          if succeeded { $0.items = refresh.fresh }
          $0.growing = false
          $0.failed = !succeeded
        }
      })
  }

  private func refreshReviewRequests(_ repo: GitHubRepoName) {
    guard requestingReviews.insert(repo).inserted else { return }
    source.reviewRequests(repo) { result in
      self.requestingReviews.remove(repo)
      guard let result else { return }
      self.viewer.record(result.login)
      self.repositories[repo, default: Repository()].reviewRequests = result.numbers
    }
  }

  private func update(
    _ repo: GitHubRepoName, _ kind: GitHubItemKind, _ change: (inout List) -> Void
  ) {
    switch kind {
    case .issue: change(&repositories[repo, default: Repository()].issues)
    case .pr: change(&repositories[repo, default: Repository()].pullRequests)
    }
  }

  /// 一覧の 1 件を書き換える。進行中の取得の「前回」と「今回分」と、これから届くページにも当てる——差し込む
  /// 前に問い合わせた古いページが後から届いても、差し込んだ値を消さないため。
  private func patch(
    _ id: GitHubItemID, _ kind: GitHubItemKind,
    _ change: @escaping (inout GitHubOpenItem) -> Void
  ) {
    let apply = { (items: inout [GitHubOpenItem]?) in
      guard let index = items?.firstIndex(where: { $0.number == id.number }) else { return }
      change(&items![index])
    }
    update(id.repo, kind) { apply(&$0.items) }
    let key = RefreshKey(repo: id.repo, kind: kind)
    guard var refresh = refreshes[key] else { return }
    apply(&refresh.previous)
    var fresh: [GitHubOpenItem]? = refresh.fresh
    apply(&fresh)
    refresh.fresh = fresh ?? []
    refresh.patches[id.number, default: []].append(change)
    refreshes[key] = refresh
  }

  /// 取り直し途中の一覧。今回届いた分の後ろに、前回の一覧のうち「今回分に含まれる要素で前回の並びの
  /// 一番後ろにあるもの」より後ろをつなぐ（重ならなければ前回を全部つなぐ）。境目は前回の並び順だけで
  /// 決める——番号が作成順に振られている前提を置くと、移された issue で崩れる。
  static func merge<T: GitHubNumbered>(fresh: [T], previous: [T]?) -> [T] {
    guard let previous else { return fresh }
    let numbers = Set(fresh.map(\.number))
    let rest = previous.lastIndex { numbers.contains($0.number) }.map { $0 + 1 } ?? 0
    return fresh + previous[rest...]
  }
}
