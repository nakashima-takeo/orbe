import Foundation
import OrbePaths

/// Home の root（ホームディレクトリ直下のチャネルごとのフォルダ。隔離起動では隔離先の `home/`）と、その用意。
enum HomeFolder {
  /// テスト用にフォルダを差し替える（他の永続ファイルと同じく隔離ハーネスが張る）。
  nonisolated(unsafe) static var urlOverride: URL?

  /// Orbe の操作の指示の置き場（root からの相対）。claude は `.claude/rules/` の下を指示として読む。
  static let rulesPath = ".claude/rules/orbe.md"

  /// フォルダの場所。フォルダの有無は問わない。
  static var url: URL {
    urlOverride
      ?? url(
        isolatedStateDir: StateDir.isolatedBase,
        home: FileManager.default.homeDirectoryForCurrentUser, channel: OrbePaths.channel)
  }

  /// 場所の規則。隔離起動なら隔離先の `home/`、そうでなければ `home` の下のチャネルごとの名前
  /// （release は `orbe`、dev は `orbe-dev`）。隔離したインスタンスに本物のフォルダを触らせない。
  static func url(isolatedStateDir: URL?, home: URL, channel: OrbePaths.Channel) -> URL {
    if let isolatedStateDir {
      return isolatedStateDir.appendingPathComponent("home", isDirectory: true)
    }
    let name =
      switch channel {
      case .release: "orbe"
      case .dev: "orbe-dev"
      }
    return home.appendingPathComponent(name, isDirectory: true)
  }

  /// `language` で用意する。Orbe の操作の指示は Orbe が持つので毎回今の雛形へ書き直す。CLAUDE.md は人と AI の欄なので、
  /// フォルダを作るときに 1 回だけ置き、以後は中身を見ない。失敗はログに残し、次の起動で再挑戦する。
  static func prepare(language: Language) {
    let url = Self.url
    create(url, language: language)
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    do {
      let rules = url.appendingPathComponent(rulesPath)
      try FileManager.default.createDirectory(
        at: rules.deletingLastPathComponent(), withIntermediateDirectories: true)
      try HomeTemplate.rules(language, home: url.path).write(
        to: rules, atomically: true, encoding: .utf8)
    } catch {
      NSLog("[home] rules not written: \(error)")
    }
  }

  /// フォルダが無ければ CLAUDE.md 入りで作る。一時領域で組んでから最終名へ移す——途中で失敗して
  /// 「フォルダはあるが CLAUDE.md が無い」状態が残ると、以後は作り直されない。
  private static func create(_ url: URL, language: Language) {
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
      try HomeTemplate.claudeMd(language).write(
        to: staged.appendingPathComponent("CLAUDE.md"), atomically: false, encoding: .utf8)
      guard !fm.fileExists(atPath: url.path) else { return }
      try fm.moveItem(at: staged, to: url)
    } catch {
      NSLog("[home] prepare failed: \(error)")
    }
  }
}
