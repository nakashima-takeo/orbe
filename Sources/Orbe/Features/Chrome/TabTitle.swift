import Foundation

/// タブ名 ③派生の純粋ロジック（UI・AppKit 非依存）。
enum TabTitle {
  /// fish prompt_pwd 純正: 末尾要素はフル、それ以外は頭1文字、隠しdirはドット+1字、深さ上限なし。
  /// 先頭のスラッシュは保持する（チルダは通常要素として頭1字になる）。
  static func compactPath(_ path: String) -> String {
    let absolute = path.hasPrefix("/")
    let comps = path.split(separator: "/").map(String.init)
    guard !comps.isEmpty else { return path }  // 空文字やスラッシュはそのまま
    let last = comps.count - 1
    let parts = comps.enumerated().map { i, c -> String in
      if i == last { return c }  // 末尾はフル
      // 隠しディレクトリはドット+1字。
      if c.hasPrefix("."), c.count > 1 { return String(c.prefix(2)) }
      return String(c.prefix(1))  // それ以外 → 頭1字
    }
    return (absolute ? "/" : "") + parts.joined(separator: "/")
  }

  /// ③派生。圧縮アンカーを root の親に置き、pwd と root の関係で 2 分岐。
  static func derive(pwd: String, root: String?) -> String {
    let p = trimSlash(pwd)
    if let root, !root.isEmpty {
      let r = trimSlash(root)
      // root 以下 → root の親基準（先頭＝root 名）で compact する。
      if p == r || p.hasPrefix(r + "/") {
        let base = (r as NSString).lastPathComponent
        return compactPath(base + p.dropFirst(r.count))
      }
    }
    // root 外 → ~ 基準 absolute を compact
    return compactPath((p as NSString).abbreviatingWithTildeInPath)
  }

  private static func trimSlash(_ s: String) -> String {
    s.count > 1 && s.hasSuffix("/") ? String(s.dropLast()) : s
  }
}
