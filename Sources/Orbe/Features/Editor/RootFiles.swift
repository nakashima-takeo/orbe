import Foundation

/// 根のサービスからの通知。(a) はデバウンス後すぐ、(b)(c) は取り直しジョブの完了後に届く。
@MainActor
protocol RootFilesObserver: AnyObject {
  /// 根の下でファイルが変わった（git dir の中は含まない）。
  func rootFiles(_ files: RootFiles, filesDidChange change: RootFiles.Change)
  /// status が新しくなった（git 管理下のみ）。
  func rootFilesStatusDidChange(_ files: RootFiles)
  /// 関心を申告したファイルの baseline が変わった（index に無くなった → nil も含む）。
  func rootFiles(_ files: RootFiles, baselineDidChange url: URL)
}

/// 根（`GitWorktreeRoot.root(of:)` の値）1 つにつき 1 つの、監視・git 状態・一覧・新規作成・baseline を担う
/// サービス。握る者（文書の結線・面のツリー）がいる間だけ生き、離されれば監視が止まる。
///
/// git 管理下かどうかはここで決める: 根に `.git` があれば `GitRepo` を開き、git の綴りを正規形に揃えて根と
/// 一致したときだけ管理下（status・baseline・git dir の監視を持つ）。`GitRepo.root` との突き合わせは
/// ここ 1 か所に閉じる。管理外なら監視と一覧・新規作成だけが働く。
///
/// 観測（status → 関心のあるパスの index の OID → 変わった OID の blob）は根ごとに 1 本のジョブに直列化し、
/// 実行中に来た要求は「終わったらもう 1 回」に畳む。結果は常に最新の index を映す（古い結果が後から乗らない）。
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
  private(set) var status: GitStatus?
  private var observations: [Observation] = []
  /// 根の監視。git 管理下と分かっても張り替えない（張り替えの隙間に届いたイベントが落ちる）。
  private var rootWatcher: RepoWatcher?
  /// git dir（gitDir・commonDir）の監視。管理下と分かったときに足す。
  private var gitWatcher: RepoWatcher?
  /// 関心のある相対パス → index 版。
  private var baselines: [String: Baseline] = [:]
  private var isRefreshing = false
  private var refreshAgain = false

  private struct Observation {
    weak var observer: RootFilesObserver?
    let interest: URL?
    let relativePath: String?
  }

  private struct Baseline {
    let oid: String?
    let text: String?
  }

  init(root: String, runner: GitRunner = .shared) {
    self.root = root
    self.runner = runner
    rootWatcher = watch(roots: [root], gitDirs: [])
    guard FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(".git"))
    else { return }
    GitRepo.open(cwd: root, runner: runner) { [weak self] repo in
      guard let self, let repo, GitWorktreeRoot.normalizedPath(repo.root) == self.root else {
        return
      }
      self.repo = repo
      let gitDirs = [repo.gitDir, repo.commonDir]
      gitWatcher = watch(roots: gitDirs, gitDirs: gitDirs)
      requestRefresh()
    }
  }

  // MARK: - 観測者

  /// weak に持つ。`interest` は baseline を追うファイル（実体のパス）。追う集合は生きている観測者の関心の
  /// 和集合で、観測者が消えれば関心も消える。既に取れている baseline は `baseline(for:)` で同期に引ける。
  func addObserver(_ observer: RootFilesObserver, interest: URL? = nil) {
    prune()
    observations.append(
      Observation(
        observer: observer, interest: interest, relativePath: interest.flatMap(relativePath(of:))))
    if interest != nil { requestRefresh() }
  }

  func removeObserver(_ observer: RootFilesObserver) {
    observations.removeAll { $0.observer == nil || $0.observer === observer }
    dropUnwantedBaselines()
  }

  private func prune() {
    guard observations.contains(where: { $0.observer == nil }) else { return }
    observations.removeAll { $0.observer == nil }
    dropUnwantedBaselines()
  }

  private var interests: [String] {
    Array(Set(observations.compactMap(\.relativePath))).sorted()
  }

  private func dropUnwantedBaselines() {
    let wanted = Set(interests)
    baselines = baselines.filter { wanted.contains($0.key) }
  }

  private func relativePath(of url: URL) -> String? {
    let path = GitWorktreeRoot.normalizedPath(url.path)
    guard path.hasPrefix(root + "/") else { return nil }
    return String(path.dropFirst(root.count + 1))
  }

  /// 関心を申告したファイルの index 版（取れていなければ・index に無ければ nil）。
  func baseline(for url: URL) -> String? {
    relativePath(of: url).flatMap { baselines[$0]?.text }
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
    requestRefresh()
  }

  private func notify(_ body: (RootFilesObserver) -> Void) {
    for observation in observations {
      if let observer = observation.observer { body(observer) }
    }
  }

  // MARK: - 取り直しジョブ

  private func requestRefresh() {
    guard repo != nil else { return }
    if isRefreshing {
      refreshAgain = true
      return
    }
    refresh()
  }

  private func refresh() {
    guard let repo else { return }
    isRefreshing = true
    let interests = self.interests
    repo.status { [weak self] status in
      guard let self else { return }
      repo.indexEntries(relativePaths: interests) { [weak self] oids in
        guard let self else { return }
        guard let oids else {
          finish(status: status, changed: [])
          return
        }
        var changed: [String] = []
        var fetch: [(relativePath: String, oid: String)] = []
        for relativePath in interests {
          if let oid = oids[relativePath] {
            if baselines[relativePath]?.oid != oid { fetch.append((relativePath, oid)) }
          } else {
            if baselines[relativePath]?.text != nil { changed.append(relativePath) }
            baselines[relativePath] = Baseline(oid: nil, text: nil)
          }
        }
        fetchBlobs(fetch[...], status: status, changed: changed)
      }
    }
  }

  /// 変わった OID の blob を 1 つずつ取る（並列に投げない）。
  private func fetchBlobs(
    _ pending: ArraySlice<(relativePath: String, oid: String)>, status: GitStatus?,
    changed: [String]
  ) {
    guard let repo, let next = pending.first else {
      finish(status: status, changed: changed)
      return
    }
    repo.blob(oid: next.oid) { [weak self] data in
      guard let self else { return }
      let text = data.flatMap { String(data: $0, encoding: .utf8) }
      var changed = changed
      if baselines[next.relativePath]?.text != text { changed.append(next.relativePath) }
      baselines[next.relativePath] = Baseline(oid: next.oid, text: text)
      fetchBlobs(pending.dropFirst(), status: status, changed: changed)
    }
  }

  private func finish(status: GitStatus?, changed: [String]) {
    if status != self.status {
      self.status = status
      notify { $0.rootFilesStatusDidChange(self) }
    }
    for observation in observations {
      guard let observer = observation.observer, let interest = observation.interest,
        let relativePath = observation.relativePath, changed.contains(relativePath)
      else { continue }
      observer.rootFiles(self, baselineDidChange: interest)
    }
    isRefreshing = false
    if refreshAgain {
      refreshAgain = false
      refresh()
    }
  }

  // MARK: - 一覧と新規作成

  /// ディレクトリの中身（`.git` を除く。ドットファイルは含む）。名前順（大小無視）。
  func entries(of directory: URL) throws -> [Entry] {
    let manager = FileManager.default
    return try manager.contentsOfDirectory(atPath: directory.path)
      .filter { $0 != ".git" }
      .map { name in
        let url = directory.appendingPathComponent(name)
        let type = (try? manager.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
        let isDirectory = type == .typeDirectory
        return Entry(
          name: name, url: directory.appendingPathComponent(name, isDirectory: isDirectory),
          isDirectory: isDirectory)
      }
      .sorted { $0.name.caseInsensitiveCompare($1.name) == .orderedAscending }
  }

  /// 空ファイルを作る。既に在れば失敗。中間ディレクトリは作らない。
  func createFile(at url: URL) throws {
    guard !FileManager.default.fileExists(atPath: url.path) else { throw Error.alreadyExists(url) }
    try Data().write(to: url)
  }

  /// フォルダを作る。既に在れば失敗。中間ディレクトリは作らない。
  func createDirectory(at url: URL) throws {
    guard !FileManager.default.fileExists(atPath: url.path) else { throw Error.alreadyExists(url) }
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
  }
}
