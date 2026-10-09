import Foundation
import OrbeEditorCore

/// 根のサービスからの通知。(a) はデバウンス後すぐ、(b) は status が返った時点、(c) は版の本文の取り直しの完了後に届く。
@MainActor
protocol RootFilesObserver: AnyObject {
  /// 根の下でファイルが変わった（git dir の中は含まない）。
  func rootFiles(_ files: RootFiles, filesDidChange change: RootFiles.Change)
  /// status が新しくなった（git 管理下のみ）。
  func rootFilesStatusDidChange(_ files: RootFiles)
  /// 関心を申告した版の本文の状態が変わった（その版に無くなった・取れなくなったも含む）。
  func rootFiles(_ files: RootFiles, versionDidChange version: RootFiles.Version)
}

/// 根（`GitWorktreeRoot.root(of:)` の値）1 つにつき 1 つの、監視・git 状態・一覧・新規作成・版の本文・git の書き込みを
/// 担うサービス。握る者（文書の結線・面のツリー・プロジェクト検索）がいる間だけ生き、離されれば監視が止まる。書き込みが
/// 完了を返すまでは、その返りを待つ処理も握る（→ `RootFiles+Writes`）。
///
/// git 管理下かどうかはここで決める: 根に `.git` があれば `GitRepo` を開き、git の綴りを正規形に揃えて根と
/// 一致したときだけ管理下（status・版の本文・git dir の監視・書き込みを持つ）。`GitRepo.root` との突き合わせは
/// ここ 1 か所に閉じる。管理外なら監視と一覧・新規作成だけが働く。
///
/// 観測は 2 本の取り直しで成る——status と、版の本文（関心のある（パス, 版）ごとの OID → 変わった OID の blob）。版は
/// index と HEAD で、文書の底（baseline）と diff の両側が同じ 1 か所の本文を引く。両者にデータの依存は無く、根ごとに
/// 別々に直列化し、どちらも実行中に来た要求は「終わったらもう 1 回」に畳む。古い結果が後から乗らない（index や HEAD が
/// 動けば監視が取り直す。status と版の本文は別々の git 起動で読むので同一時点の保証は無い）。別々にするのは、版の本文の
/// 取得が smudge filter（git-lfs のネットワーク等）で遅くなりうるから——その後ろにバッジと書き込みの完了を並べない。
@MainActor
final class RootFiles {
  struct Entry: Equatable {
    let name: String
    let url: URL
    /// symlink は辿らない（リンク自体の種類）。
    let isDirectory: Bool
  }

  enum Change: Equatable {
    /// 変わったパス（根の綴りの絶対パス）。
    case paths(Set<String>)
    /// 取りこぼしがあった。全部見直す。
    case scanAll

    func includes(_ path: String) -> Bool {
      switch self {
      case .paths(let paths): return paths.contains(path)
      case .scanAll: return true
      }
    }
  }

  enum Error: Swift.Error, Equatable {
    case alreadyExists(URL)
  }

  /// 関心の単位——根からの相対パスと版。
  struct Version: Hashable {
    let path: String
    let revision: GitRevision
  }

  /// 版の本文の状態（OID ごとに決まる）。
  enum VersionState: Equatable {
    /// 本文（作業ツリーに出したときの姿）。
    case text(String)
    /// その版に無い（index に無い・競合中・初回コミット前の HEAD を含む。ファイルでないものも）。
    case absent
    /// UTF-8 として読めない。
    case notText
    /// git から取れない（取り直しの上限に達した）。
    case failed

    var text: String? {
      if case .text(let text) = self { return text }
      return nil
    }
  }

  private final class WeakRef {
    weak var value: RootFiles?
    init(_ value: RootFiles) { self.value = value }
  }

  private static var registry: [String: WeakRef] = [:]

