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
  /// git が失敗した。
  case failed
}

extension GitRepo {
  /// あるパスの、ある版での本文。在るかを先に確かめてから、baseline と同じ取り方（`blob(oid:relativePath:)`。smudge と
  /// eol を通し、textconv・外部 diff は通らない）で本文を取る——「その版に無い」を git の失敗と取り違えないため。
  func version(
    of relativePath: String, at revision: GitRevision,
    completion: @escaping (GitVersionText) -> Void
  ) {
    let name: String
    switch revision {
    case .head: name = "HEAD:" + relativePath
    case .index: name = ":0:" + relativePath
    case .commit(let commit): name = commit + ":" + relativePath
    }
    runner.run(
      ["cat-file", "-z", "--batch-check=%(objectname) %(objecttype)"], cwd: root,
      stdin: Data((name + "\0").utf8)
    ) { output in
      guard output.isSuccess else { return completion(.failed) }
      // 在れば `<oid> <type>`、無ければ `<名前> missing`。名前は `:` を含むので前者と取り違えない。
      let fields = output.stdoutText.trimmingCharacters(in: .newlines).split(separator: " ")
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
