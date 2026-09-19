import AppKit
import UniformTypeIdentifiers

/// allow の実行側。ローカルファイルは家族ごとに決めた開き先へ明示的に渡し、Launch Services の
/// ファイル→handler 解決（拡張子の無い実行ファイルや `.command` を Terminal に渡す等）には委ねない。メインスレッドで呼ぶ。
extension UntrustedLink.Target {
  func open() {
    let workspace = NSWorkspace.shared
    switch self {
    case .url(let url):
      workspace.open(url)
    case .text(let url):
      // ⌘⇧E と同じ解決の GUI コードエディタ。無ければ plain text の既定アプリ（TextEdit 等）。
      if let editor = EditorLauncher.resolve() {
        EditorLauncher.open(url.path, editor: editor)
      } else {
        Self.open(url, withDefaultAppFor: .plainText)
      }
    case .typed(let url, let type):
      Self.open(url, withDefaultAppFor: type)
    case .folder(let url):
      workspace.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }
  }

  /// 型で引いた既定アプリに渡す（ファイルで引くと実行ビットで handler が化ける）。
  /// 型に既定アプリが無ければ Finder で見せるに留める。
  private static func open(_ url: URL, withDefaultAppFor type: UTType) {
    let workspace = NSWorkspace.shared
    guard let app = workspace.urlForApplication(toOpen: type) else {
      workspace.activateFileViewerSelecting([url])
      return
    }
    workspace.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
  }
}
