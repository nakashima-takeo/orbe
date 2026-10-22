import AppKit
import XCTest

@testable import Orbe

extension RowListTests {
  /// 源の偽物の行の組（版だけ）。
  struct SourceRows {
    let version: Int
  }

  /// 源の偽物。行 r の中身は "row r"、選択の同一性は行の番号そのもの。受けた操作を記録する。
  final class Source: RowListSource {
    var rowCount = 200
    /// 組の版。組は版だけを写す値で、行の数は読み直さなくてもその場で変わる。
    var version = 0
    var rows: SourceRows { SourceRows(version: version) }
    func rowCount(in rows: SourceRows) -> Int { rowCount }
    var wantsFocus = false
    private(set) var keys: [RowListKey] = []
    private(set) var releases = 0
    private(set) var clicks: [String] = []
    private(set) var selected: [Int] = []
    private(set) var focus: [Bool] = []
    private(set) var focusRequestsApplied = 0
    /// 今の行の数の外の行を問われた回数。
    private(set) var outOfRange = 0
    /// 部品の押下に返す錨。
    var anchor: RowListAnchor<Int>?
    /// 部品の押下で渡された組の版。
    private(set) var pressedVersions: [Int] = []

    func makeRowView() -> Row { Row(frame: .zero) }
    func show(_ row: Int, of rows: SourceRows, in view: Row, emoji: NSFont?) {
      if row >= rowCount { outOfRange += 1 }
      view.show("row \(row)")
    }
    func row(of selection: Int, in rows: SourceRows) -> Int? {
      selection < rowCount ? selection : nil
    }
    func prepareRows(for appearance: NSAppearance) {}
    func focusRequestDidApply() {
      wantsFocus = false
      focusRequestsApplied += 1
    }
    func focusDidChange(_ focused: Bool) { focus.append(focused) }
    func perform(_ key: RowListKey, in rows: SourceRows) { keys.append(key) }
    func keyDidRelease() { releases += 1 }
    func click(_ row: Int, in rows: SourceRows) {
      if row >= rowCount { outOfRange += 1 }
      clicks.append("click \(row)")
    }
    func doubleClick(_ row: Int, in rows: SourceRows) { clicks.append("double \(row)") }
    func press(_ row: Int, control: Int, in rows: SourceRows) -> RowListAnchor<Int>? {
      clicks.append("press \(row) \(control)")
      pressedVersions.append(rows.version)
      return anchor
    }
    func select(_ row: Int, in rows: SourceRows) { selected.append(row) }
  }

  /// 行の偽物。中身が変わったときだけ描き直す（描いた回数を数える）。右端 30pt に部品 0 を持つ。
  final class Row: ListRowView {
    private(set) var label: String?
    private(set) var draws = 0

    func show(_ label: String) {
      guard label != self.label else { return }
      self.label = label
      setAccessibilityLabel(label)
      needsDisplay = true
    }

    override func drawContent(_ colors: RowColors, in context: CGContext) { draws += 1 }

    override func control(at point: NSPoint) -> ListRowControl? {
      let frame = NSRect(x: bounds.maxX - 30, y: 0, width: 30, height: bounds.height)
      return frame.contains(point) ? ListRowControl(id: 0, frame: frame) : nil
    }
  }
}

/// 選べる行の無い源の偽物（行は 10）。受けたクリックを記録する。
final class RowListUnselectableSource: RowListSource {
  typealias Selection = Never
  var rows: RowListTests.SourceRows { RowListTests.SourceRows(version: 0) }
  private(set) var clicks: [Int] = []
  func rowCount(in rows: RowListTests.SourceRows) -> Int { 10 }
  func makeRowView() -> RowListTests.Row { RowListTests.Row(frame: .zero) }
  func show(_ row: Int, of rows: RowListTests.SourceRows, in view: RowListTests.Row, emoji: NSFont?)
  {
    view.show("row \(row)")
  }
  func prepareRows(for appearance: NSAppearance) {}
  func click(_ row: Int, in rows: RowListTests.SourceRows) { clicks.append(row) }
}
