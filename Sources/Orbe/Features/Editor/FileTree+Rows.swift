import Foundation

/// 行の組み立て。描画用に、根の直下から深さ優先で平坦にする（閉じたディレクトリの配下は出ない）。
extension FileTree {
  enum RowKind: Equatable {
    case directory(isExpanded: Bool)
    case file(badge: GitStatus.Badge?)
    /// 新規作成の行内入力（ディレクトリならシェブロンの幅を空ける）。世代は `NewEntry.generation`。
    case input(isDirectory: Bool, generation: Int)
  }

  struct Row: Identifiable, Equatable {
    let id: String
    let depth: Int
    let name: String
    let url: URL
    let kind: RowKind
    let isSelected: Bool
    /// 選択の行か、その祖先のフォルダの行（字下げの線を accent にする）。
    let isOnSelectionPath: Bool
  }

  var rows: [Row] {
    var out: [Row] = []
    append(directory: "", depth: 0, into: &out)
    return out
  }

  /// 一覧は名前順（→ `RootFiles.entries`）。ツリーではディレクトリを先に並べる（VS Code の慣習）。
  private static func directoriesFirst(_ list: [RootFiles.Entry]) -> [RootFiles.Entry] {
    list.filter(\.isDirectory) + list.filter { !$0.isDirectory }
  }

  private func append(directory: String, depth: Int, into out: inout [Row]) {
    if let newEntry, newEntry.directory == directory {
      out.append(
        Row(
          id: Self.inputRowID(newEntry), depth: depth, name: "", url: url(of: directory),
          kind: .input(isDirectory: newEntry.isDirectory, generation: newEntry.generation),
          isSelected: false, isOnSelectionPath: false))
    }
    for entry in Self.directoriesFirst(entries[directory] ?? []) {
      let path = Self.join(directory, entry.name)
      let onPath = isOnSelectionPath(path)
      if entry.isDirectory {
        let isExpanded = expanded.contains(path)
        out.append(
          Row(
            id: path, depth: depth, name: entry.name, url: entry.url,
            kind: .directory(isExpanded: isExpanded), isSelected: selected == path,
            isOnSelectionPath: onPath))
        if isExpanded { append(directory: path, depth: depth + 1, into: &out) }
      } else {
        out.append(
          Row(
            id: path, depth: depth, name: entry.name, url: entry.url,
            kind: .file(badge: status?.badge(of: path)), isSelected: selected == path,
            isOnSelectionPath: onPath))
      }
    }
  }

  private func isOnSelectionPath(_ path: String) -> Bool {
    guard let selected else { return false }
    return selected == path || selected.hasPrefix(path + "/")
  }
}
