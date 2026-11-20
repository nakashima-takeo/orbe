import Foundation

// MARK: - 版の本文

/// あるコミットでの、あるパスの本文。
enum GitVersionText: Equatable {
  /// 作業ツリーに出したときの姿（baseline と同じ底）。
  case present(Data)
  /// サブモジュール（gitlink が指すコミット）。本文は取らない。
  case submodule(String)
  /// そのコミットに無い。
  case absent
  /// 取れなかった（git の失敗・手元に無いコミット）。
  case failed
}

extension GitRepo {
  /// あるパスの、コミット `commit` での本文（サブモジュールなら gitlink が指すコミット）。在るかと種類を先に確かめてから、
  /// baseline と同じ取り方（`blob(oid:relativePath:)`。smudge と eol を通し、textconv・外部 diff は通らない）で本文を取る
  /// ——「そのコミットに無い」を git の失敗と取り違えないため。
  ///
  /// そのコミットのツリーの項目（`treeEntries`）で在るかと種類を読む——gitlink の答え方が git の版で変わる `cat-file` に
  /// 頼らない。手元に無いコミットは「取れなかった」にする（無いコミットのパスを「そのコミットに無い」と答えると、呼び出し側が
  /// そのコミットを取りに行く合図を失う）。
  func version(
    of relativePath: String, atCommit commit: String,
    completion: @escaping (GitVersionText) -> Void
  ) {
    treeEntries(at: commit, relativePaths: [relativePath]) { [self] entries in
      guard let entries else { return completion(.failed) }
      switch entries.values.first {
      case .file(let oid)?:
        blob(oid: oid, relativePath: relativePath) { data in
          completion(data.map(GitVersionText.present) ?? .failed)
        }
      case .submodule(let commit)?: completion(.submodule(commit))
      case nil: completion(.absent)
      }
    }
  }
}
