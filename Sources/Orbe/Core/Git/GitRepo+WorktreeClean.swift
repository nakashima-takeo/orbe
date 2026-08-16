import Foundation

// MARK: - worktree の掃除（安全確認・削除）

/// `status --porcelain` の件数。行の語彙 `未コミット N ファイル` / `untracked N ファイル` の出どころで、
/// 同時に `--force` 削除を止める関門（`isClean`）でもある——同じ 1 本の出力を 2 つの役が読む。
struct GitWorktreeStatusCounts: Equatable {
  /// `??` 以外の行数（tracked の変更・staged を含む）。
  let modified: Int
  /// `??` で始まる行数。`--untracked-files=normal` のエントリ数なので未追跡ディレクトリは 1 と数える。
  let untracked: Int

  var isClean: Bool { modified == 0 && untracked == 0 }
}

/// worktree で停止している git 操作。gitdir 直下の管理エントリからどれか 1 つに一意に決まる。
enum GitWorktreeOperation: Equatable {
  case rebase, merge, cherryPick, bisect

  /// 表示に使う git 自身の語（訳さない）。
  var name: String {
    switch self {
    case .rebase: return "rebase"
    case .merge: return "merge"
    case .cherryPick: return "cherry-pick"
    case .bisect: return "bisect"
    }
  }
}

/// 進行中操作の検知結果。`unknown` は gitdir を読めなかった＝**判定できなかった事実を「安全」と読まない**
/// ための第 3 の値（`nil` の `containment` と同じ流儀）。
enum GitWorktreeOperationState: Equatable {
  case none
  case inProgress(GitWorktreeOperation)
  case unknown
}

/// worktree の gitdir を読んで、停止している git 操作を検知する。**subprocess を 1 本も増やさない**——
/// `git worktree list --porcelain` は gitdir を出さないが、リンク worktree の `<path>/.git` が
/// `gitdir: <パス>` の 1 行を持つファイル（本体 worktree ではディレクトリ）であることは git 自身の
/// レイアウト契約なので、これを読めば同じ事実がファイル 1 本の読み取りで決まる。
enum GitWorktreeOperationProbe {
  /// 判定に使う管理エントリ（先に一致したものを採る）。
  private static let markers: [(entry: String, operation: GitWorktreeOperation)] = [
    ("rebase-merge", .rebase), ("rebase-apply", .rebase), ("MERGE_HEAD", .merge),
    ("CHERRY_PICK_HEAD", .cherryPick), ("BISECT_LOG", .bisect),
  ]

  /// 停止している操作。無ければ `.none`、gitdir を読めなければ `.unknown`。
  static func detect(worktreeAt path: String) -> GitWorktreeOperationState {
    guard let gitDir = gitDir(worktreeAt: path) else { return .unknown }
    let manager = FileManager.default
    for marker in markers
    where manager.fileExists(atPath: (gitDir as NSString).appendingPathComponent(marker.entry)) {
      return .inProgress(marker.operation)
    }
    return .none
  }

  /// worktree の gitdir。`.git` がディレクトリならそれ自身（本体 worktree）、ファイルなら `gitdir:` 行の
  /// 指す先（リンク worktree）。相対パスは worktree 基準で解決する。読めなければ nil。
  static func gitDir(worktreeAt path: String) -> String? {
    let dotGit = (path as NSString).appendingPathComponent(".git")
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) else {
      return nil
    }
    if isDirectory.boolValue { return dotGit }
    guard let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
      let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") })
    else { return nil }
    let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
    guard !target.isEmpty else { return nil }
    guard !target.hasPrefix("/") else { return (target as NSString).standardizingPath }
    return ((path as NSString).appendingPathComponent(target) as NSString).standardizingPath
  }
}

/// 削除が拒否された事実。`log` は行のサブラインに出す git の生 stderr を 1 行へ畳んだもの
/// （打ち切りでは空になりうるので `timedOut` を添え、文言の差し替えは UI 言語を持つ側が決める）。
struct GitWorktreeCleanFailure: Equatable {
  let log: String
  let timedOut: Bool
}

extension GitRepo {
  /// 作業ツリーが clean か（`status --porcelain` が空）。件数 API の薄いラッパで、
  /// **確認できなかったら clean でない側に倒す**契約はここが持つ。
  ///
  /// この bool は `--force` 削除を止める唯一の関門である。
  func worktreeIsClean(
    at path: String, isolated: Bool = false, completion: @escaping (Bool) -> Void
  ) {
    worktreeStatusCounts(at: path, isolated: isolated) { completion($0?.isClean ?? false) }
  }

