import Foundation
import UniformTypeIdentifiers

/// OSC 8 で端末出力が指すリンク。見えている文字列と別の対象を隠せるため、開く前に
/// allow / confirm / block の 3 値で判定する。判定は URL 文字列・ローカル host 名の集合・ファイルシステムの
/// 状態だけから決まる。
///
/// ローカルファイルの危険はファイルの型ではなく Launch Services が選ぶ handler にある（実行ビット付きの
/// `.txt` は Terminal、`.py` は IDLE、`.jnlp` は JavaLauncher、`.fileloc` は中で参照した先に渡る）。
/// だから allow は「開き先」を伴い、Orbe が内容の家族ごとに開き先を決める。家族のどれでもないものは
/// allow に落ちず confirm になる。
struct UntrustedLink: Equatable {
  enum BlockReason: Equatable {
    case malformed
    case unsafeCharacters
    case invalidWeb
    case remoteFile
    case inaccessibleFile
    case unsafeFile
  }

  /// allow の開き先。
  enum Target: Equatable {
    /// URL の既定アプリ（web・mail）。
    case url(URL)
    /// GUI コードエディタ（無ければ plain text の既定アプリ）。実行しない。
    case text(URL)
    /// ファイルの型で引いた既定アプリ（画像・PDF・音声/動画）。
    case typed(URL, UTType)
    /// Finder で表示。
    case folder(URL)
  }

  enum Decision: Equatable {
    /// Orbe が決めた開き先で開く。
    case allow(Target)
    /// 対象と開き先アプリを見せて人が決める。任意のアプリを起動できる scheme と、家族のどれでもないファイル。
    case confirm(URL)
    /// 開かず理由を示す。
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
      return .allow(.url(url))

    case "mailto":
      // 宛先は path に入る。素の `mailto:` でメールアプリに空の要求を送らない。
      guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
        !components.path.isEmpty
      else {
        return .block(.malformed)
      }
      return .allow(.url(url))

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
      normalized = (Self.canonicalFileURL(url) ?? url.standardizedFileURL).path
    } else {
      normalized = raw
    }
    var result = ""
    result.unicodeScalars.reserveCapacity(normalized.unicodeScalars.count)
    for scalar in normalized.unicodeScalars {
      if Self.isUnsafeCharacter(scalar) {
        result += String(format: "\\u{%04X}", scalar.value)
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
    guard let canonical = Self.canonicalFileURL(url) else { return .block(.inaccessibleFile) }
    let values: URLResourceValues
    do {
      values = try canonical.resourceValues(forKeys: [
        .contentTypeKey, .isDirectoryKey, .isPackageKey, .isRegularFileKey,
      ])
    } catch {
      return .block(.inaccessibleFile)
    }
    let isDirectory = values.isDirectory == true
    guard isDirectory || values.isRegularFile == true else { return .block(.inaccessibleFile) }
    return Self.familyDecision(
      canonical, type: values.contentType ?? .data, isDirectory: isDirectory,
      isPackage: values.isPackage == true)
  }

  /// 実在する通常ファイル／ディレクトリを内容の家族に振り分け、開き先を決める。
  private static func familyDecision(
    _ canonical: URL, type: UTType, isDirectory: Bool, isPackage: Bool
  ) -> Decision {
    // 判定順は家族の包含関係で決まる: `.js` は executable にも text にも準拠し、`.svg` は image にも
    // text にも準拠する。実行形式の block より前に中身判定を置くのは、拡張子の無いシェルスクリプトが
    // 実行ビットで unix 実行形式の型になるため（中身がテキストなら編集対象で、実行はしない）。
    if forwardingTypes.contains(where: type.conforms(to:)) { return .block(.unsafeFile) }
    if mediaTypes.contains(where: type.conforms(to:)) { return .allow(.typed(canonical, type)) }
    if type.conforms(to: .text) { return .allow(.text(canonical)) }
    if !isDirectory, hasNoDeclaredType(type) || type.conforms(to: .executable),
      looksLikeText(canonical)
    {
      return .allow(.text(canonical))
    }
    if executableTypes.contains(where: type.conforms(to:)) { return .block(.unsafeFile) }
    if isDirectory, !isPackage { return .allow(.folder(canonical)) }
    return .confirm(canonical)
  }

  /// `..` と symlink を全部畳んだ実体。存在しなければ nil。Foundation の symlink 解決は `/private` を
  /// 剥がして `/tmp`・`/etc` 自身を symlink のまま残すので、realpath(3) で畳む。
  private static func canonicalFileURL(_ url: URL) -> URL? {
    guard let resolved = realpath(url.standardizedFileURL.path, nil) else { return nil }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved))
  }

  /// 中身が別の対象を指す転送ファイル（`.webloc`・`.fileloc`・`.url` 等）。開かない。
  private static let forwardingTypes: [UTType] =
    [.internetLocation, UTType("public.stored-url")].compactMap { $0 }

  /// アプリ・実行形式（`.app`・unix 実行形式・`.dylib`・`.jar`・`.exe` 等）。中身がテキストでない限り開かない。
  private static let executableTypes: [UTType] = [.application, .executable]

  private static let mediaTypes: [UTType] = [.image, .pdf, .audiovisualContent]

  /// macOS が型を知らないファイル（`.zig`・`.rs`・`.env` 等は動的な型、Dockerfile 等の拡張子無しは
  /// 素のデータ型になる）。型が無いので中身で判定する。
  private static func hasNoDeclaredType(_ type: UTType) -> Bool {
    type.isDynamic || type == .data
  }

  private static let sniffLength = 8 * 1024

  /// 先頭 8 KiB が NUL を含まない UTF-8 ならテキストと見なす。
  private static func looksLikeText(_ url: URL) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    let data: Data
    do {
      data = try handle.read(upToCount: sniffLength) ?? Data()
    } catch {
      return false
    }
    guard !data.contains(0) else { return false }
    if data.count < sniffLength { return String(data: data, encoding: .utf8) != nil }
    // 切れ目が多バイト列の途中に当たりうるので、末尾 3 バイトまでは削って読み直す。
    return (0...3).contains { String(data: data.dropLast($0), encoding: .utf8) != nil }
  }

  /// 表示と実体を食い違わせうる scalar。列挙ではなく Unicode の性質で断つ: 一般カテゴリが
  /// Other（制御・書式・私用・未割当・サロゲート）か Separator（U+0020 を除く空白・行・段落区切り）、
  /// または Default_Ignorable（ソフトハイフン・異体字セレクタ・結合書記素接合子・タグ文字等）。
  static func isUnsafeCharacter(_ scalar: Unicode.Scalar) -> Bool {
    if scalar == " " { return false }
    let properties = scalar.properties
    if properties.isDefaultIgnorableCodePoint { return true }
    switch properties.generalCategory {
    case .control, .format, .privateUse, .surrogate, .unassigned,
      .spaceSeparator, .lineSeparator, .paragraphSeparator:
      return true
    default:
      return false
    }
  }
}
