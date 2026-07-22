import AppKit
import GhosttyKit
import UniformTypeIdentifiers

/// libghostty の OPEN_URL アクションの host 側処理。
/// 本家 macOS 版と同じく NSWorkspace で開く。これを実装しないと libghostty の
/// フォールバック（`internal_os.open`）が走り、`os/open.zig` の無限ループ
/// （stderr の改行を消費しないループ）を踏んで CPU 暴走・ログ洪水になる。
enum OpenURL {
  enum Kind {
    case unknown, text, html

    init(_ c: ghostty_action_open_url_kind_e) {
      switch c {
      case GHOSTTY_ACTION_OPEN_URL_KIND_TEXT: self = .text
      case GHOSTTY_ACTION_OPEN_URL_KIND_HTML: self = .html
      default: self = .unknown
      }
    }
  }

  /// URL 文字列を URL へ解決する（純関数・副作用なし）。
  /// scheme を持つ真の URL はそのまま、scheme 無し（プレーンなパス）は
  /// `~` を展開してファイル URL とみなす（ghostty-org/ghostty#8763）。
  static func resolve(_ raw: String) -> URL {
    if let candidate = URL(string: raw), candidate.scheme != nil {
      return candidate
    }
    let expanded = NSString(string: raw).standardizingPath
    return URL(filePath: expanded)
  }

  /// 解決した URL を macOS の作法で開く（メインスレッドで呼ぶこと）。
  /// text は既定テキストエディタ（拡張子既定 → プレーンテキスト既定の順）、
  /// それ以外は URL の既定アプリで開く。
  static func open(kind: Kind, url: URL) {
    if kind == .text,
      let editor = NSWorkspace.shared.defaultApplicationURL(forExtension: url.pathExtension)
        ?? NSWorkspace.shared.defaultTextEditor
    {
      NSWorkspace.shared.open(
        [url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
      return
    }
    NSWorkspace.shared.open(url)
  }
}

extension NSWorkspace {
  fileprivate var defaultTextEditor: URL? {
    defaultApplicationURL(forContentType: UTType.plainText.identifier)
  }

  fileprivate func defaultApplicationURL(forContentType contentType: String) -> URL? {
    LSCopyDefaultApplicationURLForContentType(contentType as CFString, .all, nil)?
      .takeRetainedValue() as? URL
  }

  fileprivate func defaultApplicationURL(forExtension ext: String) -> URL? {
    guard let uti = UTType(filenameExtension: ext) else { return nil }
    return defaultApplicationURL(forContentType: uti.identifier)
  }
}