  /// `status --porcelain` の件数。判定できなかったら nil。
  ///
  /// **status の見え方を左右するユーザー設定をすべて引数で上書きして事実を固定する**。
  /// `--ignore-submodules=none` は `diff.ignoreSubmodules` を、`--untracked-files=normal` は
  /// `status.showUntrackedFiles`（巨大リポの高速化として広く使われ、`no` だと未追跡ファイルだけの
  /// worktree が空出力＝clean に見える）を封じる。`--no-optional-locks` は観測でユーザーが作業中の
  /// worktree の index を書き換えないため。
  ///
  /// `isolated` は呼び出し側が決める: 分類のプローブは共有 read-write lock の外へ逃がして直後の
  /// Enter(barrier) を待たせないが、削除直前のゲートは lock の中に置き実行と同じレーンで直列させる。
  func worktreeStatusCounts(
    at path: String, isolated: Bool = false,
    completion: @escaping (GitWorktreeStatusCounts?) -> Void
  ) {
    // 実体が消えた worktree でも起動できるよう、cwd は main worktree に置いて `-C` で対象を指す。
    GitRunner.shared.run(
      [
        "--no-optional-locks", "-C", path, "status", "--porcelain",
        "--untracked-files=normal", "--ignore-submodules=none",
      ], cwd: root, lane: isolated ? .independent : .read
    ) { output in
      guard output.isSuccess else {
        completion(nil)
        return
      }
      let lines = output.stdoutText.split(separator: "\n").filter {
        !$0.trimmingCharacters(in: .whitespaces).isEmpty
      }
      let untracked = lines.filter { $0.hasPrefix("??") }.count
      completion(
        GitWorktreeStatusCounts(modified: lines.count - untracked, untracked: untracked))
    }
  }

  /// worktree を削除する。成功なら nil、失敗なら実質的な失敗理由。
  ///
  /// **`--force` は検証済みの前提のもとでの唯一正しい呼び方であって、未知の拒否を握り潰す逃げではない。**
  /// submodule を初期化した worktree を、git は作業ツリーが完全に clean でも
  /// `git worktree remove` で消させない（`submodule deinit` して実体を空にしても拒否は変わらない）。
  /// Orbe 自身のリポジトリも submodule を持つため、`--force` 以外の道が無い。
  /// `--force` 1 個が外すのは「dirty」と「submodule」の 2 つ。dirty は呼び出し側が削除の直前に
  /// status で検証済み。submodule は作業コピーと**その worktree 固有の submodule gitdir
  /// （`<common>/worktrees/<id>/modules/…`。common dir 直下ではなく、alternates も持たない独立の
  /// オブジェクトストア）ごと消える**——safe 行は super のブランチのコミットが世界に残ること
  /// （`refs/remotes/origin/*` からの到達性、または比較先への patch 等価）を通っており、
  /// その前提のもとで submodule 側にだけ未 push が残る状態は成立しない。
  /// locked は `-f` 1 個では外れないため、locked な worktree はそもそも安全確認を通さない。
  func removeWorktree(path: String, completion: @escaping (GitWorktreeCleanFailure?) -> Void) {
    GitRunner.shared.run(
      ["worktree", "remove", "--force", path], cwd: root, lane: .exclusive
    ) { output in
      completion(GitRepo.cleanFailure(output))
    }
  }

  /// ローカルブランチを、`expectedOid` の先端であることを条件に削除する。
  /// 成功なら nil、失敗なら実質的な失敗理由。
  ///
  /// `branch -D` ではなく `update-ref -d <ref> <oid>` を呼ぶ。`-D` は無条件削除なので、判定した時点の
  /// 先端と削除する時点の先端がずれていても気づけない——**worktree を消して失うのは作業コピーだが、
  /// ブランチを消して失うのはコミットそのもの**（reflog も同時に消え、通常は `fsck --lost-found` しか
  /// 残らない）で、判定は実行（⌘⏎）の瞬間に確定した依頼が運ぶ。`update-ref` の第 3 引数は
  /// 「この OID のときだけ」という compare-and-swap で、ref ロックの中で比較と削除が起きるため
  /// 読み直して比べる 2 段と違い窓が無い。分類後に外部からコミットが載ったブランチは
  /// `cannot lock ref … but expected …` で拒否され、失敗行として集約される。
  ///
  /// `branch -d` に頼らない点は変わらない: safe 行は `branchContainment` の証明
  /// （`refs/remotes/origin/*` からの到達性、または比較先への patch 等価）を通っており、これは `-d`（upstream か
  /// HEAD への到達性のみ）より厳密に強い——`-d` は squash も rebase も統合先が既定ブランチでない
  /// マージも取りこぼすので、先に試しても safe 行ですら通らない。caution 行から
  /// 呼ばれる場合は、ユーザーが行ごとに `worktree + ブランチ` を選ぶ行為が安全確認の上書きになっている。
  func deleteBranch(
    name: String, expectedOid: String, completion: @escaping (GitWorktreeCleanFailure?) -> Void
  ) {
    GitRunner.shared.run(
      ["update-ref", "-d", "refs/heads/\(name)", expectedOid], cwd: root, lane: .exclusive
    ) { output in
      completion(GitRepo.cleanFailure(output))
    }
  }

  /// 失敗した削除の生ログ。**1 行に畳む**——行のサブラインは 1 行・末尾省略なので、改行の入った
  /// stderr をそのまま渡すと 2 行目以降が読めないまま高さだけが揺れる。
  private static func cleanFailure(_ output: GitRunner.Output) -> GitWorktreeCleanFailure? {
    guard !output.isSuccess else { return nil }
    let log =
      output.stderrText
      .split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" })
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    return GitWorktreeCleanFailure(log: log, timedOut: output.timedOut)
  }
}
