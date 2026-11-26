import Foundation

/// 行の組み立て。描画用に、根の直下から深さ優先で平坦にする（閉じたディレクトリの配下は出ない）。子がフォルダ 1 つだけの
/// フォルダの連なりは、覚え（`onlyChild`）をたどって 1 行にまとめる。行は覚えだけを読み、ディスクには触れない。
extension FileTree {
  enum RowKind: Equatable {
    case directory(isExpanded: Bool)
    case file(badge: GitStatus.Badge?)
    /// 新規作成の行内入力（ディレクトリならシェブロンの幅を空ける）。世代は `NewEntry.generation`。
    case input(isDirectory: Bool, generation: Int)
  }

  struct Row: Identifiable, Equatable {
    /// 行の同一性。フォルダの行は連なりの先頭のフォルダのパス（先読みの結果が届いても、途中に子が増えても替わらない）。
    let id: String
    let depth: Int
    /// 名前の最後の段。
    let name: String
    /// 連なりの名前の前の段（`docs/spec/`。連なりでなければ空）。
    let prefix: String
    /// フォルダの行は連なりのいちばん深いフォルダ（中身を出すフォルダ）、ファイルの行はそのファイル。
    let url: URL
    let kind: RowKind
    /// 選択がこの行（連なりなら、そのどれか）。
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
          id: Self.inputRowID(newEntry), depth: depth, name: "", prefix: "",
          url: url(of: directory),
          kind: .input(isDirectory: newEntry.isDirectory, generation: newEntry.generation),
          isSelected: false, isOnSelectionPath: false))
    }
    for entry in Self.directoriesFirst(entries[directory] ?? []) {
      let path = Self.join(directory, entry.name)
      let onPath = isOnSelectionPath(path)
      guard entry.isDirectory else {
        out.append(
          Row(
            id: path, depth: depth, name: entry.name, prefix: "", url: entry.url,
            kind: .file(badge: status?.badge(of: path)), isSelected: selected == path,
            isOnSelectionPath: onPath))
        continue
      }
      let chain = chain(from: path)
      let deepest = chain[chain.count - 1]
      let isExpanded = expanded.contains(deepest)
      out.append(
        Row(
          id: path, depth: depth, name: Self.name(of: deepest),
          prefix: chain.dropLast().map { Self.name(of: $0) + "/" }.joined(),
          url: url(of: deepest), kind: .directory(isExpanded: isExpanded),
          isSelected: selected.map(chain.contains) ?? false, isOnSelectionPath: onPath))
      if isExpanded { append(directory: deepest, depth: depth + 1, into: &out) }
    }
  }

  /// `head` から覚えをたどった連なり（先頭からいちばん深いフォルダまで）。行内入力の挿し先で止める（入力行はその中身）。
  private func chain(from head: String) -> [String] {
    var chain = [head]
    var path = head
    while path != newEntry?.directory, let child = onlyChild[path] {
      path = Self.join(path, child)
      chain.append(path)
    }
    return chain
  }

  private func isOnSelectionPath(_ path: String) -> Bool {
    guard let selected else { return false }
    return selected == path || selected.hasPrefix(path + "/")
  }
}
