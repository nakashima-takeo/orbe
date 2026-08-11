import AppKit
import Foundation

/// アクティブペインの cwd を GUI エディタで開く（Cmd+Shift+E）。
/// エディタは「$VISUAL → $EDITOR（GUI のみ）→ PATH 検索」で決め、`ShellPATH` の PATH
/// で実行ファイルを解決する（GUI アプリの貧弱な PATH ではユーザー導入の `code` 等が見えない）。
enum EditorLauncher {
  /// PATH 検索の対象。先頭ヒットを採る。`$EDITOR` が GUI かの判定にも使う。
  private static let guiEditors = ["code", "cursor", "windsurf", "zed", "subl"]

  /// cwd を検出エディタでフォルダとして開く。cwd 不明は beep、エディタ未検出は NSAlert（現在言語）。
  static func openCwd(_ cwd: String?, localization: LocalizationStore) {
    guard let cwd else {
      NSSound.beep()
      return
    }
    guard let editor = resolve() else {
      let alert = NSAlert()
      alert.messageText = localization.string(.editorNotFoundTitle)
      alert.informativeText = localization.string(.editorNotFoundMessage)
      alert.runModal()
      return
    }
    open(directory: cwd, editor: editor)
  }

  /// 見つかったエディタの絶対パス。**見つからなかったことは覚えない**——起動直後のまだ痩せた PATH で
  /// 一度外した結果を焼くと、PATH が整った後も「エディタ未検出」のままになる。
  private static var cached: String?

  /// 起動すべきエディタを解決する。見つからなければ nil。
  private static func resolve() -> String? {
    if let cached { return cached }
    let result = resolveUncached()
    cached = result
    return result
  }

  private static func resolveUncached() -> String? {
    let path = ShellPATH.shared.value()
    let env = ProcessInfo.processInfo.environment

    // $VISUAL → $EDITOR の順。CLI エディタ（vim 等）は採らず PATH 検索へ落とす。
    for key in ["VISUAL", "EDITOR"] {
      guard let raw = env[key]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { continue }
      // `code --wait` のような引数付きも先頭語で判定する。
      let command = raw.split(separator: " ").first.map(String.init) ?? raw
      let name = (command as NSString).lastPathComponent
      guard guiEditors.contains(name) else { continue }
      if let resolved = locate(command, in: path) { return resolved }
    }

    // PATH 検索で GUI エディタの先頭ヒット。
    for name in guiEditors {
      if let resolved = locate(name, in: path) { return resolved }
    }
    return nil
  }

  /// 実行ファイルを解決する。絶対パスならそのまま検証し、コマンド名なら PATH 各要素から探す。
  private static func locate(_ command: String, in path: String) -> String? {
    let fm = FileManager.default
    if command.hasPrefix("/") {
      return fm.isExecutableFile(atPath: command) ? command : nil
    }
    for dir in path.split(separator: ":").map(String.init) {
      let candidate = (dir as NSString).appendingPathComponent(command)
      if fm.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
  }

  /// `editor <directory>` をバックグラウンド起動する（Orbe をブロックしない）。
  /// PATH は起動のたび `ShellPATH` から取る（解決時点の値を焼くと、まだ痩せていた PATH を
  /// そのセッションの全エディタ起動へ引き継いでしまう）。
  private static func open(directory: String, editor: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: editor)
    process.arguments = [directory]
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = ShellPATH.shared.value()
    process.environment = environment
    try? process.run()
  }
}
