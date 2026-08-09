import Foundation

/// worktree を作業ツリーの**中**に作るときの除外。repo 内配置を設定で選べる以上、`git status` が
/// worktree ぶんだけ汚れる（`git add .` が gitlink 化する）のを注意書きでなく自動化で塞ぐ。
///
/// 契約は「**Orbe が作ったものだけを除外する**」。判定は解決済みパスだけで行い、UI の行（プリセット／
/// カスタム）には副作用を紐付けない。書き先は `$GIT_COMMON_DIR/info/exclude`——git は `info/exclude` を
/// 常に common dir から読むため（per-worktree の exclude は存在しない）、ここ 1 箇所でどのチェックアウト
/// にも効く。ユーザーの `.gitignore` は書き換えない（コミット対象を勝手に増やさない）。
enum GitWorktreeExclude {
  /// `.git/info/exclude` へ入れる除外 1 件。
  struct Entry {
    /// 除外対象ディレクトリ（作業ツリー root からの相対）。
    let relativePath: String
    /// gitignore パターン（root 起点アンカー・ディレクトリ限定）。
    var pattern: String { "/\(relativePath)/" }
    /// `git check-ignore` に渡す形。対象は常にディレクトリなので末尾スラッシュで明示する——
    /// 付けないと、まだ実在しない対象が `foo/` 形（ディレクトリ限定＝最も慣用的な書き方）の
    /// 既存パターンに一致せず、「ユーザーが既に塞いでいる」を取りこぼす。
    var checkPath: String { "\(relativePath)/" }
  }

  /// 追記行の由来を人が読めるようにする見出し（この 1 行だけで `.git/info/exclude` の出所が分かる）。
  static let comment = "# Orbe: worktree location"

  /// 解決済み worktree パスが作業ツリー内に入るなら除外 1 件を返す（外なら nil＝何もしない）。
  ///
  /// - Parameter parentIsNew: worktree の親ディレクトリが**作成前に存在しなかった**か。
  ///   true のときだけ親（＝以後そこに増える worktree も 1 行で覆う容れ物）を対象にする。
  static func entry(worktreePath: String, worktreeRoot: String, parentIsNew: Bool) -> Entry? {
    // 作成先の解決と同じ純字句の正規化を通す（実在有無で答えが変わらない＝両者が同じ土俵に乗る）。
    let root = WorktreePathTemplate.lexicallyStandardized(worktreeRoot)
    let path = WorktreePathTemplate.lexicallyStandardized(worktreePath)
    guard path.hasPrefix(root + "/") else { return nil }
    let components = path.dropFirst(root.count + 1).split(separator: "/").map(String.init)
    guard !components.isEmpty else { return nil }
    let parent = components.dropLast()
    // 親をまとめて除外してよいのは、その親を Orbe がこれから容れ物として作るときだけ。既存の
    // ディレクトリを対象にすると、そこへ後から置かれたユーザーのファイルまで `git status` から
    // 消え（`git add` も拒否され）、しかも worktree を消しても行が残る。
    let target = parentIsNew && !parent.isEmpty ? Array(parent) : components
    let relativePath = target.joined(separator: "/")
    // gitignore は行指向。改行を含むパスは 1 行のパターンで表せないので除外を諦める（補助機能なので
    // nil へ畳む）——書けば行が割れ、意図より広い別パターンが残るうえ冪等判定も二度と成立しない。
    guard !relativePath.contains("\n") else { return nil }
    return Entry(relativePath: relativePath)
  }

  /// 共有 exclude へ冪等に追記する（同じパターンの行が既にあれば何もしない）。書けなければ false
  /// ——除外は補助であり worktree 作成の前提条件ではないので、呼び出し側は失敗しても続行する。
  @discardableResult
  static func append(_ entry: Entry, toCommonDir commonDir: String) -> Bool {
    let infoDir = (commonDir as NSString).appendingPathComponent("info")
    let file = (infoDir as NSString).appendingPathComponent("exclude")
    let manager = FileManager.default
    // 読めない既存を「不在」と同一視して全体を置換すると、git が解釈できている中身（非 UTF-8 でも
    // 有効）が消える。clone にも push にも乗らないローカル専用ファイルで復旧手段が無いため、
    // 読めない物には触らない。
    var existing = Data()
    if manager.fileExists(atPath: file) {
      guard let bytes = manager.contents(atPath: file) else { return false }
      existing = bytes
    }
    if contains(existing, line: entry.pattern) { return true }
    try? manager.createDirectory(atPath: infoDir, withIntermediateDirectories: true)
    let separator = existing.isEmpty || existing.last == 0x0A ? "" : "\n"
    let addition = Data((separator + "\(comment)\n\(entry.pattern)\n").utf8)
    // 全体置換でなく追記で書く——既存のバイト列をそのまま残し、symlink・ハードリンクの実体も保つ。
    guard let handle = FileHandle(forWritingAtPath: file) else {
      return (try? addition.write(to: URL(fileURLWithPath: file))) != nil
    }
    defer { try? handle.close() }
    guard (try? handle.seekToEnd()) != nil, (try? handle.write(contentsOf: addition)) != nil
    else { return false }
    return true
  }

  /// 行として完全一致するパターンが既にあるか（行頭・行末の空白は無視）。既存が非 UTF-8 でも
  /// 判定を諦めないよう、文字列でなくバイト列で見る。
  private static func contains(_ data: Data, line pattern: String) -> Bool {
    let target = Array(pattern.utf8)
    let blanks: Set<UInt8> = [0x20, 0x09, 0x0D]  // space・tab・CR（CRLF 混在でも当てる）
    return data.split(separator: 0x0A, omittingEmptySubsequences: false).contains { line in
      var bytes = Array(line)
      while let first = bytes.first, blanks.contains(first) { bytes.removeFirst() }
      while let last = bytes.last, blanks.contains(last) { bytes.removeLast() }
      return bytes == target
    }
  }
}

extension GitRepo {
  /// 作成できた worktree が作業ツリー内なら、共有 exclude へ除外を冪等に入れる。
  /// `entry` は worktree 作成の**前**に決めておく（作成後は親が実在してしまい、容れ物を Orbe が
  /// 作ったのかユーザーの既存ディレクトリなのかを判別できなくなる）。
  ///
  /// `worktreeRoot` はテンプレート解決に使った base（main worktree）を渡す——`self.root` はリンク
  /// worktree のこともあり、作成先の導出元と土俵が食い違うと包含判定が黙って外れる。
  /// 既に無視されている（ユーザーの `.gitignore` 由来を含む）なら触らない。
  /// 除外は補助なので、判定・追記の成否にかかわらず completion は必ず呼ぶ。
  func applyWorktreeExclude(
    _ entry: GitWorktreeExclude.Entry?, worktreeRoot: String, completion: @escaping () -> Void
  ) {
    guard let entry else {
      completion()
      return
    }
    // exit 0＝既に無視。exit 1（未無視）と判定不能はどちらも追記を試みる（追記自体が冪等）。
    runner.run(
      ["check-ignore", "-q", "--", entry.checkPath], cwd: worktreeRoot
    ) { [commonDir] output in
      if !output.isSuccess {
        GitWorktreeExclude.append(entry, toCommonDir: commonDir)
      }
      completion()
    }
  }
}
