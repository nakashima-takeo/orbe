import CoreText
import XCTest

@testable import Orbe

/// 同梱フォントと、それを名指す設定・ビルド・帰属の整合ゲート。
/// 同じ事実が `app/*.ttf` の name table・`orbe-defaults.conf` の委譲先名・`TerminalFonts` の登録・
/// `build-app.sh` のコピー・`NOTICE` の帰属という独立した 5 箇所に埋まっており、どれか 1 つがずれても
/// **実行時には何も起きない**。libghostty は委譲先の名前解決に失敗すると警告を 1 行ログへ吐いて委譲を捨て、
/// 解決できても委譲先にグリフが無ければ `hasCodepoint` が false でログすら無く捨てる
/// （vendor/ghostty `src/font/CodepointResolver.zig` の `getIndexCodepointOverride`）。
/// 画面には「囲み文字が元の小さい字形に戻る」としか現れず、誰も気づけない。ここがその唯一の番人。
final class TerminalFontDelegationTests: XCTestCase {

  /// ① — 委譲を導入した動機そのもので、委譲行を引くときの錨に使う。
  private let circledOne: UInt32 = 0x2460

  /// 計測の基準サイズ。`orbe-defaults.conf` の `font-size = 12` に合わせる（比較は同一フォント内なので
  /// 値自体には依存しない）。
  private let referenceSize: CGFloat = 12

  // MARK: - ① 委譲先の名前解決

  /// conf が名指す委譲先フォント名が、同梱 TTF のファミリ名に解決することを検証する。
  /// conf の文字列と TTF の name table は独立に埋まるため、どちらかを改名すると discovery が
  /// 名前を引けず委譲が丸ごと無効化する（画面上は元の小さい字形に戻るだけ）。
  func testDelegationTargetResolvesToBundledFontFamily() throws {
    let target = try XCTUnwrap(
      delegationTarget(for: circledOne),
      "app/orbe-defaults.conf に \(describe(circledOne)) を委譲する font-codepoint-map 行が無い")
    let bundled = bundledFontFamilies()
    XCTAssertNotNil(
      bundled[target],
      "委譲先 `\(target)` に一致するファミリ名の TTF が app/ に無い（同梱: \(bundled.keys.sorted())）")
  }

  // MARK: - ② 登録 × 同梱 × 帰属

  /// 起動時に `.process` 登録するフォント集合と、`.app` へ同梱するフォント集合が一致することを検証する。
  /// 登録だけ足すとファイルが無く、同梱だけ足すと名前解決の対象にならない。どちらも無警告で効かない。
  func testRegisteredFontsMatchBundleCopies() {
    XCTAssertEqual(
      Set(TerminalFonts.bundledResources), fontsCopiedIntoBundle(),
      "TerminalFonts.bundledResources と build-app.sh のコピー集合がずれている"
        + "（登録漏れ＝名前解決に失敗／同梱漏れ＝ファイルが無い。どちらも実行時は無警告）")
  }

  /// 同梱する各 TTF が `NOTICE` に帰属されていることを検証する。
  /// 帰属漏れは動作に一切現れないが、OFL-1.1 の要求を満たさないまま出荷することになる。
  func testBundledFontsAreAttributedInNotice() {
    let missing = fontsCopiedIntoBundle().subtracting(attributedFontFileNames()).sorted()
    XCTAssertTrue(missing.isEmpty, "NOTICE に帰属の無い同梱フォント: \(missing)")
  }

  // MARK: - ③ 委譲レンジ

  /// 委譲する全 codepoint が委譲先フォントにグリフを持つことを検証する。
  /// 持たない codepoint は libghostty の `hasCodepoint` 検証で落ち、ログも無く委譲が外れる。
  func testDelegatedCodepointsHaveGlyphsInDelegateFont() throws {
    let delegate = try delegateFont()
    let missing = delegatedCodepoints(to: delegate.family)
      .filter { glyph(for: $0, in: delegate.font) == nil }
    XCTAssertTrue(
      missing.isEmpty,
      "\(delegate.family) にグリフが無い codepoint を委譲している: \(missing.map(describe))")
  }

