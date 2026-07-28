import CoreText
import XCTest

@testable import Orbe

/// 独立した 2 本の整合ゲート。どちらもずれても **実行時には何も起きない**ので、ここが唯一の番人になる。
///
/// ⓪①② 層1 の `font-codepoint-map`: 全行がパースできていること・委譲先ファミリ名が実在のフォントへ
/// 解決すること・レンジが `Emoji=Yes` を含まないこと。libghostty は名前解決に失敗すると警告を 1 行ログへ
/// 吐いて委譲を捨て、解決できてもグリフが無ければ `hasCodepoint` が false でログすら無く捨てる
/// （vendor/ghostty `src/font/CodepointResolver.zig` の `getIndexCodepointOverride`）。
/// 画面には「仮名漢字が中華字形に戻る」としか現れない。
///
/// ③ 同梱 TTF: `TerminalFonts` の登録・`build-app.sh` のコピー・`NOTICE` の帰属が一致していること。
/// こちらは本文等幅チェーンと絵文字の話で、上の委譲とは別の鎖。
final class TerminalFontDelegationTests: XCTestCase {

  // MARK: - ⓪ conf 解析の健全性

  /// `font-codepoint-map` 行がすべてパースできていることを検証する。
  /// 下流の検証は「パースできた行」だけを見るので、キー表記の変更や 1 行の記法崩れで対象が静かに
  /// 減ると、レンジの退行を何も見ないまま緑になる。ここで対象の件数そのものを固定する。
  func testEveryCodepointMapLineIsParsed() {
    let declared = text("app/orbe-defaults.conf").split(separator: "\n")
      .filter { $0.hasPrefix("font-codepoint-map") }
    XCTAssertFalse(declared.isEmpty, "app/orbe-defaults.conf に font-codepoint-map 行が無い")
    XCTAssertEqual(
      codepointMapLines().count, declared.count,
      "font-codepoint-map 行にパースできない表記がある（下流の検証が静かに空振りする）")
  }

  // MARK: - ① 委譲先の名前解決

  /// conf が名指す委譲先フォント名が、実際にインストール済みのフォントへ解決することを検証する。
  /// libghostty の discovery と同じ経路（family 名だけの descriptor でコレクションを引く）を踏む。
  /// `Hiragino Sans W3` の綴りを崩すと候補が 0 件になり、委譲が丸ごと無効化する。
  func testDelegationTargetsResolveToInstalledFonts() {
    let lines = codepointMapLines()
    XCTAssertFalse(lines.isEmpty, "委譲行が 1 本も無い")
    let unresolved = lines.map(\.family).filter { matchingDescriptors(family: $0).isEmpty }
    XCTAssertTrue(
      unresolved.isEmpty,
      "委譲先に一致するフォントがシステムに無い（discovery が 0 件を返し委譲が外れる）: \(unresolved)")
  }

  // MARK: - ② 絵文字ベースの切り欠き

  /// 層1 の `font-codepoint-map` が絵文字ベースの codepoint を捕まえていないことを検証する。
  /// libghostty の override は presentation より先に効き（`getIndexCodepointOverride`）検証も `.any` なので、
  /// Emoji=Yes の codepoint をレンジに含めるとモノクロのテキストフォントで確定してしまい、VS16 付き
  /// （`㊗️` `〽️` 等）は後段の emoji 検証で候補が全滅して置換文字に落ちる。画面に出るまで誰も気づけない。
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
    let copied = fontsCopiedIntoBundle()
    XCTAssertFalse(copied.isEmpty, "scripts/build-app.sh から同梱 TTF を 1 つも取れていない")
    let missing = copied.subtracting(attributedFontFileNames()).sorted()
    XCTAssertTrue(missing.isEmpty, "NOTICE に帰属の無い同梱フォント: \(missing)")
  }

  // MARK: - conf の解析

  /// `font-codepoint-map = <ranges>=<family>` 1 行。
  private struct CodepointMapLine {
    let ranges: [ClosedRange<UInt32>]
    let family: String
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

  // MARK: - フォントの解決

  /// libghostty の CoreText discovery（`Descriptor.toCoreTextDescriptor` → FontCollection）と同じ引き方。
  private func matchingDescriptors(family: String) -> [CTFontDescriptor] {
    let descriptor = CTFontDescriptorCreateWithAttributes(
      [kCTFontFamilyNameAttribute: family] as CFDictionary)
    let collection = CTFontCollectionCreateWithFontDescriptors([descriptor] as CFArray, nil)
    return CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] ?? []
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
