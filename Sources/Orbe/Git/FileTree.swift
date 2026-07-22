import Foundation

/// ワークツリーのファイルツリー 1 ノード（`git ls-files` のパス列から構築）。
struct FileTreeNode: Equatable {
  let name: String
  /// repo root 相対パス。
  let path: String
  /// nil = ファイル。非 nil = フォルダ（子はフォルダ優先・名前順）。
  let children: [FileTreeNode]?

  var isDirectory: Bool { children != nil }
}

/// パス列（repo root 相対）からファイルツリーを組む。
/// 並びは各階層でフォルダ優先・大文字小文字を無視した名前順（同名は大文字小文字で安定化）。
enum FileTree {
  static func build(paths: [String]) -> [FileTreeNode] {
    /// 中間表現（子をパス名 → ノードで持つ可変ツリー）。
    final class Builder {
      var directories: [String: Builder] = [:]
      var files: Set<String> = []
    }

    let root = Builder()
    for path in paths {
      let components = path.split(separator: "/").map(String.init)
      guard let fileName = components.last else { continue }
      var node = root
      for dir in components.dropLast() {
        if let existing = node.directories[dir] {
          node = existing
        } else {
          let child = Builder()
          node.directories[dir] = child
          node = child
        }
      }
      node.files.insert(fileName)
    }

    func emit(_ builder: Builder, prefix: String) -> [FileTreeNode] {
      let dirs = builder.directories.keys.sorted(by: ordered).map { name in
        FileTreeNode(
          name: name, path: prefix + name,
          children: emit(builder.directories[name]!, prefix: prefix + name + "/"))
      }
      let files = builder.files.sorted(by: ordered).map { name in
        FileTreeNode(name: name, path: prefix + name, children: nil)
      }
      return dirs + files
    }
    return emit(root, prefix: "")
  }

  private static func ordered(_ a: String, _ b: String) -> Bool {
    let fold = a.lowercased().compare(b.lowercased())
    if fold != .orderedSame { return fold == .orderedAscending }
    return a < b
  }
}