  /// 委譲する全 codepoint が半角 advance で存在することを検証する。
  /// これは委譲レンジの必要条件——全角字形を 1 セル幅で委譲すると、libghostty の
  /// `.fit` 制約がセル幅に潰すか、制約が掛からず隣セルへはみ出すかの二択になり必ず壊れる。
  /// レンジを ⒑（U+2491・全角）や CJK 側へ広げる書き間違いはここで落ちる。
  func testDelegatedCodepointsAreHalfWidthInDelegateFont() throws {
    let delegate = try delegateFont()
    let halfWidth = try XCTUnwrap(
      glyph(for: 0x41, in: delegate.font).map { advance(of: $0, in: delegate.font) },
      "\(delegate.family) に半角の基準となる `A` が無い")
    let offenders = delegatedCodepoints(to: delegate.family).compactMap { codepoint -> String? in
      // グリフ欠落は testDelegatedCodepointsHaveGlyphsInDelegateFont の担当なのでここでは見ない。
      guard let glyph = glyph(for: codepoint, in: delegate.font) else { return nil }
      let width = advance(of: glyph, in: delegate.font)
      // 浮動小数の等値比較を避ける下駄。0.01pt は 12pt/1000upem で 0.83 units 相当＝1 unit 差でも落ちる。
      guard abs(width - halfWidth) > 0.01 else { return nil }
      return "\(describe(codepoint)) advance=\(width)"
    }
    XCTAssertTrue(
      offenders.isEmpty,
      "半角 advance(\(halfWidth)) でない字形を委譲している: \(offenders)")
  }

  /// 委譲を導入する動機になった字形が、委譲対象に残っていることを検証する。
  /// グリフ有無と半角 advance の 2 本はレンジを**広げた**ときしか落ちない。狭めた側は見た目が元に戻る
  /// だけで無症状なので、代表点を対で押さえる（`※` `①` `⑳` `⑴` `⒇` `⒈` `⒐` `⒜` `⒵` `★` `☆`）。
  func testDelegationCoversTheGlyphsItWasIntroducedFor() throws {
    let delegate = try delegateFont()
    let delegated = Set(delegatedCodepoints(to: delegate.family))
    let representatives: [UInt32] = [
      0x203B, 0x2460, 0x2473, 0x2474, 0x2487, 0x2488, 0x2490, 0x249C, 0x24B5, 0x2605, 0x2606,
    ]
    let dropped = representatives.filter { !delegated.contains($0) }
    XCTAssertTrue(
      dropped.isEmpty, "委譲レンジから外れている: \(dropped.map(describe))")
  }

  /// 層1 の `font-codepoint-map` が絵文字ベースの codepoint を捕まえていないことを検証する。
  /// libghostty の override は presentation より先に効き（`getIndexCodepointOverride`）検証も `.any` なので、
  /// Emoji=Yes の codepoint をレンジに含めるとモノクロのテキストフォントで確定してしまい、VS16 付き
  /// （`㊗️` 等）は後段の emoji 検証で候補が全滅して置換文字に落ちる。画面に出るまで誰も気づけない。
  func testLayerOneCodepointMapsExcludeEmojiBases() {
    let offenders = codepointMapLines().flatMap { line in
      line.ranges.flatMap { Array($0) }
        .filter { UnicodeScalar($0)?.properties.isEmoji == true }
        .map { "\(describe($0)) → \(line.family)" }
    }
    XCTAssertTrue(
      offenders.isEmpty,
      "絵文字ベースの codepoint を層1 の font-codepoint-map が捕まえている"
        + "（VS16 付きが置換文字になる）: \(offenders)")
  }

  // MARK: - conf の解析

  /// `font-codepoint-map = <ranges>=<family>` 1 行。
  private struct CodepointMapLine {
    let ranges: [ClosedRange<UInt32>]
    let family: String

    func covers(_ codepoint: UInt32) -> Bool { ranges.contains { $0.contains(codepoint) } }
  }

  private func codepointMapLines() -> [CodepointMapLine] {
    let key = "font-codepoint-map = "
    return text("app/orbe-defaults.conf").split(separator: "\n").compactMap { line in
      guard line.hasPrefix(key) else { return nil }
      let value = line.dropFirst(key.count)
      guard let separator = value.lastIndex(of: "=") else { return nil }
      let tokens = value[..<separator].split(separator: ",")
      let ranges = tokens.compactMap(parseRange)
      let family = value[value.index(after: separator)...].trimmingCharacters(in: .whitespaces)
      // 1 つでも表記が壊れていれば行ごと落とす。下流は「委譲行が無い」として失敗する。
      guard ranges.count == tokens.count, !ranges.isEmpty, !family.isEmpty else { return nil }
      return CodepointMapLine(ranges: ranges, family: family)
    }
  }

  /// `U+2460` / `U+2460-U+2473` を閉区間へ。
  private func parseRange(_ token: Substring) -> ClosedRange<UInt32>? {
    let ends = token.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
    let values = ends.compactMap { $0.hasPrefix("U+") ? UInt32($0.dropFirst(2), radix: 16) : nil }
    guard values.count == ends.count, let low = values.first, let high = values.last, low <= high
    else { return nil }
    return low...high
  }

