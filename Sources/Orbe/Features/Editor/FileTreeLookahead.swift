import Foundation

/// ツリーの先読み——開いていないフォルダが「中身がフォルダ 1 つだけ」かを裏で調べ、続いていればその先も同じ仕事の中で調べる。
/// 入れ子の根（`.git` を持つフォルダ。サブモジュール・入れ子のリポジトリ）とその中は読まず、「連なりでない」として返す。
/// 裏の直列の 1 本で、頼まれた順に走り、1 回の頼みの結果をまとめて main へ返す。監視の通知は変化の後に届き、仕事は直列なので、
/// 同じフォルダについては、後から届いた結果ほど新しいディスクの状態になる。
final class FileTreeLookahead: Sendable {
  /// 調べたフォルダ（根からの相対）→ ただ 1 つの子フォルダの名前（無ければ nil）。
  typealias Result = [String: String?]

  private let root: URL
  private let queue = DispatchQueue(label: "orbe.file-tree.lookahead", qos: .userInitiated)

  init(root: String) {
    self.root = URL(fileURLWithPath: root, isDirectory: true)
  }

  /// `paths`（根からの相対のフォルダ）から調べ、結果を main 上で `deliver` へ渡す。
  func request(_ paths: Set<String>, deliver: @escaping @MainActor @Sendable (Result) -> Void) {
    guard !paths.isEmpty else { return }
    let root = self.root
    queue.async {
      var result = Result()
      var nested: [String: Bool] = [:]
      for start in paths {
        var path = start
        while result[path] == nil {
          let only =
            Self.isNested(path, root: root, known: &nested)
            ? nil : RootFiles.onlyChildDirectory(of: root.appendingPathComponent(path))
          result[path] = .some(only)
          guard let only else { break }
          path += "/" + only
        }
      }
      DispatchQueue.main.async { deliver(result) }
    }
  }

  /// `path`（根からの相対）か、根より下のその祖先が `.git` を持つか。調べたフォルダは `known` に覚える。
  private static func isNested(_ path: String, root: URL, known: inout [String: Bool]) -> Bool {
    if let value = known[path] { return value }
    let parent = (path as NSString).deletingLastPathComponent
    let value =
      (!parent.isEmpty && isNested(parent, root: root, known: &known))
      || FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path + "/.git")
    known[path] = value
    return value
  }
}
