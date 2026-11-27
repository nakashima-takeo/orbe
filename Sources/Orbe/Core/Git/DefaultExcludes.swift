import Foundation

/// 既定の除外（VS Code の `search.exclude` と `files.exclude` の既定）。ディレクトリは配下ごと、ファイルは名前で、拡張子は
/// 名前の末尾で外す。プロジェクト検索（git grep に渡す除外）とツリーの絞り込みの対象（集めた後に当てる）が、ここを読む。
enum DefaultExcludes {
  static let directories = [
    "node_modules", "bower_components", ".git", ".svn", ".hg", ".jj",
  ]
  static let files = [".DS_Store", "Thumbs.db"]
  static let extensions = ["code-search"]

  /// 根からの相対のフォルダが、既定の除外のフォルダか、その中か。
  static func containsDirectory(_ relativePath: String) -> Bool {
    relativePath.split(separator: "/").contains { directories.contains(String($0)) }
  }

  /// 根からの相対パスが既定の除外に当たるか。
  static func contains(_ relativePath: String) -> Bool {
    let components = relativePath.split(separator: "/").map(String.init)
    guard let name = components.last else { return false }
    return components.dropLast().contains(where: directories.contains)
      || files.contains(name)
      || extensions.contains((name as NSString).pathExtension)
  }
}
