import SwiftUI

/// タブ・閉じたタブの表示タイトル・短縮ラベル・モノグラム 1 文字・チップ配色を決定論的に導く。
enum BrowserTabDisplay {
  /// Bidi 書式文字・制御文字を無害化し、改行・タブ・行/段落区切りを半角スペースへ畳んで前後トリムする。
  static func sanitizeTitle(_ raw: String) -> String {
    var result = ""
    result.reserveCapacity(raw.utf8.count)
    for scalar in raw.unicodeScalars {
      let properties = scalar.properties
      if properties.isBidiControl { continue }
      switch properties.generalCategory {
      case .lineSeparator, .paragraphSeparator:
        result.append(" ")
      case .control:
        if scalar == "\n" || scalar == "\r" || scalar == "\t" {
          result.append(" ")
        }
      default:
        result.unicodeScalars.append(scalar)
      }
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func title(url: URL?, title: String, fallback: String) -> String {
    let cleaned = sanitizeTitle(title)
    if !cleaned.isEmpty { return cleaned }
    if let host = BrowserURLInput.display(url)?.host, !host.isEmpty { return host }
    return fallback
  }

  static func shortLabel(url: URL?, title: String, fallback: String) -> String {
    let cleaned = sanitizeTitle(title)
    if !cleaned.isEmpty { return cleaned }
    return strippedHost(for: url) ?? fallback
  }

  static func monogram(url: URL?, title: String) -> String? {
    if let host = strippedHost(for: url), let first = host.first {
      return String(first).uppercased()
    }
    let cleaned = sanitizeTitle(title)
    return cleaned.first.map { String($0).uppercased() }
  }

  static func localBadgeLetter(workspaceName: String) -> String {
    let cleaned = sanitizeTitle(workspaceName)
    return cleaned.first.map { String($0).uppercased() } ?? "O"
  }

  /// プロセス再起動をまたいでも同じ色になるよう FNV-1a でホストから決定論的に色を選ぶ。
  static func chipTint(url: URL?, title: String) -> Color? {
    let seed = strippedHost(for: url) ?? sanitizeTitle(title)
    guard !seed.isEmpty else { return nil }
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in seed.lowercased().utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    let colors: [Color?] = [
      nil, Color.theme.browserProfileBlue, Color.theme.browserProfileTeal,
      Color.theme.browserProfilePurple, Color.theme.browserProfileAmber,
      Color.theme.browserProfilePink, Color.theme.browserProfileGreen,
    ]
    return colors[Int(hash % UInt64(colors.count))]
  }

  private static func strippedHost(for url: URL?) -> String? {
    guard let rawHost = url?.host?.lowercased(), !rawHost.isEmpty else { return nil }
    let sanitized = BrowserURLInput.sanitizeForDisplay(rawHost)
    return sanitized.hasPrefix("www.") && sanitized.count > 4
      ? String(sanitized.dropFirst(4)) : sanitized
  }
}
