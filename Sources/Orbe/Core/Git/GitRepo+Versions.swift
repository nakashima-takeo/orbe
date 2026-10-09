import Foundation

// MARK: - 版の本文

/// どの版か。
enum GitRevision: Equatable {
  case head
  case index
  case commit(String)
}

/// ある版での、あるパスの本文。
enum GitVersionText: Equatable {
  /// 作業ツリーに出したときの姿（baseline と同じ底）。
  case present(Data)
  /// その版に無い（初回コミット前の HEAD を含む）。
  case absent
  /// 取れなかった（git の失敗・手元に無いコミット）。
  case failed
}

extension GitRepo {
  /// あるパスの、ある版での本文。在るかを先に確かめてから、baseline と同じ取り方（`blob(oid:relativePath:)`。smudge と
  /// eol を通し、textconv・外部 diff は通らない）で本文を取る——「その版に無い」を git の失敗と取り違えないため。
  /// コミットの版はコミット自体が手元に在るかも同じ問い合わせで確かめ、無ければ「取れなかった」にする（無いコミットの
  /// パスを「その版に無い」と答えると、呼び出し側がそのコミットを取りに行く合図を失う）。
  func version(
    of relativePath: String, at revision: GitRevision,
    completion: @escaping (GitVersionText) -> Void
  ) {
    let names: [String]
    switch revision {
    case .head: names = ["HEAD:" + relativePath]
    case .index: names = [":0:" + relativePath]
    case .commit(let commit): names = [commit + "^{commit}", commit + ":" + relativePath]
    }
    runner.run(
      ["cat-file", "-z", "--batch-check=%(objectname) %(objecttype)"], cwd: root,
      stdin: Data(names.map { $0 + "\0" }.joined().utf8)
    ) { output in
      guard output.isSuccess else { return completion(.failed) }
      // 1 問 1 行。在れば `<oid> <type>`、無ければ `<名前> missing`。名前は `:` を含むので前者と取り違えない。
      // コミットを確かめる行は呼び出し側の ID だけを含み、改行を持たない。パスの行は最後の 1 行（パスは改行を含みうる）。
      var answer = output.stdoutText.trimmingCharacters(in: .newlines)
      if names.count == 2 {
        let lines = answer.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard lines.count == 2, lines[0].hasSuffix(" commit") else { return completion(.failed) }
        answer = String(lines[1])
      }
      let fields = answer.split(separator: " ")
      guard fields.count == 2, fields[0].allSatisfy(\.isHexDigit) else {
        return completion(fields.last == "missing" ? .absent : .failed)
      }
      guard fields[1] == "blob" else { return completion(.absent) }
      self.blob(oid: String(fields[0]), relativePath: relativePath) { data in
        completion(data.map(GitVersionText.present) ?? .failed)
      }
    }
  }
}
