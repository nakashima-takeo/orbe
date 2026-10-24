import Foundation

// MARK: - コミットグラフ

/// コミットの列（トポロジー順）と、その先があるか。
struct GitCommitGraph: Equatable {
  let commits: [GitGraphCommit]
  /// `limit` より先にもコミットがある（件数を増やして頭から読み直せば出る）。
  let hasMore: Bool
}

struct GitGraphCommit: Equatable {
  let oid: String
  let subject: String
  /// 指しているローカルブランチ（`refs/heads/` を除いた名前）。
  let localBranches: [String]
  /// 指している remote 追跡ブランチ（`refs/remotes/` を除いた名前。`<remote>/HEAD` は含まない）。
  let remoteBranches: [String]
  /// どれかの remote 追跡ブランチから届く。
  let isPushed: Bool
}

extension GitRepo {
  /// HEAD と、在れば upstream から届くコミットを、新しい側から最大 `limit` 件。読めなければ nil。
  ///
  /// 書式を明示し、署名の表示・色・出力の文字コードを封じる（ユーザーの `log.showSignature` 等で出力が変わらない）。
  /// 指しているブランチ名は装飾の文字列（`HEAD -> `・`tag: ` が混ざり、名前に `,` が入りうる）を割らずに ref から別に
  /// 引く。push 済みかは、表示する分から remote 追跡ブランチに届かない分を引くので、その手間は表示する分と未 push の分に
  /// 比例する（履歴全体を歩かない）。
  func commitGraph(limit: Int, completion: @escaping (GitCommitGraph?) -> Void) {
    runner.run(["rev-parse", "--symbolic-full-name", "@{upstream}"], cwd: root) { output in
      let upstream = output.stdoutText.trimmingCharacters(in: .newlines)
      let refs = ["HEAD"] + (output.isSuccess && !upstream.isEmpty ? [upstream] : [])
      self.runner.run(
        [
          "log", "--topo-order", "--no-color", "--no-show-signature", "--encoding=UTF-8", "-z",
          "--format=%H%x00%s", "--max-count=\(limit + 1)", "--ignore-missing",
          "--end-of-options",
        ] + refs + ["--"], cwd: self.root,
        transform: { $0.isSuccess ? Self.parseLog($0.stdout) : nil },
        completion: { listed in
          guard let listed else { return completion(nil) }
          self.decorate(listed, limit: limit, completion: completion)
        })
    }
  }

  /// HEAD のコミットと、それが push 済みか（`isPushed`）。グラフの口を通らないので、グラフの並べ替えの手間を払わない。
  /// 初回コミット前・読めなければ nil。
  func headPush(completion: @escaping ((commit: String, isPushed: Bool)?) -> Void) {
    runner.run(["rev-parse", "-q", "--verify", "HEAD^{commit}"], cwd: root) { parsed in
      let commit = parsed.stdoutText.trimmingCharacters(in: .newlines)
      guard parsed.isSuccess, !commit.isEmpty else { return completion(nil) }
      self.isPushed(commit, handle: GitRunner.Handle()) { pushed in
        completion((try? pushed.get()).map { (commit, $0) })
      }
    }
  }

  /// `revision` が push 済み（どれかの remote 追跡ブランチから届く）か。グラフの push 済み（`unpushed`）と同じ定義。手間は
  /// `revision` と remote 追跡ブランチの分かれ目より新しい分（未 push の分と、remote 側で先に進んだ分）に比例する。
  func isPushed(
    _ revision: String, handle: GitRunner.Handle,
    completion: @escaping (Result<Bool, GitWriteFailure>) -> Void
  ) {
    runner.run(
      ["rev-list", "-n", "1", revision, "--not", "--remotes", "--"], cwd: root, handle: handle
    ) { listed in
      if let failure = GitWriteFailure.of(listed) { return completion(.failure(failure)) }
      completion(.success(listed.stdoutText.isEmpty))
    }
  }

