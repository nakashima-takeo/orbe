import Foundation

/// ツリーのパスの扱い（根からの相対パス。根は空）。
extension FileTree {
  func url(of relativePath: String) -> URL {
    let rootURL = URL(fileURLWithPath: root, isDirectory: true)
    return relativePath.isEmpty
      ? rootURL : rootURL.appendingPathComponent(relativePath, isDirectory: true)
  }

  func relativePath(of url: URL) -> String? {
    relativePath(ofAbsolute: GitWorktreeRoot.normalizedPath(url.path))
  }

  func relativePath(ofAbsolute path: String) -> String? {
    guard path.hasPrefix(root + "/") else { return nil }
    return String(path.dropFirst(root.count + 1))
  }

  /// `path` が、取り直した `directory` の一覧から消えたフォルダか、その配下か。
  static func isGone(_ path: String, under directory: String, present: Set<String>) -> Bool {
    let prefix = directory.isEmpty ? "" : directory + "/"
    guard path.hasPrefix(prefix), path.count > prefix.count else { return false }
    let child = prefix + (path.dropFirst(prefix.count).split(separator: "/").first ?? "")
    return !present.contains(child)
  }

  static func join(_ directory: String, _ name: String) -> String {
    directory.isEmpty ? name : directory + "/" + name
  }

  /// フォルダ `directory` の直下の、`path` を含むもの（`path` が直下ならそれ自身）。
  static func child(of directory: String, toward path: String) -> String {
    let prefix = directory.isEmpty ? "" : directory + "/"
    let rest = path.dropFirst(prefix.count)
    return prefix + (rest.split(separator: "/").first.map(String.init) ?? String(rest))
  }

  /// パスの最後の段。
  static func name(of path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return path }
    return String(path[path.index(after: slash)...])
  }

  static func parent(of path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return "" }
    return String(path[..<slash])
  }

  /// 根を除く祖先（浅い順）。
  static func ancestors(of path: String) -> [String] {
    var out: [String] = []
    var current = parent(of: path)
    while !current.isEmpty {
      out.append(current)
      current = parent(of: current)
    }
    return out.reversed()
  }
}
