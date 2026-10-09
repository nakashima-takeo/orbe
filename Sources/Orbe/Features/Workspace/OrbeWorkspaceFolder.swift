import Foundation

/// Orbe の workspace の root（`StateDir.base()/orbe-workspace/`）と、その用意。
enum OrbeWorkspaceFolder {
  /// テスト用にフォルダを差し替える（他の永続ファイルと同じく隔離ハーネスが張る）。
  nonisolated(unsafe) static var urlOverride: URL?

  /// フォルダの場所。解決できなければ nil。フォルダの有無は問わない。
  static var url: URL? {
    urlOverride ?? StateDir.base()?.appendingPathComponent("orbe-workspace", isDirectory: true)
  }

  /// フォルダが無ければ `language` の CLAUDE.md 入りで作る。あれば中身を見ない（人や AI の書き換えを上書きしない）。
  /// 一時領域で組んでから最終名へ移す——途中で失敗して「フォルダはあるが CLAUDE.md が無い」状態が残ると、
  /// 以後は作り直されない。失敗はログに残し、フォルダが無いままなので次の起動で再挑戦する。
  static func prepare(language: Language) {
    guard let url else {
      NSLog("[orbe-workspace] state dir unresolved, folder not prepared")
      return
    }
    let fm = FileManager.default
    guard !fm.fileExists(atPath: url.path) else { return }
    do {
      let parent = url.deletingLastPathComponent()
      try fm.createDirectory(at: parent, withIntermediateDirectories: true)
      let scratch = try fm.url(
        for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: parent, create: true)
      defer { try? fm.removeItem(at: scratch) }
      let staged = scratch.appendingPathComponent(url.lastPathComponent, isDirectory: true)
      try fm.createDirectory(at: staged, withIntermediateDirectories: false)
      try OrbeWorkspaceTemplate.claudeMd(language).write(
        to: staged.appendingPathComponent("CLAUDE.md"), atomically: false, encoding: .utf8)
      guard !fm.fileExists(atPath: url.path) else { return }
      try fm.moveItem(at: staged, to: url)
    } catch {
      NSLog("[orbe-workspace] prepare failed: \(error)")
    }
  }
}
