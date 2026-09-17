import Foundation
import UniformTypeIdentifiers

/// OSC 8 で端末出力が指すリンク。見えている文字列と別の対象を隠せるため、Launch Services へ渡す前に
/// allow / confirm / block の 3 値で判定する。判定は URL 文字列・ローカル host 名の集合・ファイルシステムの
/// 状態だけから決まる。
struct UntrustedLink: Equatable {
  enum BlockReason: Equatable {
    case malformed
    case unsafeCharacters
    case invalidWeb
    case remoteFile
    case inaccessibleFile
    case unsafeFile
  }

  enum Decision: Equatable {
    /// 実行を伴わず挙動が定まっている scheme。そのまま開く。
    case allow(URL)
    /// 独自 scheme。登録アプリを何でも起動できるので、対象と開き先を見せて人が決める。
    case confirm(URL)
    /// 不正形式・実行されうるローカルファイル等。開かない。
    case block(BlockReason)
  }

  let raw: String
  /// `file://` の host としてこのマシンを指すと認める名前（小文字）。空 host と `localhost` を常に含む。
  let localHosts: Set<String>

  init(_ raw: String, localHosts: Set<String> = Self.machineHostNames()) {
    self.raw = raw
    self.localHosts = Set(localHosts.map { $0.lowercased() }).union(["", "localhost"])
  }

  /// coreutils `ls`・ripgrep・fd・cargo は `file://<gethostname()>/path` を出すので、このマシンが名乗る
  /// 名前をすべてローカルと認める。
  static func machineHostNames() -> Set<String> {
    Set([ProcessInfo.processInfo.hostName] + Host.current().names)
  }

  var decision: Decision {
    guard !raw.isEmpty else { return .block(.malformed) }

    // Foundation は制御・書式文字を URL として受け入れるが、UI はそれを改行・不可視・方向反転として
    // 描く。表示と実体が食い違う手口はパースの前に断つ。
    guard !raw.unicodeScalars.contains(where: Self.isUnsafeCharacter) else {
      return .block(.unsafeCharacters)
    }

    // `URL(string:)` は相対参照も受け入れる。後段が base に対して勝手に解決しないよう scheme を要求する。
    guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
      return .block(.malformed)
    }

    switch scheme {
    case "http", "https":
      // `https:relative` のような authority 無しは消費者ごとに解決が変わる。
      guard let host = url.host, !host.isEmpty else { return .block(.invalidWeb) }
      return .allow(url)

    case "mailto":
      // 宛先は path に入る。素の `mailto:` でメールアプリに空の要求を送らない。
      guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
        !components.path.isEmpty
      else {
        return .block(.malformed)
      }
      return .allow(url)

    case "file":
      return fileDecision(url)

    default:
      return .confirm(url)
    }
  }

  /// 表示用の 1 行文字列。`file` は開く対象（`..`・symlink 解決後のパス）、それ以外は元の文字列で、
  /// 不可視文字は `\u{XXXX}` に可視化する。Orbe はリンクのホバー表示を持たないので、これが真の対象を
  /// 人に見せる唯一の場所。
  var displayString: String {
    let normalized: String
    if let url = URL(string: raw), url.isFileURL {
      normalized = url.standardizedFileURL.resolvingSymlinksInPath().path
    } else {
      normalized = raw
    }
    var result = ""
    result.unicodeScalars.reserveCapacity(normalized.unicodeScalars.count)
    for scalar in normalized.unicodeScalars {
      if Self.isUnsafeCharacter(scalar) {
        result += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
      } else {
        result.unicodeScalars.append(scalar)
      }
    }
    return result
  }

  private func fileDecision(_ url: URL) -> Decision {
    // query/fragment はファイルシステム上の対象を指さず、ハンドラごとに解釈が揺れる。
    guard url.isFileURL, url.query == nil, url.fragment == nil else { return .block(.malformed) }
    guard localHosts.contains((url.host ?? "").lowercased()) else { return .block(.remoteFile) }

    // 端末出力の綴りではなく実体で判定する。`..` と symlink を畳み、無害そうな名前の裏の実行ファイルを
    // 見逃さない。
    let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
    let values: URLResourceValues
    do {
      values = try canonical.resourceValues(forKeys: [
        .contentTypeKey, .isDirectoryKey, .isExecutableKey, .isRegularFileKey,
      ])
    } catch {
      return .block(.inaccessibleFile)
    }
    guard values.isDirectory == true || values.isRegularFile == true else {
      return .block(.inaccessibleFile)
    }
    guard !Self.isUnsafeFile(canonical, values) else { return .block(.unsafeFile) }
    return .allow(canonical)
  }

  private static func isUnsafeFile(_ url: URL, _ values: URLResourceValues) -> Bool {
    // Launch Services は拡張子でハンドラを選ぶので、実行ビットが無くても実行されうる容器を拡張子で弾く。
    if unsafePathExtensions.contains(url.pathExtension.lowercased()) { return true }
    // 拡張子が無い・偽っているファイルは UTI で。system 宣言の広い型を使い、シェルスクリプトや
    // アプリバンドルの下位型を自動で含める。
    if let type = values.contentType, unsafeContentTypes.contains(where: type.conforms(to:)) {
      return true
    }
    return values.isDirectory != true && values.isExecutable == true
  }

  static func isUnsafeCharacter(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x00...0x1F, 0x7F...0x9F:  // C0/C1 制御（CR・LF・NEL を含む）
      return true
    case 0x061C, 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069:  // 方向制御・ゼロ幅
      return true
    case 0x2028...0x2029:  // 行・段落区切り
      return true
    case 0x2060, 0xFEFF:  // Word Joiner・BOM
      return true
    default:
      return false
    }
  }

  static let unsafePathExtensions: Set<String> = [
    "action", "app", "applescript", "class", "command", "desktop", "inetloc", "jar",
    "mobileconfig", "mpkg", "pkg", "scpt", "terminal", "tool", "url", "webloc", "workflow",
  ]

  static let unsafeContentTypes: [UTType] = [.application, .executable, .script]
}