  /// 生きているサービスがあればそれを、無ければ作って返す。返ったものを強参照で握る者がいる間だけ生きる。
  static func shared(for root: String) -> RootFiles {
    registry = registry.filter { $0.value.value != nil }
    if let live = registry[root]?.value { return live }
    let files = RootFiles(root: root)
    registry[root] = WeakRef(files)
    return files
  }

  let root: String
  private let runner: GitRunner
  /// nil = 管理外（または解決前）。
  private(set) var repo: GitRepo?
  /// git 管理下かの判定が済んだか。
  private(set) var isResolved = false
  /// 最後に成功した取り直しの結果（git 管理下のみ。失敗では変わらない）。
  private(set) var status: GitStatus?
  private var observations: [Observation] = []
  /// 根の監視。git 管理下と分かっても張り替えない（張り替えの隙間に届いたイベントが落ちる）。
  private var rootWatcher: RepoWatcher?
  /// git dir（gitDir・commonDir）の監視。管理下と分かったときに足す。
  private var gitWatcher: RepoWatcher?
  /// 関心のある版 → OID と本文の状態。
  private var versions: [Version: Settled] = [:]
  private var statusJob = RefreshJob()
  private var versionJob = RefreshJob()
  /// 次に始まる status の取り直しが済んだら呼ぶもの（書き込みの完了）。
  private var statusWaiters: [() -> Void] = []
  /// 同じ worktree の index への書き込みの順番待ち（先頭から 1 つずつ走らせる）。
  var queuedWrites: [QueuedWrite] = []
  var isWriting = false

  /// 取り直し 1 本の直列化。実行中に来た要求は「終わったらもう 1 回」に畳む。
  private struct RefreshJob {
    var isRunning = false
    var again = false
  }

  private struct Observation {
    weak var observer: RootFilesObserver?
    var versions: Set<Version>

    var isLive: Bool { observer != nil }
  }

  /// 生きている観測者（`observer` が解けた `Observation`）。
  private struct LiveObservation {
    let observer: RootFilesObserver
    let versions: Set<Version>
  }

  /// 取り終えた版——OID（その版に無ければ nil）と本文の状態。
  private struct Settled {
    let oid: String?
    let state: VersionState
  }

  /// blob の取得が git の失敗で落ちた回数（版 → その OID と回数）。`blobFailureBudget` 回で諦める。
  private var blobFailures: [Version: (oid: String, count: Int)] = [:]
  /// 同じ OID を取り直す上限。一時失敗（LFS のネットワーク等）は次の取り直しで回復させ、恒久失敗
  /// （必須 filter の欠落・打ち切り）を毎バッチ回さない——smudge が監視対象へ書く自走ループも閉じる。
  static let blobFailureBudget = 3

