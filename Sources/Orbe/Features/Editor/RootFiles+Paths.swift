import Foundation

/// ツリーの絞り込みの対象の一覧——根の下のファイルのうち、無視されているフォルダ（git がフォルダのまま返すもの。配下に
/// 追跡しているファイルを持たない）の中と既定の除外（`DefaultExcludes`）を除いたもの。単独で無視されているファイルと、無視の
/// 規則に当たる追跡しているファイルは対象に入る。
extension RootFiles {
  /// 一覧を取った結果。
  enum PathList: Equatable {
    /// 根からの相対パスの配列と、上限で打ち切ったか。
    case listed([String], isTruncated: Bool)
    /// git が失敗して取れなかった（呼び出し元は前に取れた一覧を保つ）。
    case failed
  }

  /// 一覧が持つパスの上限。
  static let pathListLimit = 200_000

  /// 絞り込みの対象の一覧を取る（`completion` は main で呼ぶ）。キューを根から始め、キューから取ったフォルダが git の作業ツリー
  /// の根なら git に 2 回問い合わせ、そうでなければディスクを走査する。どちらも、入れ子の根（サブモジュール・入れ子のリポジトリ・
  /// 走査していて `.git` を持つフォルダ）に出会ったら中へは入らずにキューへ足す。根で git が失敗したら全体を「取れなかった」に
  /// する。入れ子の根で git が失敗したら（壊れた `.git`）、根が git 管理下かの判定と同じ決まり（壊れた `.git` は管理外）で、
  /// 管理外として走査する。結果はキャッシュしない。git 管理下かの判定（`isResolved`）が済んでから呼ぶ。
  func listFilterPaths(completion: @escaping @MainActor (PathList) -> Void) {
    let root = self.root
    let rootIsManaged = repo != nil
    let runner = self.runner
    DispatchQueue.global(qos: .userInitiated).async {
      var collector = PathCollector(root: root, runner: runner)
      let list = collector.collect(rootIsManaged: rootIsManaged)
      DispatchQueue.main.async { completion(list) }
    }
  }
}

/// 一覧を集める、バックグラウンドでの 1 回分の処理。
private struct PathCollector {
  let root: String
  let runner: GitRunner

  /// 集めたパス（根からの相対）。
  private var paths: [String] = []
  /// 処理待ちのキュー（根からの相対のフォルダ。根は空）。
  private var pending: [String] = [""]

  init(root: String, runner: GitRunner) {
    self.root = root
    self.runner = runner
  }

  mutating func collect(rootIsManaged: Bool) -> RootFiles.PathList {
    while !pending.isEmpty, paths.count < RootFiles.pathListLimit {
      let directory = pending.removeFirst()
      let managed =
        directory.isEmpty
        ? rootIsManaged
        : FileManager.default.fileExists(atPath: absolute(directory) + "/.git")
      if managed, askGit(directory) { continue }
      if managed, directory.isEmpty { return .failed }
      walk(directory)
    }
    let isTruncated = paths.count >= RootFiles.pathListLimit
    return .listed(Array(paths.prefix(RootFiles.pathListLimit)), isTruncated: isTruncated)
  }

  private func absolute(_ directory: String) -> String {
    directory.isEmpty ? root : root + "/" + directory
  }

  private func join(_ directory: String, _ path: String) -> String {
    directory.isEmpty ? path : directory + "/" + path
  }

  private mutating func add(_ path: String) {
    if !DefaultExcludes.contains(path) { paths.append(path) }
  }

  /// git の作業ツリーの根 `directory` を git に問い合わせる。入れ子の根では `GitFileList.nestedOptions` を足す。skip-worktree
  /// のファイルは、ディスクに在るものだけを足す。どちらかの git が失敗したら何も足さずに false。
  private mutating func askGit(_ directory: String) -> Bool {
    let cwd = absolute(directory)
    let options = directory.isEmpty ? [] : GitFileList.nestedOptions(workTree: cwd)
    let listed = runner.runSync(options + GitFileList.listedArguments, cwd: cwd)
    guard listed.ending == .completed, listed.isSuccess else { return false }
    let ignored = runner.runSync(options + GitFileList.ignoredArguments, cwd: cwd)
    guard ignored.ending == .completed, ignored.isSuccess else { return false }
    let read = GitFileList.parseListed(listed.stdout)
    let present = read.skipped.filter { isFile(join(directory, $0)) }
    for path in read.files + present + GitFileList.parseIgnored(ignored.stdout) {
      add(join(directory, path))
    }
    for nested in read.nestedRoots where !DefaultExcludes.containsDirectory(join(directory, nested))
    {
      pending.append(join(directory, nested))
    }
    return true
  }

  /// `path` がディスクにフォルダ以外として在るか（symlink は辿らない）。
  private func isFile(_ path: String) -> Bool {
    var info = stat()
    return lstat(absolute(path), &info) == 0 && info.st_mode & S_IFMT != S_IFDIR
  }

  /// `directory` の下をディスクで走査する。symlink は辿らず、`.git` はフォルダでもファイルでも数えず（ツリーの一覧と同じ
  /// 判定）、既定の除外のフォルダには入らず、`.git` を持つフォルダは入らずに入れ子の根としてキューへ足す。
  private mutating func walk(_ directory: String) {
    var folders = [directory]
    while let folder = folders.popLast(), paths.count < RootFiles.pathListLimit {
      RootFiles.forEachChild(of: absolute(folder)) { name, isDirectory in
        let path = join(folder, name)
        if !isDirectory {
          add(path)
        } else if DefaultExcludes.directories.contains(name) {
          // 既定の除外のフォルダには入らない（`.git` は `forEachChild` が渡さない）。
        } else if FileManager.default.fileExists(atPath: absolute(path) + "/.git") {
          pending.append(path)
        } else {
          folders.append(path)
        }
        return true
      }
    }
  }
}
