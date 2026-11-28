import Foundation

// MARK: - コミットの間の関係と remote 追跡 ref の値

/// 2 つのコミットの、それぞれにしか無いコミットの数。
struct GitCommitCounts: Equatable {
  /// 比べる側にしか無い数（先行）。
  let ahead: Int
  /// 比べる相手にしか無い数（遅れ）。
  let behind: Int
}

/// 2 つのコミットの間の 1 つのファイルの diff の区間（変更とその前後の文脈）の列。区間ごとに、古い側と新しい側の、その側の
/// 版の行（1 始まり）の半開区間を、前から順に持つ（行数 0 の側は空の区間）。
struct GitDiffHunkLines: Equatable {
  struct Hunk: Equatable {
    let old: Range<Int>
    let new: Range<Int>
  }

  var hunks: [Hunk]
}

extension GitDiffHunkLines {
  /// patch の区間の頭（`@@ -<始まり>[,<行数>] +<始まり>[,<行数>] @@`）から読む。行数を省いた側は 1 行。
  init(patch: Data) {
    self.init(hunks: [])
    for line in patch.split(separator: UInt8(ascii: "\n")) where line.starts(with: Self.header) {
      let fields = line.dropFirst(3).split(separator: UInt8(ascii: " "), maxSplits: 2)
      guard fields.count >= 2, let removed = Self.span(fields[0]), let added = Self.span(fields[1])
      else { continue }
      hunks.append(Hunk(old: Self.lines(removed), new: Self.lines(added)))
    }
  }

  private static let header = Array("@@ -".utf8)

  /// `-12,7` か `+12` の 1 欄の、始まりの行と行数。読めなければ nil。
  private static func span(_ field: Data.SubSequence) -> (start: Int, count: Int)? {
    let parts = field.dropFirst().split(
      separator: UInt8(ascii: ","), maxSplits: 1, omittingEmptySubsequences: false)
    let numbers = parts.compactMap { String(bytes: $0, encoding: .utf8).flatMap { Int($0) } }
    guard numbers.count == parts.count, let start = numbers.first else { return nil }
    return (start, numbers.count == 2 ? numbers[1] : 1)
  }

  private static func lines(_ span: (start: Int, count: Int)) -> Range<Int> {
    span.start..<(span.start + span.count)
  }
}

/// ブランチの push 先の remote 追跡 ref。
enum GitPushTracking: Equatable {
  /// push 先が無い（push 先の設定も origin も無い）。
  case noDestination
  /// push 先の remote 追跡 ref の名前（`refs/remotes/<remote>/<ブランチ名>`）。手元にその ref が在るとは限らない。
  case ref(String)
}

/// 2 つのコミットのマージベースを求めた結果。
enum GitMergeBase: Equatable {
  case found(String)
  /// どちらかのコミットが手元に無い（取ってくれば求まりうる）。
  case missingCommit
  /// 共通の祖先が無い。
  case unrelated
  /// 手元の履歴が浅く（shallow clone）、共通の祖先までたどれない（両端のコミットを取ってきても求まらない）。浅い
  /// リポジトリでは、本当に共通の祖先が無いこととは分けられない。
  case shallow
  /// 読めなかった（git の失敗）。
  case failed
}

extension GitRepo {
  /// `a` と `b` のマージベース（`git merge-base`）。求まらなければ、その理由。git は共通の祖先が無いことを終了コード 1 で
  /// 言い、コミットが無いことを分けて言わないので、失敗したときだけ 2 つのコミットが手元に在るかを確かめる。浅いリポジトリ
  /// では、浅い境界でたどれないことも終了コード 1 で言うので、浅ければ共通の祖先が無いとは言わない。
  func mergeBase(_ a: String, _ b: String, completion: @escaping (GitMergeBase) -> Void) {
    runner.run(["merge-base", "--end-of-options", a, b], cwd: root) { output in
      let base = output.stdoutText.trimmingCharacters(in: .newlines)
      if output.isSuccess, !base.isEmpty { return completion(.found(base)) }
      if output.ending == .completed, output.status == 1 {
        return completion(self.isShallow ? .shallow : .unrelated)
      }
      self.runner.run(
        ["cat-file", "--batch-check"], cwd: self.root,
        stdin: Data([a, b].map { $0 + "^{commit}\n" }.joined().utf8)
      ) { checked in
        let lines = checked.stdoutText.split(separator: "\n")
        guard checked.isSuccess, lines.count == 2 else { return completion(.failed) }
        completion(lines.contains { $0.hasSuffix(" missing") } ? .missingCommit : .failed)
      }
    }
  }