  init(root: String, runner: GitRunner = .shared) {
    self.root = root
    self.runner = runner
    rootWatcher = watch(roots: [root], gitDirs: [])
    guard FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(".git"))
    else {
      isResolved = true
      return
    }
    GitRepo.open(cwd: root, runner: runner) { [weak self] repo in
      guard let self else { return }
      isResolved = true
      guard let repo, GitWorktreeRoot.normalizedPath(repo.root) == self.root else { return }
      self.repo = repo
      let gitDirs = [repo.gitDir, repo.commonDir]
      gitWatcher = watch(roots: gitDirs, gitDirs: gitDirs)
      requestStatusRefresh()
      requestVersionRefresh()
    }
  }

  // MARK: - 観測者

  /// weak に持つ。`versions` は本文を追う版。追う集合は生きている観測者の関心の和集合で、観測者が消えれば関心も
  /// 消える。既に取れている版の状態は `state(of:)` で同期に引ける。
  func addObserver(_ observer: RootFilesObserver, versions: Set<Version> = []) {
    prune()
    observations.append(Observation(observer: observer, versions: versions))
    if !versions.isEmpty { requestVersionRefresh() }
  }

  /// 観測者の関心を置き換える（diff の rename の元パスが変わったときなど）。増えた版があれば取り直す。
  func setVersions(_ versions: Set<Version>, for observer: RootFilesObserver) {
    guard let index = observations.firstIndex(where: { $0.observer === observer }) else { return }
    let added = !versions.subtracting(observations[index].versions).isEmpty
    observations[index].versions = versions
    dropUnwantedVersions()
    if added { requestVersionRefresh() }
  }

  func removeObserver(_ observer: RootFilesObserver) {
    observations.removeAll { !$0.isLive || $0.observer === observer }
    dropUnwantedVersions()
  }

  private func prune() {
    guard observations.contains(where: { !$0.isLive }) else { return }
    observations.removeAll { !$0.isLive }
    dropUnwantedVersions()
  }

  /// 生きている観測者だけ（死んだ要素は次の観測者の出入りで `prune` が捨てる）。読む側は必ずここを通る。
  private var live: [LiveObservation] {
    observations.compactMap { observation in
      observation.observer.map { LiveObservation(observer: $0, versions: observation.versions) }
    }
  }

  /// 生きている観測者の関心の和集合。
  private var interests: Set<Version> {
    live.reduce(into: Set<Version>()) { $0.formUnion($1.versions) }
  }

  private func dropUnwantedVersions() {
    let wanted = interests
    versions = versions.filter { wanted.contains($0.key) }
    blobFailures = blobFailures.filter { wanted.contains($0.key) }
  }

  /// 実体のパス `url` の根からの相対パス（根の外なら nil）。
  func relativePath(of url: URL) -> String? {
    let path = GitWorktreeRoot.normalizedPath(url.path)
    guard path.hasPrefix(root + "/") else { return nil }
    return String(path.dropFirst(root.count + 1))
  }

  /// 関心を申告した版の本文の状態（まだ取れていなければ nil）。
  func state(of version: Version) -> VersionState? {
    versions[version]?.state
  }

  // MARK: - 監視

  private func watch(roots: [String], gitDirs: [String]) -> RepoWatcher? {
    RepoWatcher(roots: roots, gitDirs: gitDirs) { [weak self] batch in self?.handle(batch) }
  }

  private func handle(_ batch: RepoWatcher.Batch) {
    if batch.scanAll {
      notify { $0.rootFiles(self, filesDidChange: .scanAll) }
    } else if !batch.paths.isEmpty {
      notify { $0.rootFiles(self, filesDidChange: .paths(batch.paths)) }
    }
    requestStatusRefresh()
    requestVersionRefresh()
  }

  private func notify(_ body: (RootFilesObserver) -> Void) {
    for observation in live { body(observation.observer) }
  }

  // MARK: - status の取り直し

  /// status を取り直す。`then` は、この要求の後に始まる取り直しが済んだら（通知した・値が同じ・git の失敗のどれでも）
  /// 呼ぶ——実行中の取り直しは要求より前の状態を読んでいるかもしれないので、それには付けない。
  func requestStatusRefresh(then waiter: (() -> Void)? = nil) {
    guard repo != nil else {
      waiter?()
      return
    }
    if let waiter { statusWaiters.append(waiter) }
    if statusJob.isRunning {
      statusJob.again = true
      return
    }
    refreshStatus()
  }

  private func refreshStatus() {
    guard let repo else { return }
    statusJob.isRunning = true
    let waiters = statusWaiters
    statusWaiters = []
    repo.status(comparedTo: status) { [weak self] read in
      guard let self else { return }
      publish(read)
      // 通知と待ち手を呼ぶ間も「実行中」を保つ——その中から取り直しを求められても（書き込みの完了の中で次の書き込みを
      // 始める等）、ここで 2 本目を並走させず「もう 1 回」に畳む。
      for waiter in waiters { waiter() }
      statusJob.isRunning = false
      if statusJob.again {
        statusJob.again = false
        refreshStatus()
      }
    }
  }

  /// git の一時失敗では前の status を保つ——「最後に成功した取り直しの結果」が status の意味で、失敗のたびにバッジが
  /// 消えて戻らないため。比べる相手は取り直しを始めたときの status で、取り直しは直列なので今の値と同じ。
  ///
  /// 置き換えた status は裏で手放す。観測者は通知の中で新しい値へ持ち替えるので、裏へ渡した参照が最後になる——未追跡が
  /// 多いと数万の文字列の解放になり、main に載せない。
  private func publish(_ read: GitStatusRead) {
    guard case .changed(let status) = read else { return }
    let replaced = self.status
    self.status = status
    notify { $0.rootFilesStatusDidChange(self) }
    DispatchQueue.global(qos: .utility).async { withExtendedLifetime(replaced) {} }
  }

  // MARK: - 版の本文の取り直し

  private func requestVersionRefresh() {
    guard repo != nil else { return }
    if versionJob.isRunning {
      versionJob.again = true
      return
    }
    refreshVersions()
  }

  /// 関心のある版の OID を版ごとに 1 回で引き、OID が変わったものだけ本文を取る。
  private func refreshVersions() {
    guard let repo else { return }
    versionJob.isRunning = true
    let interests = self.interests
    let index = interests.filter { $0.revision == .index }.map(\.path).sorted()
    let head = interests.filter { $0.revision == .head }.map(\.path).sorted()
    repo.indexEntries(relativePaths: index) { [weak self] indexOIDs in
      repo.headEntries(relativePaths: head) { [weak self] headOIDs in
        guard let self else { return }
        var changed: [Version] = []
        var fetch: [(version: Version, oid: String)] = []
        let ordered = interests.sorted {
          $0.path != $1.path ? $0.path < $1.path : $0.revision == .index
        }
        for version in ordered {
          let oids = version.revision == .index ? indexOIDs : headOIDs
          guard let oids else { continue }
          if let oid = oids[version.path] {
            if versions[version]?.oid != oid { fetch.append((version, oid)) }
          } else {
            if versions[version]?.state != .absent { changed.append(version) }
            versions[version] = Settled(oid: nil, state: .absent)
          }
        }
        fetchBlobs(fetch[...], changed: changed)
      }
    }
  }

  /// 変わった OID の blob を 1 つずつ取る（並列に投げない）。
  private func fetchBlobs(
    _ pending: ArraySlice<(version: Version, oid: String)>, changed: [Version]
  ) {
    guard let repo, let next = pending.first else {
      finish(changed: changed)
      return
    }
    repo.blob(oid: next.oid, relativePath: next.version.path) { [weak self] data in
      guard let self else { return }
      var changed = changed
      let version = next.version
      // git の失敗（smudge の失敗・打ち切り。一時的でありうる）は上限までは記録せず、次の取り直しで同じ OID を
      // 取り直す。上限に達したら OID ごと「取れない」を焼き、OID が変わるまで諦める。UTF-8 でない中身は
      // 恒久なので即座に OID ごと「読めない」を記録する。
      let settled: Settled?
      if let data {
        blobFailures[version] = nil
        settled = Settled(
          oid: next.oid,
          state: String(data: data, encoding: .utf8).map(VersionState.text) ?? .notText)
      } else {
        let previous = blobFailures[version]
        let count = (previous?.oid == next.oid ? previous?.count ?? 0 : 0) + 1
        blobFailures[version] = (next.oid, count)
        settled = count >= Self.blobFailureBudget ? Settled(oid: next.oid, state: .failed) : nil
      }
      if let settled {
        if versions[version]?.state != settled.state { changed.append(version) }
        versions[version] = settled
      }
      fetchBlobs(pending.dropFirst(), changed: changed)
    }
  }

  private func finish(changed: [Version]) {
    // 連鎖の最中に関心が消えた版（取り始めたときの集合で走り切る）を書き戻さない。
    dropUnwantedVersions()
    for observation in live {
      for version in changed where observation.versions.contains(version) {
        observation.observer.rootFiles(self, versionDidChange: version)
      }
    }
    versionJob.isRunning = false
    if versionJob.again {
      versionJob.again = false
      refreshVersions()
    }
  }
}