  /// ghostty の `CodepointMap.get`（逆走査＝後勝ち）と同じ順序で委譲先を引く。
  private func delegationTarget(for codepoint: UInt32) -> String? {
    codepointMapLines().last { $0.covers(codepoint) }?.family
  }

  /// 同じフォントへ委譲している全行の codepoint（行を分割しても同じ集合になる）。
  private func delegatedCodepoints(to family: String) -> [UInt32] {
    codepointMapLines().filter { $0.family == family }
      .flatMap(\.ranges).flatMap { Array($0) }.sorted()
  }

  // MARK: - フォントの実測

  /// conf が名指した名前から同梱 TTF を解決してロードする。
  private func delegateFont() throws -> (font: CTFont, family: String) {
    let family = try XCTUnwrap(
      delegationTarget(for: circledOne),
      "app/orbe-defaults.conf に \(describe(circledOne)) を委譲する font-codepoint-map 行が無い")
    let url = try XCTUnwrap(
      bundledFontFamilies()[family], "委譲先 `\(family)` に一致する TTF が app/ に無い")
    let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]
    let descriptor = try XCTUnwrap(descriptors?.first, "\(url.lastPathComponent) を読めない")
    return (CTFontCreateWithFontDescriptor(descriptor, referenceSize, nil), family)
  }

  /// `app/*.ttf` のファミリ名（name table 由来）→ ファイル URL。
  private func bundledFontFamilies() -> [String: URL] {
    let appDir = repoRoot().appendingPathComponent("app")
    let urls =
      (try? FileManager.default.contentsOfDirectory(at: appDir, includingPropertiesForKeys: nil))
      ?? []
    var families: [String: URL] = [:]
    for url in urls where url.pathExtension == "ttf" {
      let descriptors =
        CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]
      guard let descriptor = descriptors?.first,
        let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute)
          as? String
      else { continue }
      families[family] = url
    }
    return families
  }

  private func glyph(for codepoint: UInt32, in font: CTFont) -> CGGlyph? {
    guard let scalar = UnicodeScalar(codepoint) else { return nil }
    var utf16 = Array(String(scalar).utf16)
    var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
    // 戻り値は「全単位が引けたか」で、サロゲートペアでは false になる。先頭グリフの有無で判定する。
    _ = CTFontGetGlyphsForCharacters(font, &utf16, &glyphs, utf16.count)
    guard let first = glyphs.first, first != 0 else { return nil }
    return first
  }

  private func advance(of glyph: CGGlyph, in font: CTFont) -> CGFloat {
    var glyphs = [glyph]
    var advances = [CGSize.zero]
    _ = CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &advances, 1)
    return advances[0].width
  }

  // MARK: - リポジトリ実ファイルの読み

  /// `build-app.sh` が `Contents/Resources/<name>.ttf` へコピーする basename 集合。
  private func fontsCopiedIntoBundle() -> Set<String> {
    let matches = regexMatches(
      #"Contents/Resources/([A-Za-z0-9._-]+)\.ttf"#, in: text("scripts/build-app.sh"))
    return Set(matches.map { $0[1] })
  }

  /// `NOTICE` が帰属している TTF ファイル名。`Foo-{Regular,Bold}.ttf` の列記表現も展開して数える。
  private func attributedFontFileNames() -> Set<String> {
    let notice = text("NOTICE")
    var names = Set(regexMatches(#"([A-Za-z0-9._-]+)\.ttf"#, in: notice).map { $0[1] })
    for match in regexMatches(#"([A-Za-z0-9._-]*)\{([^}]*)\}([A-Za-z0-9._-]*)\.ttf"#, in: notice) {
      for style in match[2].split(separator: ",") { names.insert(match[1] + style + match[3]) }
    }
    return names
  }

  /// 全マッチをキャプチャグループの配列（`[0]` は全体）として返す。
  private func regexMatches(_ pattern: String, in text: String) -> [[String]] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let whole = NSRange(text.startIndex..., in: text)
    return regex.matches(in: text, range: whole).map { match in
      (0..<match.numberOfRanges).map { index in
        Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
      }
    }
  }

  private func text(_ relativePath: String) -> String {
    let url = repoRoot().appendingPathComponent(relativePath)
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
  }

  /// このファイル: <repo>/Tests/OrbeTests/...swift → 3 階層上が repo root。
  private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  }

  private func describe(_ codepoint: UInt32) -> String {
    let scalar = UnicodeScalar(codepoint).map(String.init) ?? "?"
    return String(format: "U+%04X %@", codepoint, scalar)
  }
}
