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

/// ブランチ削除の安全判定の結論。「消して世界に残るか」を、証明の種類ごとに別のケースで語る
/// （0 という数値に「取り込み済み」を兼務させない——到達性の証明と patch 等価の証明はラベルが違う）。
enum GitBranchContainment: Equatable {
  /// 全コミットが `refs/remotes/origin/*` から到達可能（消してもコミットはそこに残る）。
  /// **origin に限るのは鮮度の保証範囲と揃えるため**——Orbe が prune するのは origin だけなので、
  /// 他 remote の tracking ref は remote 側で消えた後もローカルに残り続け、「世界に残る」の根拠にできない。
  /// `mergedIntoDefault` は既定ブランチが tip を含むか（ラベル「merged → \<default\>」を名乗れるか）で、
  /// 安全事実そのものには関わらない。
  case reachable(mergedIntoDefault: Bool)
  /// 既定ブランチに patch 等価で存在（cherry 2 段）。ラベルは「merged → \<default\>」。
  case patchEquivalent
  /// 未取り込み。`count` は失われうるコミット数（到達不能数と patch 非等価数の min）。
  case unmerged(count: Int)
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

  /// ブランチを消して「コミットが世界に残るか」の判定。判定できなければ nil（安全と読まない）。
  ///
  /// **3 段構え**。第0段は到達性——`rev-list --count <tip> --not --remotes=origin --` が 0 なら、
  /// 全コミットが `refs/remotes/origin/*` から到達可能で、worktree とローカルブランチを消しても
  /// コミットはそこに残る。比較先の推測なしに安全群の意味論（消して世界に残るか）を直接問えるので、
  /// 統合先が既定ブランチでないリポジトリ（git-flow の develop 統合等）でも成立する。
  /// squash/rebase マージは SHA が変わって到達性で見えないため、第1段（素の `git cherry`）・
  /// 第2段（累積差分のダングリングコミットで再 cherry）が既定ブランチとの patch 等価で拾う。
  ///
  /// **`--remotes` ではなく `--remotes=origin`。** 信頼する ref の集合は、Orbe が鮮度を保証する集合と
  /// 一致していなければならない。prune するのは `fetchPrune` の origin だけなので、fork や upstream の
  /// tracking ref は remote 側で消えた後も残り続ける。それを根拠にすると、`[gone]` で安全群に入った行が
  /// stale な ref だけを頼りにブランチごと消え、ユーザーが後で全 remote を prune した時点でコミットが
  /// 到達不能になる。origin に限れば「`[gone]` を作る prune」と「信頼する ref を掃除する prune」が
  /// 同一操作になり、その組み合わせが構造的に消える。
  ///
  /// **`--` でオプションを終端する。** `rev-list` は pathspec も取るので、リポジトリ直下のエントリと
  /// 同名のブランチ（`docs` 等）では `ambiguous argument` で落ちる。cwd は main worktree の `root`
  /// なので、終端しないとその worktree だけ第0段が常に失敗し、黙って旧経路へ退行する。
  ///
  /// **`branchOrCommit` は曖昧さの無い名前で渡す**——ブランチは `refs/heads/<branch>` の完全 ref、
  /// detached は oid。短縮名は refs/tags が refs/heads より**先に**解決されるため、同名タグが
  /// あるとタグの指すコミットを判定してしまう（全経路——第0段 rev-list・cherry・
  /// `rev-parse ^{tree}`・merge-base——が同じ名前を受けるので、入口の 1 点で塞ぐ）。
  ///
  /// **素の `git cherry` 単独では multi-commit squash を検出できない。** cherry はコミット 1 個ずつの
  /// patch-id を比べるので、複数コミットを 1 個に畳んだ squash マージでは畳んだ側の patch-id が元のどの
  /// コミットとも一致せず「未取り込み」と誤判定する。そこでブランチの累積差分を 1 個のダングリング
  /// コミットへ合成してから再度 cherry にかける。**2 段構えが要る**——レシピ単独では、既定ブランチの
  /// 厳密な祖先であるブランチ（＝完全に取り込み済み）に対して空パッチのダングリングコミットができ、
  /// 偽陽性で `+` を返す。
  ///
  /// `unmerged` の `count` は到達不能数と patch 非等価数の **min**——どちらも「真に失われる数」の
  /// 過大評価なので、min は厳密により良い過大評価（統合先が既定ブランチでないリポジトリで
  /// 「独自コミット +106」型の巨大数が実数へ縮む）。
  ///
  /// `isolated` は呼び出し側が決める（`worktreeIsClean` と同じ理由）。この判定は worktree 1 本あたり
  /// 最大 6 本の git を撒く（到達性 1 本＋merged 経路は is-ancestor 1 本／unmerged 経路は cherry 系
  /// 最大 5 本）ので、共有 read レーンに置くと直後の `addWorktree`(barrier) が全部の完了を待つ。
  func branchContainment(
    branchOrCommit: String, default defaultBranch: String, isolated: Bool = false,
    completion: @escaping (GitBranchContainment?) -> Void
  ) {
    let lane: GitRunner.Lane = isolated ? .independent : .read
    GitRunner.shared.run(
      ["rev-list", "--count", branchOrCommit, "--not", "--remotes=origin", "--"], cwd: root,
      lane: lane
    ) { output in
      // 第0段の失敗は nil に直結させない（到達性を諦めて従来の cherry 経路へ倒す）。
      let reachCount =
        output.isSuccess
        ? Int(output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
      if reachCount == 0 {
        // 安全事実（reachable）は証明済み。is-ancestor は「merged → <default>」を名乗れるかの
        // ラベルだけを決めるので、exit 1（非祖先）と異常失敗を区別せず汎用ラベル側へ倒してよい。
        GitRunner.shared.run(
          ["merge-base", "--is-ancestor", branchOrCommit, defaultBranch], cwd: self.root, lane: lane
        ) { ancestor in
          completion(.reachable(mergedIntoDefault: ancestor.isSuccess))
        }
        return
      }
      self.patchEquivalenceCheck(
        branchOrCommit, default: defaultBranch, reachCount: reachCount, isolated: isolated,
        completion: completion)
    }
  }

  /// 第1段（素の cherry）と第2段（squash 検出）。remote が 1 つも無いリポジトリ
  /// （到達不能数＝全履歴）でも、ローカル既定ブランチとの比較で従来どおり判定できる経路。
  private func patchEquivalenceCheck(
    _ branchOrCommit: String, default defaultBranch: String, reachCount: Int?, isolated: Bool,
    completion: @escaping (GitBranchContainment?) -> Void
  ) {
    GitRunner.shared.run(
      ["cherry", defaultBranch, branchOrCommit], cwd: root, lane: isolated ? .independent : .read
    ) { output in
      guard output.isSuccess else {
        completion(nil)
        return
      }
      let plus = output.stdoutText.split(separator: "\n").filter { $0.hasPrefix("+") }.count
      guard plus > 0 else {
        completion(.patchEquivalent)
        return
      }
      // 失われうる数は到達不能数と patch 非等価数の min（どちらも過大評価なので、より良い過大評価）。
      let count = reachCount.map { min($0, plus) } ?? plus
      self.squashMergedCheck(branchOrCommit, default: defaultBranch, isolated: isolated) { merged in
        completion(merged.map { $0 ? .patchEquivalent : .unmerged(count: count) })
      }
    }
  }

  /// ブランチの累積差分を合成したダングリングコミットで squash 取り込み済みかを見る。
  /// 判定できなければ nil。
  ///
  /// `commit-tree` は到達不可能なコミットオブジェクトを 1 個書くだけ（ref は触らず、いずれ gc で消える）。
  /// オブジェクトストアへの書き込みは git 自身が並行安全なので barrier に載せない。
  /// `-c user.name` / `-c user.email` は identity 自動推定が失敗する環境で `commit-tree` が落ちるのを
  /// 塞ぐためで、patch-id は内容だけから決まるため判定には影響しない。
  private func squashMergedCheck(
    _ branchOrCommit: String, default defaultBranch: String, isolated: Bool,
    completion: @escaping (Bool?) -> Void
  ) {
    GitRunner.shared.run(
      ["merge-base", defaultBranch, branchOrCommit], cwd: root,
      lane: isolated ? .independent : .read
    ) { base in
      guard base.isSuccess else {
        completion(nil)
        return
      }
      let mergeBase = base.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
      GitRunner.shared.run(
        ["rev-parse", "\(branchOrCommit)^{tree}"], cwd: self.root,
        lane: isolated ? .independent : .read
      ) { tree in
        guard tree.isSuccess else {
          completion(nil)
          return
        }
        let treeOid = tree.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        GitRunner.shared.run(
          [
            "-c", "user.name=orbe", "-c", "user.email=orbe@localhost",
            "commit-tree", treeOid, "-p", mergeBase, "-m", "_",
          ], cwd: self.root, lane: isolated ? .independent : .read
        ) { synthesized in
          guard synthesized.isSuccess else {
            completion(nil)
            return
          }
          let oid = synthesized.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
          GitRunner.shared.run(
            ["cherry", defaultBranch, oid], cwd: self.root, lane: isolated ? .independent : .read
          ) { cherry in
            guard cherry.isSuccess else {
              completion(nil)
              return
            }
            completion(cherry.stdoutText.hasPrefix("-"))
          }
        }
      }
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
  /// （`refs/remotes/origin/*` からの到達性、または既定ブランチへの patch 等価）を通っており、
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
  /// 残らない）で、判定は clean 画面を開いた時点で凍結される。`update-ref` の第 3 引数は
  /// 「この OID のときだけ」という compare-and-swap で、ref ロックの中で比較と削除が起きるため
  /// 読み直して比べる 2 段と違い窓が無い。分類後に外部からコミットが載ったブランチは
  /// `cannot lock ref … but expected …` で拒否され、失敗行として集約される。
  ///
  /// `branch -d` に頼らない点は変わらない: safe 行は `branchContainment` の証明
  /// （`refs/remotes/origin/*` からの到達性、または既定ブランチへの patch 等価）を通っており、これは `-d`（upstream か
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
