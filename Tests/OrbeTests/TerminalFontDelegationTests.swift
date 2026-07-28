import CoreText
import XCTest

@testable import Orbe

/// 層1 の `font-codepoint-map` と、同梱フォントのビルド・帰属の整合ゲート。
/// 同じ事実が `orbe-defaults.conf` の委譲先名・システムに実在するファミリ名・`TerminalFonts` の登録・
/// `build-app.sh` のコピー・`NOTICE` の帰属という独立した箇所に埋まっており、どれか 1 つがずれても
/// **実行時には何も起きない**。libghostty は委譲先の名前解決に失敗すると警告を 1 行ログへ吐いて委譲を捨て、
/// 解決できても委譲先にグリフが無ければ `hasCodepoint` が false でログすら無く捨てる
/// （vendor/ghostty `src/font/CodepointResolver.zig` の `getIndexCodepointOverride`）。
/// 画面には「囲み文字が元の小さい欧文字形に戻る」としか現れず、誰も気づけない。ここがその唯一の番人。
final class TerminalFontDelegationTests: XCTestCase {

  /// ① — 記号委譲を導入した動機そのもので、記号委譲行を引くときの錨に使う。
  private let circledOne: UInt32 = 0x2460

  /// 計測の基準サイズ。`orbe-defaults.conf` の `font-size = 12` に合わせる。
  private let referenceSize: CGFloat = 12

  /// libghostty が「記号らしい」と見なし `.fit` 制約でセル枠に収めるブロック
  /// （vendor/ghostty `src/build/uucode_config.zig` の `computeIsSymbol` を写したもの）。
  private let symbolBlocks: [ClosedRange<UInt32>] = [
    0x2190...0x21FF,  // Arrows
    0x2460...0x24FF,  // Enclosed Alphanumerics
    0x2600...0x26FF,  // Miscellaneous Symbols
    0x2700...0x27BF,  // Dingbats
    0xE000...0xF8FF,  // Private Use Area（general_category == other_private_use）
    0x1F100...0x1F1FF,  // Enclosed Alphanumeric Supplement
    0x1F300...0x1F5FF,  // Miscellaneous Symbols and Pictographs
    0x1F600...0x1F64F,  // Emoticons
    0x1F680...0x1F6FF,  // Transport and Map Symbols
    0xF0000...0xFFFFD,  // Supplementary Private Use Area-A
    0x100000...0x10FFFD,  // Supplementary Private Use Area-B
  ]

  // MARK: - ① 記号委譲レンジの必要条件

  /// 記号委譲行のレンジが `isSymbol` ブロックの中だけに収まっていることを検証する。
  /// 委譲先の Hiragino Sans W3 は全角字形しか持たないので、`.fit` 制約が掛からない
  /// 非 isSymbol の点を足すと、インク幅 9.5〜12.2pt の字形が 7.2pt のセルから隣へはみ出す
  /// （`※`(U+203B)・`●■▲◆`(U+25A0-25FF)・`⌘`(U+2318) がこれに当たる）。
  /// 制約の有無はレンダラ内部の分岐でしかなく、画面にしか現れない無言の破綻になる。
  func testSymbolDelegationStaysWithinSymbolBlocks() throws {
    let line = try symbolDelegationLine()
    let offenders = line.ranges.flatMap { Array($0) }
      .filter { codepoint in !symbolBlocks.contains { $0.contains(codepoint) } }
    XCTAssertTrue(
      offenders.isEmpty,
      "isSymbol ブロックの外を `\(line.family)` へ委譲している"
        + "（.fit が働かず全角字形が隣セルへはみ出す）: \(offenders.map(describe))")
  }

  // MARK: - ② 委譲先の名前解決

  /// conf が名指す委譲先フォント名が、実際にインストール済みのフォントへ解決することを検証する。
  /// libghostty の discovery と同じ経路（family 名だけの descriptor でコレクションを引く）を踏む。
  /// `Hiragino Sans W3` の綴りを崩すと候補が 0 件になり、委譲が丸ごと無効化する。
  func testSymbolDelegationTargetResolvesToAnInstalledFont() throws {
    let family = try symbolDelegationLine().family
    XCTAssertFalse(
      matchingDescriptors(family: family).isEmpty,
      "委譲先 `\(family)` に一致するフォントがシステムに無い（discovery が 0 件を返す）")
  }

  /// 委譲を導入する動機になった字形が、レンジに残っていて委譲先にグリフもあることを検証する。
  /// レンジを**狭めた**側と、委譲先が字形を落とした側は、どちらも見た目が元に戻るだけで無症状。
  /// 代表点を押さえるのがその唯一の検出手段になる。
  func testDelegationCoversTheGlyphsItWasIntroducedFor() throws {
    let line = try symbolDelegationLine()
    let font = try delegateFont(family: line.family)
    let representatives: [UInt32] = [
      0x2460, 0x2473, 0x24B6, 0x24D0, 0x24EA, 0x2605, 0x2606, 0x266A, 0x266B,
    ]
    let dropped = representatives.filter { codepoint in
      !line.covers(codepoint) || glyph(for: codepoint, in: font) == nil
    }
    XCTAssertTrue(
      dropped.isEmpty,
      "委譲レンジから外れているか `\(line.family)` にグリフが無い: \(dropped.map(describe))")
  }

  // MARK: - ③ 登録 × 同梱 × 帰属

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

  // MARK: - ④ 絵文字ベースの切り欠き

  /// 層1 の `font-codepoint-map` が絵文字ベースの codepoint を捕まえていないことを検証する。
  /// libghostty の override は presentation より先に効き（`getIndexCodepointOverride`）検証も `.any` なので、
  /// Emoji=Yes の codepoint をレンジに含めるとモノクロのテキストフォントで確定してしまい、VS16 付き
  /// （`Ⓜ️` `⚠️` `㊗️` 等）は後段の emoji 検証で候補が全滅して置換文字に落ちる。画面に出るまで誰も気づけない。
  /// レンジに開いている穴はすべてこの切り欠きなので、埋めようとするとここで落ちる。
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

  /// ghostty の `CodepointMap.get`（逆走査＝後勝ち）と同じ順序で ① を覆う行を引く。
  private func symbolDelegationLine() throws -> CodepointMapLine {
    try XCTUnwrap(
      codepointMapLines().last { $0.covers(circledOne) },
      "app/orbe-defaults.conf に \(describe(circledOne)) を委譲する font-codepoint-map 行が無い")
  }

  // MARK: - フォントの解決と実測

  /// libghostty の CoreText discovery（`Descriptor.toCoreTextDescriptor` → FontCollection）と同じ引き方。
  private func matchingDescriptors(family: String) -> [CTFontDescriptor] {
    let descriptor = CTFontDescriptorCreateWithAttributes(
      [kCTFontFamilyNameAttribute: family] as CFDictionary)
    let collection = CTFontCollectionCreateWithFontDescriptors([descriptor] as CFArray, nil)
    return CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] ?? []
  }

  private func delegateFont(family: String) throws -> CTFont {
    let descriptor = try XCTUnwrap(
      matchingDescriptors(family: family).first,
      "委譲先 `\(family)` に一致するフォントがシステムに無い")
    return CTFontCreateWithFontDescriptor(descriptor, referenceSize, nil)
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
