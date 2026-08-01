import Foundation

/// パス補完の 1 候補（実在の子ディレクトリ）。
struct FolderSuggestion: Equatable, Identifiable {
  /// フォルダ名（末尾セグメント）。
  let name: String
  /// 展開済みフルパス（`~` 展開後）。確定時に path 欄へ差し込む。
  let fullPath: String
  /// `child/.git` が存在する＝git タグを出す。ディレクトリでも worktree の `.git` ファイルでも真。
  let isRepo: Bool

  var id: String { fullPath }
}

/// 既存フォルダのパス補完（純関数・同期）。入力の末尾セグメントで前方一致した実在の子ディレクトリを
/// 名前昇順で返す。`FileManager` 列挙はネットワークマウントで詰まりうるため **背景 queue で呼ぶこと**。
enum FolderSuggestions {
  /// - `input`: パス欄の生入力（`~` 可）。末尾 `/` の手前までを親、末尾セグメントを前方一致キーにする。
  ///   `~` 単独や末尾 `/` はキー空＝親の全子。隠し（`.` 始まり）はキーが `.` 始まりのときだけ含める。
  static func compute(input: String, fileManager: FileManager = .default) -> [FolderSuggestion] {
    let (parent, key) = split(input)
    guard !parent.isEmpty, let entries = try? fileManager.contentsOfDirectory(atPath: parent) else {
      return []  // 親が空・存在しない・読めない
    }

    let lowerKey = key.lowercased()
    let includeHidden = key.hasPrefix(".")

    return
      entries
      .compactMap { entryName -> FolderSuggestion? in
        if !includeHidden, entryName.hasPrefix(".") { return nil }
        if !lowerKey.isEmpty, !entryName.lowercased().hasPrefix(lowerKey) { return nil }
        let full = (parent as NSString).appendingPathComponent(entryName)
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else {
          return nil  // ディレクトリのみ
        }
        let dotGit = (full as NSString).appendingPathComponent(".git")
        return FolderSuggestion(
          name: entryName, fullPath: full, isRepo: fileManager.fileExists(atPath: dotGit))
      }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  /// 親ディレクトリ（`~` 展開後）と前方一致キーへ割る。末尾 `/` や `~` 単独はキー空（＝親の全子）。
  private static func split(_ input: String) -> (parent: String, key: String) {
    let parentRaw: String
    let key: String
    if input.hasSuffix("/") {
      let dropped = String(input.dropLast())
      parentRaw = dropped.isEmpty ? "/" : dropped
      key = ""
    } else if input == "~" {
      parentRaw = "~"
      key = ""
    } else {
      let ns = input as NSString
      parentRaw = ns.deletingLastPathComponent
      key = ns.lastPathComponent
    }
    return ((parentRaw as NSString).expandingTildeInPath, key)
  }
}
