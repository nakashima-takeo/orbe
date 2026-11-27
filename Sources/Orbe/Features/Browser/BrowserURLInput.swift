import Foundation

/// ツールバーの URL 欄に表示する分解済み URL。ホスト部とパス部を 2 トーンで描き分ける。
struct BrowserDisplayURL: Equatable {
  let host: String
  let path: String
  let isSecure: Bool
  let raw: String
}

/// URL 欄の表示分解と入力正規化（純粋関数）。
enum BrowserURLInput {
  /// HTTP(S) スキームかつ非空ホストを持つナビゲーション可能な URL かを判定する。
  static func isValidHTTPNavigationURL(_ url: URL?) -> Bool {
    guard let url,
      let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      let host = url.host, !host.isEmpty
    else { return false }
    return true
  }

  /// URL をホスト部とパス部へ分解する。`about:blank` 等の空ページは `nil`。
  static func display(_ url: URL?, isSecure: Bool? = nil) -> BrowserDisplayURL? {
    guard let url else { return nil }
    let scheme = url.scheme?.lowercased()
    if scheme == "about" { return nil }
    let resolvedSecure = isSecure ?? (scheme == "https")
    let raw = url.absoluteString
    guard let host = url.host, !host.isEmpty else {
      guard !raw.isEmpty else { return nil }
      return BrowserDisplayURL(
        host: sanitizeForDisplay(raw), path: "", isSecure: resolvedSecure, raw: raw)
    }
    let displayHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    let formattedHost = sanitizeForDisplay(url.port.map { "\(displayHost):\($0)" } ?? displayHost)
    var suffix = url.path == "/" ? "" : sanitizeForDisplay(url.path)
    if let query = url.query, !query.isEmpty {
      suffix += "?\(sanitizeForDisplay(query))"
    }
    if let fragment = url.fragment, !fragment.isEmpty {
      suffix += "#\(sanitizeForDisplay(fragment))"
    }
    return BrowserDisplayURL(
      host: formattedHost, path: suffix, isSecure: resolvedSecure, raw: raw)
  }

  /// URL 表示の並び替えや切り詰めを引き起こす Bidi 書式文字・制御文字・行/段落区切りのみを
  /// UTF-8 バイト単位で再パーセントエンコードし、日本語等の可読パスは維持する。
  static func sanitizeForDisplay(_ text: String) -> String {
    guard text.unicodeScalars.contains(where: requiresDisplayPercentEncoding) else { return text }
    var result = ""
    result.reserveCapacity(text.utf8.count)
    for scalar in text.unicodeScalars {
      if requiresDisplayPercentEncoding(scalar) {
        for byte in scalar.utf8 {
          result.append("%")
          result.append(hexDigits[Int(byte >> 4)])
          result.append(hexDigits[Int(byte & 0x0F)])
        }
      } else {
        result.unicodeScalars.append(scalar)
      }
    }
    return result
  }

  private static func requiresDisplayPercentEncoding(_ scalar: Unicode.Scalar) -> Bool {
    let properties = scalar.properties
    if properties.isBidiControl { return true }
    switch properties.generalCategory {
    case .control, .lineSeparator, .paragraphSeparator:
      return true
    default:
      return false
    }
  }

  private static let hexDigits: [Character] = Array("0123456789ABCDEF")

  /// 利用者が入力した文字列を HTTP(S) URL へ正規化する。
  /// 非 HTTP(S) スキームや空白を含む語句など URL にならない文字列は `nil` を返す。
  static func resolve(_ raw: String) -> URL? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }

    let lower = trimmed.lowercased()
    if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
      return validatedHTTPURL(from: trimmed)
    }
    if trimmed.contains("://") {
      return nil
    }
    if hasNonHTTPColonScheme(trimmed) {
      return nil
    }
    guard let scheme = inferredScheme(for: trimmed) else { return nil }
    return validatedHTTPURL(from: "\(scheme)://\(trimmed)")
  }

  private static func validatedHTTPURL(from string: String) -> URL? {
    guard let components = URLComponents(string: string),
      let scheme = components.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      let host = components.host, !host.isEmpty,
      let url = components.url
    else { return nil }
    return url
  }

  /// `javascript:` / `file:` / `data:` 等のスキーム接頭辞を持つかを判定する（`host:port` は除外）。
  private static func hasNonHTTPColonScheme(_ input: String) -> Bool {
    guard !input.hasPrefix("[") else { return false }
    let authority = authorityPrefix(of: input)
    guard let colon = authority.firstIndex(of: ":") else { return false }
    let before = authority[..<colon]
    let after = authority[authority.index(after: colon)...]
    if isValidPort(after) { return false }
    return isSchemeSyntax(before)
  }

  /// スキーム省略時の補完スキームを判定する。URL と見なせない裸語は `nil`。
  private static func inferredScheme(for input: String) -> String? {
    let authority = authorityPrefix(of: input)
    guard !authority.isEmpty else { return nil }

    if authority.hasPrefix("[") {
      guard let close = authority.firstIndex(of: "]") else { return nil }
      let rest = authority[authority.index(after: close)...]
      if !rest.isEmpty {
        guard rest.hasPrefix(":"), isValidPort(rest.dropFirst()) else { return nil }
      }
      return "http"
    }

    let host: Substring
    let hasExplicitPort: Bool
    if let colon = authority.firstIndex(of: ":") {
      host = authority[..<colon]
      let portPart = authority[authority.index(after: colon)...]
      guard isValidPort(portPart) else { return nil }
      hasExplicitPort = true
    } else {
      host = authority
      hasExplicitPort = false
    }

    guard !host.isEmpty, !host.hasPrefix("."), !host.hasSuffix("."), !host.contains("..") else {
      return nil
    }
    let lowerHost = host.lowercased()
    if hasExplicitPort || lowerHost == "localhost" || lowerHost == "127.0.0.1"
      || lowerHost.hasSuffix(".local") || isIPv4(lowerHost)
    {
      return "http"
    }
    return lowerHost.contains(".") ? "https" : nil
  }

  private static func authorityPrefix(of input: String) -> Substring {
    let stop = input.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? input.endIndex
    return input[..<stop]
  }

  private static func isValidPort(_ text: Substring) -> Bool {
    guard !text.isEmpty, text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber),
      let port = Int(text), (1...65535).contains(port)
    else { return false }
    return true
  }

  private static func isSchemeSyntax(_ text: Substring) -> Bool {
    guard let first = text.first, first.isASCII, first.isLetter else { return false }
    return text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }
  }

  private static func isIPv4(_ host: String) -> Bool {
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return false }
    return parts.allSatisfy { part in
      !part.isEmpty && part.allSatisfy(\.isASCII) && part.allSatisfy(\.isNumber)
        && (0...255).contains(Int(part) ?? -1)
    }
  }
}