  /// 読んだコミットに、指しているブランチと push 済みかを添える（その先があるかの判定に 1 件多く読んである）。
  private func decorate(
    _ listed: [LoggedCommit], limit: Int, completion: @escaping (GitCommitGraph?) -> Void
  ) {
    branchTips { tips in
      guard let tips else { return completion(nil) }
      let shown = Array(listed.prefix(limit))
      self.unpushed(shown.map(\.oid), hasRemotes: !tips.remote.isEmpty) { unpushed in
        guard let unpushed else { return completion(nil) }
        let commits = shown.map {
          GitGraphCommit(
            oid: $0.oid, subject: $0.subject,
            localBranches: tips.local[$0.oid] ?? [], remoteBranches: tips.remote[$0.oid] ?? [],
            isPushed: !unpushed.contains($0.oid))
        }
        completion(GitCommitGraph(commits: commits, hasMore: listed.count > limit))
      }
    }
  }

  private struct LoggedCommit {
    let oid: String
    let subject: String
  }

  /// `-z` と `%H%x00%s`: 1 コミット 2 欄が NUL で続く。
  private static func parseLog(_ data: Data) -> [LoggedCommit] {
    let fields = data.split(separator: 0, omittingEmptySubsequences: false)
    return stride(from: 0, to: fields.count - 1, by: 2).map {
      LoggedCommit(
        oid: String(bytes: fields[$0], encoding: .utf8) ?? "", subject: subject(fields[$0 + 1]))
    }
  }

  /// 題は不正なバイトを U+FFFD へ落として読む。encoding ヘッダの無い非 UTF-8 の題（古い git・他の VCS から取り込んだ
  /// 履歴）は `--encoding=UTF-8` でも変換されずに出るので、厳密に読むと無題になる。
  private static func subject(_ bytes: Data) -> String {
    // swiftlint:disable:next optional_data_string_conversion
    String(decoding: bytes, as: UTF8.self)
  }

  /// コミット → それを指すローカル / remote 追跡ブランチの名前。symref（`origin/HEAD`）は除く。
  private func branchTips(
    completion: @escaping ((local: [String: [String]], remote: [String: [String]])?) -> Void
  ) {
    runner.run(
      [
        "for-each-ref", "--format=%(objectname) %(refname) %(symref)", "refs/heads", "refs/remotes",
      ], cwd: root
    ) { output in
      guard output.isSuccess else { return completion(nil) }
      var local: [String: [String]] = [:]
      var remote: [String: [String]] = [:]
      for line in output.stdoutText.split(separator: "\n") {
        let fields = line.split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 3, fields[2].isEmpty else { continue }
        let oid = String(fields[0])
        let ref = fields[1]
        if ref.hasPrefix("refs/heads/") {
          local[oid, default: []].append(String(ref.dropFirst("refs/heads/".count)))
        } else if ref.hasPrefix("refs/remotes/") {
          remote[oid, default: []].append(String(ref.dropFirst("refs/remotes/".count)))
        }
      }
      completion((local, remote))
    }
  }

  /// remote 追跡 ref（`refs/remotes` の下の ref 名 → 指すオブジェクト）。読めなければ nil。値で読むので、pack-refs（値は
  /// 変わらない）では変わらず、ref の形式（files・reftable）に依らない。
  func remoteTrackingRefs(completion: @escaping ([String: String]?) -> Void) {
    runner.run(
      ["for-each-ref", "--format=%(refname)%00%(objectname)", "refs/remotes"], cwd: root
    ) { output in
      guard output.isSuccess else { return completion(nil) }
      var refs: [String: String] = [:]
      for line in output.stdoutText.split(separator: "\n") {
        let fields = line.split(separator: "\0", omittingEmptySubsequences: false)
        if fields.count == 2 { refs[String(fields[0])] = String(fields[1]) }
      }
      completion(refs)
    }
  }

  /// `oids` から届くコミットのうち、どの remote 追跡ブランチからも届かないもの。remote 追跡ブランチが無ければ git を起こさず全部。
  private func unpushed(
    _ oids: [String], hasRemotes: Bool, completion: @escaping (Set<String>?) -> Void
  ) {
    guard hasRemotes, !oids.isEmpty else { return completion(Set(oids)) }
    runner.run(
      ["rev-list", "--stdin", "--not", "--remotes"], cwd: root,
      stdin: Data(oids.map { $0 + "\n" }.joined().utf8)
    ) { output in
      completion(
        output.isSuccess ? Set(output.stdoutText.split(separator: "\n").map(String.init)) : nil)
    }
  }
}
