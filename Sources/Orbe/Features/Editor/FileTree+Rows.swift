import Foundation

/// 行の組み立て。描画用に、根の直下から深さ優先で平坦にする（閉じたディレクトリの配下は出ない）。子がフォルダ 1 つだけの
/// フォルダの連なりは、覚え（`onlyChild`）をたどって 1 行にまとめる。行は覚えだけを読み、ディスクには触れない。
extension FileTree {
  enum RowKind: Equatable {
    case directory(isExpanded: Bool)
    /// `url` はそのファイル（開く・閉じる・種別チップの宛先）。`mark` は開いている文書の印（開いていなければ nil）。
    case file(url: URL, badge: GitStatus.Badge?, mark: EditorItemListRow.Mark?)
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
    let kind: RowKind
    /// 選択がこの行（連なりなら、そのどれか）。
    let isSelected: Bool
    /// 選択の行か、その祖先のフォルダの行（字下げの線を accent にする）。
    let isOnSelectionPath: Bool
  }

  /// `head` から覚えをたどった、連なりのいちばん深いフォルダ。
  func deepest(from head: String) -> String {
    var path = head
    while let child = onlyChild[path] { path = Self.join(path, child) }
    return path
  }

  /// 選択を含む行の同一性（選択が連なりの途中か、いちばん深いフォルダなら、その連なりの先頭）。選択が無ければ nil。
  var selectedRowID: String? {
    guard let selection else { return nil }
    guard selection.isDirectory else { return selection.path }
    var head = selection.path
    while !head.isEmpty {
      let parent = Self.parent(of: head)
      guard !parent.isEmpty, onlyChild[parent] == Self.name(of: head) else { break }
      head = parent
    }
    return head
  }

  /// 行の入力。絞り込んでいないときはディスクの一覧と覚えと展開集合、絞り込み中は届いた結果と、絞り込みの間に畳んだ集合。
  private struct RowSource {
    let children: [String: [RootFiles.Entry]]
    let onlyChild: [String: String]
    let isExpanded: (String) -> Bool
    let newEntry: NewEntry?
  }

  var rows: [Row] {
    var out: [Row] = []
    let source: RowSource
    if let result = filter.shown {
      let collapsed = filter.collapsed
      source = RowSource(
        children: result.children, onlyChild: result.onlyChild,
        isExpanded: { !collapsed.contains($0) }, newEntry: nil)
    } else {
      let expanded = self.expanded
      source = RowSource(
        children: entries, onlyChild: onlyChild, isExpanded: expanded.contains,
        newEntry: newEntry)
    }
    append(directory: "", depth: 0, source: source, into: &out)
    return out
  }

  /// 一覧は名前順（→ `RootFiles.entries`）。ツリーではディレクトリを先に並べる（VS Code の慣習）。
  private static func directoriesFirst(_ list: [RootFiles.Entry]) -> [RootFiles.Entry] {
    list.filter(\.isDirectory) + list.filter { !$0.isDirectory }
  }

  private func append(
    directory: String, depth: Int, source: RowSource, into out: inout [Row]
  ) {
    if let newEntry = source.newEntry, newEntry.directory == directory {
      out.append(
        Row(
          id: Self.inputRowID(newEntry), depth: depth, name: "", prefix: "",
          kind: .input(isDirectory: newEntry.isDirectory, generation: newEntry.generation),
          isSelected: false, isOnSelectionPath: false))
    }
    for entry in Self.directoriesFirst(source.children[directory] ?? []) {
      let path = Self.join(directory, entry.name)
      let onPath = isOnSelectionPath(path)
      guard entry.isDirectory else {
        out.append(
          Row(
            id: path, depth: depth, name: entry.name, prefix: "",
            kind: .file(url: entry.url, badge: status?.badge(of: path), mark: openMarks[path]),
            isSelected: selected == path,
            isOnSelectionPath: onPath))
        continue
      }
      // 連なりでないフォルダ（ほとんどの行）は、連なりの列を作らず、一覧の名前をそのまま使う。
      let chain = chain(from: path, source)
      let deepest = chain.last ?? path
      let isExpanded = source.isExpanded(deepest)
      out.append(
        Row(
          id: path, depth: depth, name: chain.isEmpty ? entry.name : Self.name(of: deepest),
          prefix: chain.dropLast().map { Self.name(of: $0) + "/" }.joined(),
          kind: .directory(isExpanded: isExpanded),
          isSelected: selected.map { chain.isEmpty ? $0 == path : chain.contains($0) } ?? false,
          isOnSelectionPath: onPath))
      if isExpanded { append(directory: deepest, depth: depth + 1, source: source, into: &out) }
    }
  }

  /// `head` から覚えをたどった連なり（先頭からいちばん深いフォルダまで）。連なりでなければ空。行内入力の挿し先で止める（入力行
  /// はその中身）。
  private func chain(from head: String, _ source: RowSource) -> [String] {
    guard head != source.newEntry?.directory, source.onlyChild[head] != nil else { return [] }
    var chain = [head]
    var path = head
    while path != source.newEntry?.directory, let child = source.onlyChild[path] {
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
