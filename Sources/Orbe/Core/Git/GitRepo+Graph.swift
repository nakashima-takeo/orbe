import Foundation

// MARK: - コミットグラフ

/// コミットの列（トポロジー順）と、続きがあるか。
struct GitCommitGraph: Equatable {
  let commits: [GitGraphCommit]
  /// 続きがある（`skip` を読んだ件数だけ進めて読める）。
  let hasMore: Bool
}

struct GitGraphCommit: Equatable {
  let oid: String
  let parents: [String]
  let subject: String
  /// 指しているローカルブランチ（`refs/heads/` を除いた名前）。
  let localBranches: [String]
  /// 指している remote 追跡ブランチ（`refs/remotes/` を除いた名前。`<remote>/HEAD` は含まない）。
  let remoteBranches: [String]
  /// どれかの remote 追跡ブランチから届く。
  let isPushed: Bool
}

extension GitRepo {
  /// `refs` から届くコミットを、新しい側から `skip` 件飛ばして最大 `limit` 件。`refs` が nil なら HEAD と、在れば
  /// upstream。読めなければ nil。
  ///
  /// 書式を明示し、署名の表示・色・出力の文字コードを封じる（ユーザーの `log.showSignature` 等で出力が変わらない）。
  /// 指しているブランチ名は装飾の文字列（`HEAD -> `・`tag: ` が混ざり、名前に `,` が入りうる）を割らずに ref から別に引く。push 済みかは、表示する
  /// 分から remote 追跡ブランチに届かない分を引くので、手間は表示する分と未 push の分に比例する（履歴全体を歩かない）。
  func commitGraph(
    refs: [String]? = nil, skip: Int = 0, limit: Int,
    completion: @escaping (GitCommitGraph?) -> Void
  ) {
    guard let refs else {
      runner.run(["rev-parse", "--symbolic-full-name", "@{upstream}"], cwd: root) { output in
        let upstream = output.stdoutText.trimmingCharacters(in: .newlines)
        let refs = ["HEAD"] + (output.isSuccess && !upstream.isEmpty ? [upstream] : [])
        self.commitGraph(refs: refs, skip: skip, limit: limit, completion: completion)
      }
      return
    }
    runner.run(
      [
        "log", "--topo-order", "--no-color", "--no-show-signature", "--encoding=UTF-8", "-z",
        "--format=%H%x00%P%x00%s", "--skip=\(skip)", "--max-count=\(limit + 1)",
        "--ignore-missing", "--end-of-options",
      ] + refs + ["--"], cwd: root, transform: { $0.isSuccess ? Self.parseLog($0.stdout) : nil },
      completion: { listed in
        guard let listed else { return completion(nil) }
        self.decorate(listed, limit: limit, completion: completion)
      })
  }

  /// 読んだコミットに、指しているブランチと push 済みかを添える（続きの判定に 1 件多く読んである）。
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
            oid: $0.oid, parents: $0.parents, subject: $0.subject,
            localBranches: tips.local[$0.oid] ?? [], remoteBranches: tips.remote[$0.oid] ?? [],
            isPushed: !unpushed.contains($0.oid))
        }
        completion(GitCommitGraph(commits: commits, hasMore: listed.count > limit))
      }
    }
  }

  private struct LoggedCommit {
    let oid: String
    let parents: [String]
    let subject: String
  }

  /// `-z` と `%H%x00%P%x00%s`: 1 コミット 3 欄が NUL で続く。
  private static func parseLog(_ data: Data) -> [LoggedCommit] {
    let fields = data.split(separator: 0, omittingEmptySubsequences: false)
    return stride(from: 0, to: fields.count - 2, by: 3).map {
      LoggedCommit(
        oid: String(bytes: fields[$0], encoding: .utf8) ?? "",
        parents: (String(bytes: fields[$0 + 1], encoding: .utf8) ?? "").split(separator: " ")
          .map(String.init),
        subject: subject(fields[$0 + 2]))
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
        let fields = line.split(separator: " ")
        guard fields.count == 2 else { continue }
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

  /// `oids` のうち、どの remote 追跡ブランチからも届かないもの。remote 追跡ブランチが無ければ git を起こさず全部。
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
