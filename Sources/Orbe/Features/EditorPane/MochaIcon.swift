import AppKit
import SwiftUI

/// ファイル種別アイコン（catppuccin/vscode-icons mocha・MIT。出所と帰属は NOTICE）。
/// dark はオリジナル、light は色を事前計算した mocha-light 変種
/// （見本の CSS filter brightness(0.55) saturate(1.6) を SVG 色へ焼き込んだもの）。
enum MochaIcon {
  /// 拡張子 → アイコン名（必要種のみ。それ以外は汎用 `_file`）。
  static func name(file: String) -> String {
    switch (file as NSString).pathExtension.lowercased() {
    case "swift": return "swift"
    case "md", "markdown": return "markdown"
    case "json": return "json"
    default: return "_file"
    }
  }

  /// フォルダ名 → アイコン名（vscode-icons と同じ既知名マッピング）。
  static func name(folder: String, open: Bool) -> String {
    let base: String
    switch folder.lowercased() {
    case "src", "source", "sources": base = "folder_src"
    case "docs", "doc": base = "folder_docs"
    case "core": base = "folder_core"
    case "test", "tests": base = "folder_tests"
    default: base = "_folder"
    }
    return open ? base + "_open" : base
  }

  private static var cache: [String: NSImage] = [:]

  static func image(named name: String, dark: Bool) -> NSImage? {
    let key = (dark ? "mocha/" : "mocha-light/") + name
    if let cached = cache[key] { return cached }
    guard
      let url = Bundle.module.url(
        forResource: name, withExtension: "svg",
        subdirectory: "icons/\(dark ? "mocha" : "mocha-light")"),
      let image = NSImage(contentsOf: url)
    else { return nil }
    cache[key] = image
    return image
  }
}

/// mocha アイコンの 12×12 表示（FileIcon）。dim は閉じフォルダ等の減光。
struct FileIconView: View {
  let name: String
  var dim = false

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Group {
      if let image = MochaIcon.image(named: name, dark: colorScheme == .dark) {
        Image(nsImage: image)
          .resizable()
          .interpolation(.high)
      } else {
        Color.clear
      }
    }
    .frame(width: 12, height: 12)
    .opacity(dim ? 0.6 : 1)
  }
}
