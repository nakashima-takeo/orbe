import XCTest

@testable import Orbe

/// リリースノート（appcast description の Markdown）→ 描画要素の変換規則。
/// 「意味は入力の内容からだけ決まる」——分類は見出しの語から決まり出現順には依らず、
/// 段落は項目にならず、中身のない要素は積まれない、を固定する。
final class UpdateNotesTests: XCTestCase {

  private func plain(_ element: UpdateNotes.Element) -> String { String(element.text.characters) }

  /// GPL §6 の出典表記（「ソース: ...」段落）は箇条書きに吸われず、段落として独立する。
  func testParagraphIsNotAnItem() throws {
    let notes = UpdateNotes(
      markdown: """
        ### 修正
        - `①` などの記号が小さく表示される問題を修正

        ソース: https://github.com/nakashima-takeo/orbe/tree/v0.3.1
        """)

    let section = try XCTUnwrap(notes.sections.first)
    XCTAssertEqual(notes.sections.count, 1)
    XCTAssertEqual(section.title, "修正")
    XCTAssertEqual(section.elements.map(\.kind), [.item, .paragraph])
    // インライン Markdown は解釈され、記法（バックティック）は本文に残らない。
    XCTAssertEqual(plain(section.elements[0]), "① などの記号が小さく表示される問題を修正")
    XCTAssertEqual(
      plain(section.elements[1]), "ソース: https://github.com/nakashima-takeo/orbe/tree/v0.3.1")
  }

  /// 見出しより前の要素は title なしのセクションへ入る（見出しを持たないノートも描ける）。
  func testLeadingElementsFormUntitledSection() {
    let notes = UpdateNotes(markdown: "はじめの段落\n\n### 修正\n- 直した")

    XCTAssertEqual(notes.sections.map(\.title), [nil, "修正"])
    XCTAssertEqual(notes.sections[0].elements.map(\.kind), [.paragraph])
    XCTAssertEqual(notes.sections[1].elements.map(\.kind), [.item])
  }

  /// 本文が空の項目は要素にしない（マーカーだけの行が描かれないことの根）。
  func testEmptyElementsAreDropped() {
    let notes = UpdateNotes(markdown: "### 修正\n- 直した\n-\n-   \n")

    XCTAssertEqual(notes.sections.count, 1)
    XCTAssertEqual(notes.sections[0].elements.count, 1)
    XCTAssertEqual(plain(notes.sections[0].elements[0]), "直した")
  }

  /// セクションは出現順から属性を得ない——並び順が変わっても同じ Section 値になる。
  /// 射程はモデル層。Section 同士を丸ごと比べるので、出現順由来のフィールドが増えれば落ちる。
  func testSectionsCarryNoOrderDependentAttributes() {
    let ordered = UpdateNotes(markdown: "### 新機能\n- A\n\n### 修正\n- B")
    let reversed = UpdateNotes(markdown: "### 修正\n- B\n\n### 新機能\n- A")

    XCTAssertEqual(ordered.sections.map(\.title), ["新機能", "修正"])
    XCTAssertEqual(reversed.sections.map(\.title), ["修正", "新機能"])
    XCTAssertEqual(ordered.sections[0], reversed.sections[1])
    XCTAssertEqual(ordered.sections[1], reversed.sections[0])
  }

  /// 分類は見出しの語で決まる（release スキルが固定する 3 種）。
  func testCategoryComesFromHeadingWord() {
    let notes = UpdateNotes(markdown: "### 新機能\n- A\n\n### 改善\n- B\n\n### 修正\n- C")

    XCTAssertEqual(notes.sections.map(\.category), [.feature, .improvement, .fix])
  }

  /// 「修正」だけのノートでも修正は修正の分類になる（＝先頭にあるかどうかで変わらない）。
  func testFixOnlyNoteStaysFix() {
    XCTAssertEqual(UpdateNotes(markdown: "### 修正\n- 直した").sections.map(\.category), [.fix])
  }

  /// 規約外の見出し・見出し無しは中立へ落ちる（未知の語でも壊れない）。
  func testUnknownAndMissingHeadingsFallBackToNeutral() {
    let notes = UpdateNotes(markdown: "前置きの段落\n\n### 既知の問題\n- まだ直っていない")

    XCTAssertEqual(notes.sections.map(\.title), [nil, "既知の問題"])
    XCTAssertEqual(notes.sections.map(\.category), [.neutral, .neutral])
  }

  /// ソース側で折り返された項目は 1 行に畳む（ソフト改行が本文のハード改行にならない）。
  func testSoftBreakFoldsIntoOneLine() {
    let notes = UpdateNotes(markdown: "### 修正\n- とても長い項目がここで\n  折り返されている場合")

    XCTAssertEqual(notes.sections[0].elements.count, 1)
    XCTAssertEqual(
      plain(notes.sections[0].elements[0]), "とても長い項目がここで 折り返されている場合")
  }

  /// 入れ子の箇条書きは落とさず、同じ並びの項目として続ける（階層は持たない）。
  func testNestedItemsAreKeptAsItems() {
    let notes = UpdateNotes(markdown: "### 修正\n- 親項目\n  - 子項目A\n  - 子項目B")

    XCTAssertEqual(notes.sections[0].elements.map(\.kind), [.item, .item, .item])
    XCTAssertEqual(notes.sections[0].elements.map(plain), ["親項目", "子項目A", "子項目B"])
  }

  /// 現状描かないブロック種（順序付きリスト・コードブロック）は落とす。
  func testUnsupportedBlocksAreIgnored() {
    let notes = UpdateNotes(markdown: "### 修正\n- 直した\n\n1. 一つ目\n\n```\ncode\n```")

    XCTAssertEqual(notes.sections.count, 1)
    XCTAssertEqual(notes.sections[0].elements.map(\.kind), [.item])
  }
}
