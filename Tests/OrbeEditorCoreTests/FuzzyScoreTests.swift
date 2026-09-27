import XCTest

@testable import OrbeEditorCore

/// VS Code の tree の絞り込み（`FindFilter` が `fuzzyScore` を `firstMatchCanBeWeak: true, boostFullMatch: true` で呼ぶ）
/// の照合。事例は VS Code の filters.test.ts から移し、期待値は原本をこの呼び方で動かした結果（原本のテストの多くは
/// `firstMatchCanBeWeak: false` なので、弱い先頭一致を許す分だけ一致が増える）。壊れると、アウトラインの絞り込みで
/// VS Code と違う名前が残る・消える、強調する字がずれる。
final class FuzzyScoreTests: XCTestCase {
  func testMatchesOnWordStartsAndSeparators() {
    check("tit", "win.tit", "win.^t^i^t")
    check("title", "win.title", "win.^t^i^t^l^e")
    check("WordCla", "WordCharacterClassifier", "^W^o^r^dCharacter^C^l^assifier")
    check("WordCCla", "WordCharacterClassifier", "^W^o^r^d^Character^C^l^assifier")
    check(#"c:\do"#, #"& 'C:\Documents and Settings'"#, #"& '^C^:^\^D^ocuments and Settings'"#)
    check(#"c:\do"#, #"& 'c:\Documents and Settings'"#, #"& '^c^:^\^D^ocuments and Settings'"#)
    check("-moz", "-moz-foo", "^-^m^o^z-foo")
    check("moz", "-moz-foo", "-^m^o^z-foo")
    check("moza", "-moz-animation", "-^m^o^z-^animation")
    check("f", ":Foo", ":^Foo")
    check(".", "foo.bar", "foo^.bar")
    check("i", "machine/{id}", "machine/{^id}")
    check("ok", "obobobf{ok}/user", "^obobobf{o^k}/user")
  }

  func testPrefersTheBestPathOverTheFirstOccurrence() {
    check("close", "css.lint.importStatement", "^css.^lint.imp^ort^Stat^ement")
    check("close", "css.colorDecorators.enable", "^css.co^l^orDecorator^s.^enable")
    check(
      "close", "workbench.quickOpen.closeOnFocusOut", "workbench.quickOpen.^c^l^o^s^eOnFocusOut")
    check("highlight", "editorHoverHighlight", "editorHover^H^i^g^h^l^i^g^h^t")
    check("hhighlight", "editorHoverHighlight", "editor^Hover^H^i^g^h^l^i^g^h^t")
    check("lowrd", "lowWord", "^l^o^wWo^r^d")
    check("myvable", "myvariable", "^m^y^v^aria^b^l^e")
    check("SemanticTokens", "SemanticTokensEdits", "^S^e^m^a^n^t^i^c^T^o^k^e^n^sEdits")
  }

  func testCamelCaseAndUnderscoreHumps() {
    check("ab", "abA", "^a^bA")
    check("ccm", "cacmelCase", "^ca^c^melCase")
    check("BK", "the_black_knight", "the_^black_^knight")
    check("LLL", "SVisualLoggerLogsList", "SVisual^Logger^Logs^List")
    check("TEdit", "TextEdit", "^Text^E^d^i^t")
    check("TEdit", "TextEditor", "^Text^E^d^i^tor")
    check("TEdit", "Textedit", "^Text^e^d^i^t")
    check("TEdit", "text_edit", "^text_^e^d^i^t")
    check("TEditDit", "TextEditorDecorationType", "^Text^E^d^i^tor^Decorat^ion^Type")
    check("Tedit", "TextEdit", "^Text^E^d^i^t")
    check("bkn", "the_black_knight", "the_^black_^k^night")
    check("bt", "the_black_knight", "the_^black_knigh^t")
    check("ccm", "camelCasecm", "^camel^Casec^m")
    check("fdm", "findModel", "^fin^d^Model")
    check("is", "ImportStatement", "^Import^Statement")
    check("sllll", "SVisualLoggerLogsList", "^SVisua^l^Logger^Logs^List")
    check("zzg", "zzGroup", "^z^z^Group")
    check("g", "zzGroup", "zz^Group")
  }

  func testPlainPrefixesAndWholeWords() {
    check("fob", "foobar", "^f^oo^bar")
    check("foobar", "foobar", "^f^o^o^b^a^r")
    check("Three", "Three", "^T^h^r^e^e")
    check("is", "isValid", "^i^sValid")
    check("lo", "log", "^l^og")
    check("cno", "console", "^co^ns^ole")
    check("form", "editor.formatOnSave", "editor.^f^o^r^matOnSave")
  }

  func testSpacesInThePatternMatchSpacesInTheWord() {
    check("g p", "Git: Pull", "^Git:^ ^Pull")
    check("gip", "Git: Pull", "^G^it: ^Pull")
    check("gp", "Git: Pull", "^Git: ^Pull")
    check("gp", "Git_Git_Pull", "^Git_Git_^Pull")
    check("g", "  group", "  ^group")
    check("g g", "  group Group", "  ^group^ ^Group")
    check("g g", "  groupGroup", nil)
  }

  /// 原本のテストでは不一致でも、tree は先頭の字が語の途中（弱い位置）に当たるのを許すので一致する。
  func testFirstMatchMayBeWeak() {
    check("Three", "HTMLHRElement", "H^TML^H^R^El^ement")
    check("tor", "constructor", "construc^t^o^r")
    check("ur", "constructor", "constr^ucto^r")
    check("ob", "foobar", "fo^o^bar")
    check("fo", "barfoo", "bar^f^oo")
    check("dete", "\"editor.quickSuggestionsDelay\"", "\"e^ditor.quickSugg^es^tionsD^elay\"")
    check("dhhighlight", "editorHoverHighlight", "e^ditor^Hover^H^i^g^h^l^i^g^h^t")
    check("LLLL", "SVilLoLosLi", "SVi^l^Lo^Los^Li")
    check("LLLL", "SVisualLoggerLogsList", "SVisua^l^Logger^Logs^List")
    check("baba", "abababab", "a^b^a^b^abab")
    check(
      "fsfsfs", "dsafdsafdsafdsafdsafdsafdsafasdfdsa", "dsa^fd^sa^fd^sa^fd^safdsafdsafdsafasdfdsa")
  }

  func testNoMatch() {
    check("bti", "the_black_knight", nil)
    check("ccm", "camelCase", nil)
    check("cmcm", "camelCase", nil)
    check("KeyboardLayout=", "KeyboardLayout", nil)
    check("ba", "?AB?", nil)
    check("fobz", "foobar", nil)
    check("no", "match", nil)
    check("no", "", nil)
    check("rlut", "result", nil)
  }

  func testLongWordsAndPatternsAreCutAt128UnitsLikeTheOriginal() {
    check("aaaaaa", String(repeating: "a", count: 273), ranges: [0..<6])
    let fj = { (count: Int) in String(repeating: "fj", count: count) }
    check("jfjfj", fj(11), ranges: [1..<6])
    check("jfjfjfjfjfjfjfjfjfj", fj(30), ranges: [1..<20])
    check("jfjfjfjfjfjfjfjfjfj", "fJ" + fj(29), ranges: [1..<20])
    let bars = { (count: Int) in
      String(repeating: "f", count: 28) + String(repeating: "bar", count: count)
    }
    check("foo", bars(32) + "_foo", ranges: [125..<128])
    check("Aoo", "A" + bars(30) + "_foo", ranges: [0..<1, 121..<123])
    check("foo", "G" + bars(32) + "_foo", ranges: nil)
    check("x", String(repeating: "a", count: 127) + "x", ranges: [127..<128])
    check("x", String(repeating: "a", count: 128) + "x", ranges: nil)
    check(String(repeating: "a", count: 130), String(repeating: "a", count: 128), ranges: [0..<128])
    check("foo", String(repeating: "bar", count: 16) + "_foo", ranges: [49..<52])
  }

  func testRangesAreInUTF16Units() {
    check("di", "✨div classname=\"\"></div>", ranges: [1..<3])
    check("di", "adiv classname=\"\"></div>", ranges: [20..<22])
    check("b", "😀_bar", ranges: [3..<4])
    check("😀", "a😀b", ranges: [1..<3])
    check("ab", "😀a😀b", ranges: [2..<3, 5..<6])
    check("本", "日本語", ranges: [1..<2])
  }

  /// 原本は元の語の添字で小文字の語を引くので、小文字にすると長くなる字（İ → i̇）の後ろはずれたまま照合する。
  func testLowercasingThatLengthensTheWordShiftsLikeTheOriginal() {
    check("i", "İstanbul", ranges: [0..<1])
    check("st", "İstanbul", ranges: [2..<4])
    check("bul", "İİİbul", ranges: nil)
    check("é", "CAFÉ", ranges: [3..<4])
    check("k", "\u{212A}", ranges: [0..<1])
    check("cafe", "café", ranges: nil)
    check("ss", "ß", ranges: nil)
  }

  func testAnEmptyPatternMatchesEverythingWithoutHighlights() {
    XCTAssertEqual(FuzzyScorer(pattern: "").matches("anything"), [])
    XCTAssertEqual(FuzzyScorer(pattern: "").matches(""), [])
  }

  func testReusingTheScorerGivesTheSameResultsAsAFreshOne() {
    let words = [
      "SVisualLoggerLogsList", String(repeating: "fj", count: 60), "sl", "SVisualLoggerLogsList",
      "the_black_knight", "",
    ]
    let reused = FuzzyScorer(pattern: "sl")
    for word in words {
      XCTAssertEqual(reused.matches(word), FuzzyScorer(pattern: "sl").matches(word), word)
    }
  }

  private func check(
    _ pattern: String, _ word: String, _ decorated: String?, file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard let decorated else {
      check(pattern, word, ranges: nil, file: file, line: line)
      return
    }
    var ranges: [Range<Int>] = []
    var plain: [UInt16] = []
    var marked = false
    for unit in decorated.utf16 {
      if unit == UInt16(UInt8(ascii: "^")) {
        marked = true
        continue
      }
      if marked {
        let position = plain.count
        if let last = ranges.last, last.upperBound == position {
          ranges[ranges.count - 1] = last.lowerBound..<(position + 1)
        } else {
          ranges.append(position..<(position + 1))
        }
        marked = false
      }
      plain.append(unit)
    }
    XCTAssertEqual(Array(word.utf16), plain, "印を除いた語が一致しない", file: file, line: line)
    check(pattern, word, ranges: ranges, file: file, line: line)
  }

  private func check(
    _ pattern: String, _ word: String, ranges: [Range<Int>]?, file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(
      FuzzyScorer(pattern: pattern).matches(word), ranges, "\(pattern) → \(word)", file: file,
      line: line)
  }
}
