import AppKit
import Foundation

/// アクティブペインの cwd を GUI エディタで開く（Cmd+Shift+E）。
/// エディタは「$VISUAL → $EDITOR（GUI のみ）→ PATH 検索」で決め、ログインシェルの PATH
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
    guard let resolved = resolve() else {
      let alert = NSAlert()
      alert.messageText = localization.string(.editorNotFoundTitle)
      alert.informativeText = localization.string(.editorNotFoundMessage)
      alert.runModal()
      return
    }
    open(directory: cwd, editor: resolved.editor, path: resolved.path)
  }

  /// 解決済みエディタと、解決に使ったログインシェルの PATH。子プロセス起動にも同じ PATH を使う。
  private struct Resolved {
    let editor: String
    let path: String?
  }

  /// 解決結果。初回に一度だけ解決（ログインシェルも初回1回だけ起動）してキャッシュする。
  private static var cached: Resolved??

  /// 起動すべきエディタを解決する。見つからなければ nil。
  private static func resolve() -> Resolved? {
    if let cached { return cached }
    let result = resolveUncached()
    cached = result
    return result
  }

  private static func resolveUncached() -> Resolved? {
    let path = GitRunner.loginShellPATH()
    let env = ProcessInfo.processInfo.environment

    // $VISUAL → $EDITOR の順。CLI エディタ（vim 等）は採らず PATH 検索へ落とす。
    for key in ["VISUAL", "EDITOR"] {
      guard let raw = env[key]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { continue }
      // `code --wait` のような引数付きも先頭語で判定する。
      let command = raw.split(separator: " ").first.map(String.init) ?? raw
      let name = (command as NSString).lastPathComponent
      guard guiEditors.contains(name) else { continue }
      if let resolved = locate(command, in: path) { return Resolved(editor: resolved, path: path) }
    }

    // PATH 検索で GUI エディタの先頭ヒット。
    for name in guiEditors {
      if let resolved = locate(name, in: path) { return Resolved(editor: resolved, path: path) }
    }
    return nil
  }

  /// 実行ファイルを解決する。絶対パスならそのまま検証し、コマンド名なら PATH 各要素から探す。
  private static func locate(_ command: String, in path: String?) -> String? {
    let fm = FileManager.default
    if command.hasPrefix("/") {
      return fm.isExecutableFile(atPath: command) ? command : nil
    }
    let dirs = (path ?? "").split(separator: ":").map(String.init)
    for dir in dirs {
      let candidate = (dir as NSString).appendingPathComponent(command)
      if fm.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
  }

  /// `editor <directory>` をバックグラウンド起動する（Orbe をブロックしない）。
  /// PATH は解決時に取得済みのものを使い回す（ログインシェルを再起動しない）。
  private static func open(directory: String, editor: String, path: String?) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: editor)
    process.arguments = [directory]
    var environment = ProcessInfo.processInfo.environment
    if let path { environment["PATH"] = path }
    process.environment = environment
    try? process.run()
  }
}
