import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// 見え方の唯一の決定点——8 役割すべてに互いに違う色が付き、その色が外観（dark / light）で解き直されること。
///
/// 壊れると何が起きるか。役割の色が欠けるとその役割は素の文字色で描かれ（keyword と変数が同じ色になる）、
/// 色が静的だと light に切り替えたときコードだけ dark の配色のまま残る。
@MainActor
final class EditorStyleTests: OrbeTestCase {
  private func resolved(_ color: NSColor, _ appearance: NSAppearance.Name) -> NSColor? {
    var result: NSColor?
    NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
      result = color.usingColorSpace(.sRGB)
    }
    return result
  }

  /// 装備の色——印の 3 色は diff トークンの α .85、丸点は text.muted の .55——で、どれも外観で解き直される。
  func testMarkAndDecorationColorsCarryTheSampleAlphasAndFollowTheAppearance() throws {
    let style = EditorStyle.make()
    let marks = [
      (style.marks.added, Theme.Color.diffAdded), (style.marks.modified, Theme.Color.diffModified),
      (style.marks.removed, Theme.Color.diffRemoved),
    ]
    for (mark, token) in marks {
      for appearance in [NSAppearance.Name.darkAqua, .aqua] {
        let resolved = try XCTUnwrap(self.resolved(mark, appearance))
        let base = try XCTUnwrap(self.resolved(token, appearance))
        XCTAssertEqual(resolved.alphaComponent, 0.85, accuracy: 0.01)
        XCTAssertEqual(resolved.redComponent, base.redComponent, accuracy: 0.002)
        XCTAssertEqual(resolved.greenComponent, base.greenComponent, accuracy: 0.002)
        XCTAssertEqual(resolved.blueComponent, base.blueComponent, accuracy: 0.002)
      }
      XCTAssertNotEqual(
        try XCTUnwrap(resolved(mark, .darkAqua)), try XCTUnwrap(resolved(mark, .aqua)))
    }
    XCTAssertEqual(
      try XCTUnwrap(resolved(style.decorations.whitespaceColor, .darkAqua)).alphaComponent, 0.55,
      accuracy: 0.01)
  }

  /// git の 3 色は互いに違い、成否の緑（success）・赤（danger）のどれとも違う。
  ///
  /// 壊れると何が起きるか。git の色が成否の色の別名に戻ると、追加と削除が赤と緑だけで分かれ、赤と緑を見分けにくい人には
  /// ガター・印・バッジの区別が消える。逆に成否の色を git の色に寄せると、成功の ✓ とエラーの文まで青とオレンジになる。
  func testGitColorsAreDistinctFromEachOtherAndFromSuccessAndDanger() throws {
    let git = [Theme.Color.diffAdded, Theme.Color.diffModified, Theme.Color.diffRemoved]
    let outcome = [Theme.Color.success, Theme.Color.danger]
    for appearance in [NSAppearance.Name.darkAqua, .aqua] {
      let gitValues = try git.map { "\(try XCTUnwrap(resolved($0, appearance)))" }
      let outcomeValues = try outcome.map { "\(try XCTUnwrap(resolved($0, appearance)))" }
      XCTAssertEqual(Set(gitValues).count, git.count, "\(appearance) で追加・変更・削除が同じ色")
      XCTAssertTrue(
        Set(gitValues).isDisjoint(with: outcomeValues), "\(appearance) で git の色が成否の色と同じ")
    }
  }

  /// 8 役割すべてに色があり、同じ外観の中で互いに違い、dark と light で解が変わる。
  func testEveryRoleHasADistinctColorThatFollowsTheAppearance() throws {
    let style = EditorStyle.make()
    var darkValues: Set<String> = []
    for role in SyntaxRole.allCases {
      let color = try XCTUnwrap(style.roleColors[role], "\(role) に色が無い（素の文字色で描かれる）")
      let dark = try XCTUnwrap(resolved(color, .darkAqua))
      let light = try XCTUnwrap(resolved(color, .aqua))
      XCTAssertNotEqual(dark, light, "\(role) の色が外観で解き直されない")
      darkValues.insert("\(dark)")
    }
    XCTAssertEqual(darkValues.count, SyntaxRole.allCases.count, "役割ごとに違う色（取り違えの検知）")
  }

  /// 素の文字・キャレット・行番号も外観で解き直され、行番号だけは沈めた不透明度（α 0.55）を持つ。
  func testTextCaretAndLineNumberColorsFollowTheAppearance() throws {
    let style = EditorStyle.make()
    for color in [style.textColor, style.caretColor, style.gutterTextColor] {
      XCTAssertNotEqual(
        try XCTUnwrap(resolved(color, .darkAqua)), try XCTUnwrap(resolved(color, .aqua)))
    }
    XCTAssertEqual(
      try XCTUnwrap(resolved(style.gutterTextColor, .darkAqua)).alphaComponent, 0.55, accuracy: 0.01
    )
    XCTAssertEqual(try XCTUnwrap(resolved(style.textColor, .darkAqua)).alphaComponent, 1)
  }

  /// 打ち切った行の末尾の印の略記——丸めて次の単位に届けば次の単位で出す（「1,000K」「10,000万」にしない）。
  func testOmittedLabelAbbreviatesAtTheUnitBoundaries() {
    let en = EditorStyle.OmittedLabel(language: .en, locale: Locale(identifier: "en_US"))
    let ja = EditorStyle.OmittedLabel(language: .ja, locale: Locale(identifier: "ja_JP"))
    XCTAssertEqual(en(999), "999 more")
    XCTAssertEqual(en(999_949), "999.9K more")
    XCTAssertEqual(en(999_950), "1M more")
    XCTAssertEqual(en(999_999), "1M more")
    XCTAssertEqual(en(1_000_000), "1M more")
    XCTAssertEqual(ja(9_999), "ほか 9,999字")
    XCTAssertEqual(ja(10_000), "ほか 1万字")
    XCTAssertEqual(ja(12_345), "ほか 1.2万字")
    XCTAssertEqual(ja(99_999_999), "ほか 1億字")
  }

  /// 打ち切った行の末尾の印の数は、地域の数の書式（Foundation）と同じ字で出る——数字・桁区切りの字と位置・小数点。位取りで
  /// 書かない数字体系の地域（漢数字）と、桁区切りを使わない地域でも。
  func testOmittedLabelWritesNumbersAsTheRegionsNumberFormat() {
    func reference(_ count: Int, _ language: Language, _ locale: Locale) -> String {
      let ladder: [(unit: Double, suffix: String)] =
        language == .ja
        ? [(10_000, "万"), (100_000_000, "億")] : [(1_000, "K"), (1_000_000, "M"), (1e9, "B")]
      var value = count.formatted(.number.grouping(.automatic).locale(locale))
      var index = ladder.lastIndex { Double(count) >= $0.unit }
      while let i = index {
        let rounded = (Double(count) / ladder[i].unit * 10).rounded() / 10
        if i + 1 < ladder.count, rounded * ladder[i].unit >= ladder[i + 1].unit {
          index = i + 1
          continue
        }
        value =
          rounded.formatted(.number.precision(.fractionLength(0...1)).locale(locale))
          + ladder[i].suffix
        index = nil
      }
      return L10n.format(.editorOmittedCharacters, language, value)
    }
    let counts = [
      0, 1, 9, 10, 999, 1_000, 1_234, 9_999, 10_000, 12_345, 99_999, 100_000, 123_456, 999_949,
      999_950, 1_000_000, 1_234_567, 99_999_999, 100_000_000, 123_456_789, 1_000_000_000,
      12_345_678_901,
    ]
    for identifier in [
      "en_US", "ja_JP", "de_DE", "fr_FR", "es_ES", "ar_EG", "ja_JP@numbers=jpan", "en_US_POSIX",
    ] {
      let locale = Locale(identifier: identifier)
      for language in Language.allCases {
        let label = EditorStyle.OmittedLabel(language: language, locale: locale)
        for count in counts {
          XCTAssertEqual(
            label(count), reference(count, language, locale), "\(identifier) \(language) \(count)")
        }
      }
    }
  }
}