  /// 浅いリポジトリか（共有 git dir に `shallow` があり、境界が 1 つ以上載る）。
  var isShallow: Bool {
    let shallow = (commonDir as NSString).appendingPathComponent("shallow")
    guard let text = try? String(contentsOfFile: shallow, encoding: .utf8) else { return false }
    return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// `base` から `head` の間の rename（新しいパス → 元のパス）。読めなければ nil。
  ///
  /// plumbing コマンドの `diff-tree` で読み、rename の検出は明示して有効にする（利用者の `diff.renames` に依らない）。外部 diff・
  /// textconv・色も無効にする。パスは NUL 区切りで、クォートされない。
  func renames(
    from base: String, to head: String, completion: @escaping ([String: String]?) -> Void
  ) {
    runner.run(
      [
        "diff-tree", "-r", "-z", "--no-ext-diff", "--no-textconv", "--no-color", "-M",
        "--diff-filter=R", "--name-status", "--end-of-options", base, head, "--",
      ], cwd: root,
      transform: { $0.isSuccess ? Self.parseRenames($0.stdout) : nil }, completion: completion)
  }

  /// `R<類似度>`・元のパス・新しいパスの 3 欄が NUL で続く。
  private static func parseRenames(_ data: Data) -> [String: String]? {
    let fields = data.split(separator: 0, omittingEmptySubsequences: false).dropLast()
    guard fields.count.isMultiple(of: 3) else { return nil }
    var renames: [String: String] = [:]
    for index in stride(from: fields.startIndex, to: fields.endIndex, by: 3) {
      guard fields[index].first == UInt8(ascii: "R"),
        let original = String(bytes: fields[index + 1], encoding: .utf8),
        let renamed = String(bytes: fields[index + 2], encoding: .utf8)
      else { return nil }
      renames[renamed] = original
    }
    return renames
  }

  /// `base` から `head` の間の、ファイル `path`（`originalPath` は rename の元のパス）の diff の区間が覆う行。読めなければ nil。
  ///
  /// 区間の形は GitHub の PR の diff に合わせて引数で決め、GitHub から見えない手元の値（設定・属性・環境変数）に依らせない
  /// ——前後 3 行の文脈・既定のアルゴリズム（myers）と `--indent-heuristic`・区間どうしをつなげない・外部 diff と textconv と色を
  /// 使わない・どのファイルもテキストとして比べる（`--text`。属性でバイナリ扱いにされても区間を出す。属性の出どころは作業
  /// ツリー・`info/attributes`・`core.attributesFile`・システムにもあり、比べるコミットの木だけに絞れないため）・
  /// `GIT_DIFF_OPTS` を効かせない。明示したアルゴリズムは、属性の diff ドライバーが決めるアルゴリズムにも勝つ。rename の検出は
  /// 明示して有効にする。パスは pathspec として解釈させない。
  func hunkLines(
    from base: String, to head: String, path: String, originalPath: String?,
    completion: @escaping (GitDiffHunkLines?) -> Void
  ) {
    let paths = [originalPath, path].compactMap { $0 }
    runner.run(
      [
        "diff-tree", "-p", "-r", "-M", "-U3", "--inter-hunk-context=0", "--diff-algorithm=myers",
        "--indent-heuristic", "--no-ext-diff", "--no-textconv", "--no-color", "--text",
        "--end-of-options", base, head, "--",
      ] + Set(paths).sorted().map { ":(literal)" + $0 }, cwd: root,
      environment: GitRunner.patchEnvironment,
      transform: { $0.isSuccess ? GitDiffHunkLines(patch: $0.stdout) : nil },
      completion: completion)
  }

  /// `revision` にしか無いコミットの数（先行）と、`other` にしか無いコミットの数（遅れ）。どちらかが手元に無い・読めなければ
  /// nil。
  func counts(
    _ revision: String, against other: String,
    completion: @escaping (GitCommitCounts?) -> Void
  ) {
    runner.run(
      ["rev-list", "--left-right", "--count", "--end-of-options", "\(revision)...\(other)", "--"],
      cwd: root
    ) { output in
      let fields = output.stdoutText.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
      guard output.isSuccess, fields.count == 2 else { return completion(nil) }
      completion(GitCommitCounts(ahead: fields[0], behind: fields[1]))
    }
  }

  /// ブランチの push 先の remote 追跡 ref の名前。push 先は push の解決（`pushRemote(ofBranch:handle:)`。設定が無ければ
  /// origin）と同じで、名前は fetch の既定の refspec が写す先（`refs/remotes/<remote>/<名前>`）で組む。その ref が手元に
  /// 在るとは限らない（single-branch のクローンは、ほかのブランチの追跡 ref を作らない）。読めなければ nil。
  func pushTracking(ofBranch name: String, completion: @escaping (GitPushTracking?) -> Void) {
    pushRemote(ofBranch: name, handle: GitRunner.Handle()) { remote in
      switch remote {
      case .failure: completion(nil)
      case .success(nil): completion(.noDestination)
      case .success(let remote?): completion(.ref("refs/remotes/\(remote)/\(name)"))
      }
    }
  }

  /// ref ごとの今の値（指すオブジェクト）。在る ref だけが入る。読めなければ nil。
  func refValues(_ refs: [String], completion: @escaping ([String: String]?) -> Void) {
    guard !refs.isEmpty else { return completion([:]) }
    let args = ["for-each-ref", "--format=%(refname)%00%(objectname)"] + refs
    runner.run(args, cwd: root) { output in
      guard output.isSuccess else { return completion(nil) }
      // パターンはその名前の下の階層にも当たるので、名指しした名前の行だけを採る。
      let wanted = Set(refs)
      var values: [String: String] = [:]
      for line in output.stdoutText.split(separator: "\n") {
        let fields = line.split(separator: "\0", omittingEmptySubsequences: false)
        if fields.count == 2, wanted.contains(String(fields[0])) {
          values[String(fields[0])] = String(fields[1])
        }
      }
      completion(values)
    }
  }
}
