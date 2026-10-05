import Foundation

/// cwd が属する git worktree ルートを、`.git`（ディレクトリでも file でも＝linked worktree は file）を
/// 親方向へ探して同期で求める（ルートが checkout しているブランチも同じく `.git` から読む）。サブプロセスを
/// 使わない（OSC 7 はプロンプトごとに届く）。
enum GitWorktreeRoot {
  /// 比較用の正準形（standardizingPath → resolvingSymlinksInPath）。symlink を解いたうえで先頭の
  /// `/private` を畳むので、返るのは実パスではなく短縮形（`/private/tmp` → `/tmp`）。OSC 7 の論理パス・
  /// 復元 cwd・`git worktree list` のパスを同じ土俵に乗せる唯一の実装（macOS では `/tmp` `/var` が symlink）。
  /// どちらの変換も**実在する部分にしか効かない**ので、不在パスは末尾がそのまま残る。
  static func normalizedPath(_ path: String) -> String {
    ((path as NSString).standardizingPath as NSString).resolvingSymlinksInPath
  }

  /// パスが属する根。「それを含む worktree のルート、git の外なら正規化したそのパス」の規則の唯一の置き場。
  /// タブの連（`TerminalTab.groupKey`）・エディターの根（文書の結線が属する根のサービス）・タスクの worktree
  /// （`TaskWorktree`）が同じこの値で比べる。
  static func root(of path: String) -> String {
    locate(cwd: path) ?? normalizedPath(path)
  }

  /// 正規化した cwd から自身を含めて `/` まで上へ辿り、最初に `.git` を持つディレクトリ（正準形）。
  /// 無ければ nil。存在しないパス（消えた worktree）は `.git` が見つからないまま祖先へ上がるだけ——
  /// cwd が不在だと入口の正規化は効かないので、見つけたルートを改めて正準化して返す（`.git` が
  /// 見えた時点でそのディレクトリは実在する）。
  static func locate(cwd: String) -> String? {
    var dir = normalizedPath(cwd)
    while true {
      if FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(".git")) {
        return normalizedPath(dir)
      }
      let parent = (dir as NSString).deletingLastPathComponent
      guard parent != dir else { return nil }
      dir = parent
    }
  }

  /// worktree のルートが今 checkout しているブランチの名前。gitdir の HEAD を同期で読む——サブプロセスを
  /// 使わない（chrome の更新ごとに読む）。detached・git の外・HEAD をファイルから読めないとき（reftable の
  /// リポジトリの HEAD は `refs/heads/.invalid` を指す互換の置き物で、ブランチは ref の表にある）は nil
  /// （ブランチ不明）。
  static func branch(at root: String) -> String? {
    guard let gitDir = GitWorktreeOperationProbe.gitDir(worktreeAt: root) else { return nil }
    return symbolicRef(
      atPath: (gitDir as NSString).appendingPathComponent("HEAD"), under: "refs/heads/")
  }

  /// worktree のリポジトリの既定ブランチ（`refs/remotes/origin/HEAD` の指すブランチのローカル名）。
  /// common dir（linked worktree では gitdir の `commondir` が指す先）のそのファイルを同期で読み、
  /// 無ければ `main`（reftable のリポジトリは ref をファイルに持たないので、origin/HEAD があっても
  /// `main`）。git の外・ファイルを読めない・形が違うときは nil。
  static func defaultBranch(at root: String) -> String? {
    guard let gitDir = GitWorktreeOperationProbe.gitDir(worktreeAt: root) else { return nil }
    var commonDir = gitDir
    if let pointer = try? String(
      contentsOfFile: (gitDir as NSString).appendingPathComponent("commondir"), encoding: .utf8),
      let line = pointer.split(whereSeparator: \.isNewline).first
    {
      let path = String(line)
      commonDir =
        path.hasPrefix("/")
        ? path
        : ((gitDir as NSString).appendingPathComponent(path) as NSString)
          .standardizingPath
    }
    let originHead = (commonDir as NSString).appendingPathComponent("refs/remotes/origin/HEAD")
    guard FileManager.default.fileExists(atPath: originHead) else { return "main" }
    return symbolicRef(atPath: originHead, under: "refs/remotes/origin/")
  }

  /// `ref: <prefix><name>` を書いたファイルの name。読めない・形が違う・ブランチ名として不正（`.` で始まる段
  /// を持つ。reftable の置き物の `.invalid` を含む）なら nil。
  private static func symbolicRef(atPath path: String, under prefix: String) -> String? {
    guard let content = try? String(contentsOfFile: path, encoding: .utf8),
      let line = content.split(whereSeparator: \.isNewline).first,
      line.hasPrefix("ref: " + prefix)
    else { return nil }
    let name = String(line.dropFirst(("ref: " + prefix).count))
    guard !name.isEmpty, !name.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else {
      return nil
    }
    return name
  }
}
