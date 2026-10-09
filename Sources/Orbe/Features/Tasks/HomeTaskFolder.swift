import Foundation

/// Home のタスクの作業場（`<Home>/tasks/<ID>-<短い名前>/`）。リポジトリに属さないタスクは worktree の代わりにここで
/// 作業し、タスクの worktree と同じ席に記録する——タブの連のキーとタスクの worktree は同じ根の規則
/// （`GitWorktreeRoot.root(of:)`。git の外ならそのパス）で揃うので、行の agent の札・⌘T の続きからがそのまま効く。
/// `start_task` と ⌘⇧X の ⌘T が同じこの規則を通る。
enum HomeTaskFolder {
  /// 作業場のパス。記録があればそれ（消えていても同じ場所）、無ければ Home の下にタスクの ID と短い名前で決める。
  static func path(for task: TaskItem, home: String) -> String {
    if let worktree = task.worktree { return worktree.path }
    let slug = slug(task.title)
    let name = slug.isEmpty ? "\(task.id)" : "\(task.id)-\(slug)"
    return (home as NSString).appendingPathComponent("tasks/\(name)")
  }

  /// 無ければ作る。既にあれば中身を見ずに使う。作ったら true。
  static func prepare(_ path: String) throws -> Bool {
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      isDirectory.boolValue
    {
      return false
    }
    try FileManager.default.createDirectory(
      atPath: path, withIntermediateDirectories: true)
    return true
  }

  /// Home が git の作業ツリーの中にあるか。あれば、タスクの作業場の根がそのリポジトリになり、作業場の一致と
  /// 「1 つの作業場は 1 つのタスク」が崩れる。
  static func isInsideGit(home: String) -> Bool {
    GitWorktreeRoot.root(of: home) != GitWorktreeRoot.normalizedPath(home)
  }

  /// タイトルから作る短い名前。パス区切り・制御文字・空白類（と `-` の並び）を 1 つの `-` に畳み、先頭の
  /// `slugLength` 文字で切る。
  static func slug(_ title: String) -> String {
    var scalars = String.UnicodeScalarView()
    var pendingDash = false
    for scalar in title.unicodeScalars {
      if separators.contains(scalar) || scalar.properties.generalCategory == .control {
        pendingDash = !scalars.isEmpty
        continue
      }
      if pendingDash { scalars.append("-") }
      pendingDash = false
      scalars.append(scalar)
    }
    return String(String(scalars).prefix(slugLength))
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
  }

  private static let slugLength = 40
  private static let separators = CharacterSet.whitespacesAndNewlines.union(
    CharacterSet(charactersIn: "/:\\-"))
}
