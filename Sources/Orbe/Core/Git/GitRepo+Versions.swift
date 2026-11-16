import Foundation

// MARK: - 版の本文

/// どの版か。
enum GitRevision: Hashable {
  case head
  case index
  case commit(String)
}

/// ある版での、あるパスの本文。
enum GitVersionText: Equatable {
  /// 作業ツリーに出したときの姿（baseline と同じ底）。
  case present(Data)
  /// サブモジュール（gitlink が指すコミット）。本文は取らない。
  case submodule(String)
  /// その版に無い（初回コミット前の HEAD を含む）。
  case absent
  /// 取れなかった（git の失敗・手元に無いコミット）。
  case failed
}

extension GitRepo {
  /// あるパスの、ある版での本文（サブモジュールなら gitlink が指すコミット）。在るかと種類を先に確かめてから、baseline と
  /// 同じ取り方（`blob(oid:relativePath:)`。smudge と eol を通し、textconv・外部 diff は通らない）で本文を取る——「その版に
  /// 無い」を git の失敗と取り違えないため。
  ///
  /// HEAD と index の版は、在るかを `cat-file --batch-check` で問う（サブモジュールは「無い」と答える。HEAD と index の
  /// サブモジュールは、呼び出し側がツリーと index の項目で先に見分ける）。コミットの版は、そのコミットのツリーの項目
  /// （`treeEntries`）で種類を読む——gitlink の答え方が git の版で変わる `cat-file` に頼らない。手元に無いコミットは
  /// 「取れなかった」にする（無いコミットのパスを「その版に無い」と答えると、呼び出し側がそのコミットを取りに行く合図を
  /// 失う）。
  func version(
    of relativePath: String, at revision: GitRevision,
    completion: @escaping (GitVersionText) -> Void
  ) {
    let name: String
    switch revision {
    case .head: name = "HEAD:" + relativePath
    case .index: name = ":0:" + relativePath
    case .commit(let commit):
      return treeEntries(at: commit, relativePaths: [relativePath]) { [self] entries in
        guard let entries else { return completion(.failed) }
        switch entries.values.first {
        case .file(let oid)?: present(oid: oid, relativePath: relativePath, completion: completion)
        case .submodule(let commit)?: completion(.submodule(commit))
        case nil: completion(.absent)
        }
      }
    }
    runner.run(
      ["cat-file", "-z", "--batch-check=%(objectname) %(objecttype)"], cwd: root,
      stdin: Data((name + "\0").utf8)
    ) { [self] output in
      guard output.isSuccess else { return completion(.failed) }
      // 在れば `<oid> <type>`、無ければ `<名前> missing`。名前は `:` を含むので前者と取り違えない。
      let fields = output.stdoutText.trimmingCharacters(in: .newlines).split(separator: " ")
      guard fields.count == 2, fields[0].allSatisfy(\.isHexDigit) else {
        return completion(fields.last == "missing" ? .absent : .failed)
      }
      guard fields[1] == "blob" else { return completion(.absent) }
      present(oid: String(fields[0]), relativePath: relativePath, completion: completion)
    }
  }

  /// blob `oid` を、パス `relativePath` の本文として取る。
  private func present(
    oid: String, relativePath: String, completion: @escaping (GitVersionText) -> Void
  ) {
    blob(oid: oid, relativePath: relativePath) { data in
      completion(data.map(GitVersionText.present) ?? .failed)
    }
  }
}
