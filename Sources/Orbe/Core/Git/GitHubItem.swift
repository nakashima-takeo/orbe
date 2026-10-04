import Foundation

/// GitHub の Issue か PR を 1 つ指す同一性。Issue と PR は 1 つのリポジトリの中で番号の空間を共有するので、
/// 同じリポジトリの同じ番号は同じ項目であり、等値はリポジトリと番号だけで決まる（種別を含めない）。
struct GitHubItemID: Hashable {
  let repo: GitHubRepoName
  let number: Int

  /// `repo` は `owner/name`（各段は英数字・`-`・`_`・`.` で空でない）、`number` は 1 以上だけを受ける。
  init?(repo: String, number: Int) {
    let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, number >= 1,
      parts.allSatisfy({ part in
        !part.isEmpty
          && part.unicodeScalars.allSatisfy {
            $0.isASCII
              && (CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0))
          }
      })
    else { return nil }
    self.repo = GitHubRepoName(nameWithOwner: repo)
    self.number = number
  }

  /// `owner/name#221`。
  var text: String { "\(repo.value)#\(number)" }

  /// owner を除いたリポジトリの名前。
  var repoName: String { String(repo.value.split(separator: "/").last ?? "") }

  var owner: String { String(repo.value.split(separator: "/").first ?? "") }
}

/// Issue か PR か。
enum GitHubItemKind: String, Codable, Equatable {
  case issue
  case pr
}
