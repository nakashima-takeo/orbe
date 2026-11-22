import Foundation
import OrbeTestSupport

@testable import Orbe

/// 実 git で 1 回だけ組んでおき、テストごとに複製して渡すリポジトリのテンプレート。
///
/// 複製の契約は「git から見て、git で組んだ直後と同じ状態のリポジトリを渡す」。複製しただけでは、index が覚えている
/// ファイルの情報（inode・ctime）が複製の作業ツリーと食い違う。そのままだと、index を読み直さずに比べる git
/// （`git diff-files`）は追跡ファイルを変更ありとして出力し、素の `git status` は `.git/index` を書き換える（ファイル監視には
/// git の変化として届く）。そこで複製の最後に、追跡ファイルを持つ作業ツリーごとに `git update-index -q --refresh` で
/// index を作業ツリーに合わせる。
///
/// 契約の例外として、clone の `remote.*.url` は、テンプレートの中の bare リポジトリを指したまま複製される。複製の中の
/// bare リポジトリへ向け直すのは、テンプレートを使う側（`StaleCloneFixture.place` など、組ごとの置き方）の役目。
///
/// テンプレートの追跡ファイルの時刻は、作り終えるときに過去へずらす。git は、index を書いた時刻と同じ秒に変わった
/// ファイル（racy git）を、変わっていないと言い切れないので、素の `git status` のたびに中身を読み直して `.git/index` を
/// 書き換える。ずらさないと、テンプレートを作ってから 1 秒未満の複製だけが `.git/index` を書き換えることになり、ファイル監視に届く通知の数が
/// テストの実行の順序と時刻で変わる。
///
/// テンプレートは `TestScratch.root` の下に、最初に複製を求めたテストの中で作る（作成の時間はそのテストに入る）。
/// 作り終えたら中の全ディレクトリから所有者の書き込み権限を外すので、テンプレートの中にファイルを作る・消す・置き換える
/// 書き込みは、その場で失敗する（git が ref・index・設定・オブジェクトを書くときは、どれもこれに当たる）。後始末は
/// `TestScratch` が持つ。
final class GitFixtureTemplate {
  struct Failure: Error, CustomStringConvertible {
    let description: String
  }

  private struct Built {
    let url: URL
    /// 追跡ファイルを持つ作業ツリーの、テンプレートの根からの相対パス（根自身は空文字列）。
    let trackedWorktrees: [String]
  }

  private let name: String
  private let build: (URL) throws -> Void
  private var built: Built?

  /// `build` は空のディレクトリを受け取り、その中を実 git で組む。前提が崩れたら throw する。
  init(name: String, build: @escaping (URL) throws -> Void) {
    self.name = name
    self.build = build
  }

  /// `destination`（まだ無いパス）へ複製する。テストの中（インスタンスの `setUp` かテスト本文）でだけ呼ぶ。
  func copy(to destination: URL) throws {
    let built = try self.built ?? make()
    self.built = built
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: built.url, to: destination)
    try Self.setOwnerWrite(true, under: destination)
    for relative in built.trackedWorktrees {
      try Self.git(["update-index", "-q", "--refresh"], in: Self.path(relative, in: destination))
    }
  }

  /// 足場が使う git（組み方と、複製の後の調整）。失敗したら、引数と標準エラーを入れて throw する。
  @discardableResult
  static func git(_ args: [String], in cwd: String) throws -> GitRunner.Output {
    let output = GitRunner.shared.runSync(args, cwd: cwd)
    guard output.isSuccess else {
      throw Failure(description: "git \(args.joined(separator: " ")): \(output.stderrText)")
    }
    return output
  }

  private func make() throws -> Built {
    let url = TestScratch.root.appendingPathComponent("\(name)-\(UUID().uuidString)")
    do {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      try build(url)
      let tracked = try Self.settleTrackedWorktrees(under: url)
      try Self.setOwnerWrite(false, under: url)
      return Built(url: url, trackedWorktrees: tracked)
    } catch {
      try? Self.setOwnerWrite(true, under: url)
      try? FileManager.default.removeItem(at: url)
      throw error
    }
  }

  /// `root` の下で、`.git` ディレクトリを持ち、追跡ファイルの在る作業ツリー（`.git` の中は探さない）を返す。
  /// それぞれの追跡ファイルの時刻を過去へずらし、index を作業ツリーに合わせる。
  private static func settleTrackedWorktrees(under root: URL) throws -> [String] {
    var result: [String] = []
    for relative in directories(under: root) where !relative.split(separator: "/").contains(".git")
    {
      let worktree = path(relative, in: root)
      var isDirectory: ObjCBool = false
      guard
        FileManager.default.fileExists(
          atPath: (worktree as NSString).appendingPathComponent(".git"), isDirectory: &isDirectory),
        isDirectory.boolValue
      else { continue }
      let files = try git(["ls-files", "-z"], in: worktree).stdoutText
        .split(separator: "\0").map(String.init)
      guard !files.isEmpty else { continue }
      for file in files { try backdate((worktree as NSString).appendingPathComponent(file)) }
      try git(["update-index", "-q", "--refresh"], in: worktree)
      result.append(relative)
    }
    return result
  }

  /// `path` の更新時刻とアクセス時刻を、今の 1 分前にする（symlink は辿らない）。
  private static func backdate(_ path: String) throws {
    let past = timeval(tv_sec: time(nil) - 60, tv_usec: 0)
    guard lutimes(path, [past, past]) == 0 else { throw Failure(description: "lutimes \(path)") }
  }

  /// `root` の下の全ディレクトリの、`root` からの相対パス（`root` 自身は空文字列）。symlink は辿らない。
  private static func directories(under root: URL) -> [String] {
    var result = [""]
    let enumerator = FileManager.default.enumerator(atPath: root.path)
    while let relative = enumerator?.nextObject() as? String {
      if enumerator?.fileAttributes?[.type] as? FileAttributeType == .typeDirectory {
        result.append(relative)
      }
    }
    return result
  }

  private static func path(_ relative: String, in root: URL) -> String {
    (root.path as NSString).appendingPathComponent(relative)
  }

  /// `root` の下の全ディレクトリ（`root` を含む）の、所有者の書き込み権限を付ける・外す。ファイルの権限は変えない。
  private static func setOwnerWrite(_ writable: Bool, under root: URL) throws {
    for relative in directories(under: root) {
      let directory = path(relative, in: root)
      var info = stat()
      guard lstat(directory, &info) == 0 else { throw Failure(description: "lstat \(directory)") }
      let mode = writable ? info.st_mode | S_IWUSR : info.st_mode & ~S_IWUSR
      guard chmod(directory, mode & 0o7777) == 0 else {
        throw Failure(description: "chmod \(directory)")
      }
    }
  }
}
