import AppKit
import XCTest

@testable import Orbe

extension RowListTests {
  /// 源の偽物。行 r の中身は "row r"、選択の同一性は行の番号そのもの。受けた操作を記録する。行の高さは `segments`
  /// （無ければ全行 20 の区間 1 つ）。
  final class Source: RowListSource {
    var rowCount = 200
    var segments: [RowListSegment]?
    /// 組は自分自身（行をその場で変える源の型）。
    var rows: Source { self }
    func rowCount(in rows: Source) -> Int { rowCount }
    func segments(in rows: Source) -> [RowListSegment] {
      segments ?? [RowListSegment(start: 0, count: rowCount, height: 20)]
    }
    var wantsFocus = false
    private(set) var keys: [RowListKey] = []
    private(set) var releases = 0
    private(set) var clicks: [String] = []
    private(set) var selected: [Int] = []
    private(set) var focus: [Bool] = []
    private(set) var focusRequestsApplied = 0
    /// 今の行の数の外の行を問われた回数。
    private(set) var outOfRange = 0

    func makeRowView() -> Row { Row(frame: .zero) }
    func show(_ row: Int, of rows: Source, in view: Row, emoji: NSFont?) {
      if row >= rowCount { outOfRange += 1 }
      view.show("row \(row)")
    }
    func row(of selection: Int, in rows: Source) -> Int? { selection < rowCount ? selection : nil }
    func prepareRows(for appearance: NSAppearance) {}
    func focusRequestDidApply() {
      wantsFocus = false
      focusRequestsApplied += 1
    }
    func focusDidChange(_ focused: Bool) { focus.append(focused) }
    func perform(_ key: RowListKey, in rows: Source) { keys.append(key) }
    func keyDidRelease() { releases += 1 }
    func click(_ row: Int, in rows: Source) {
      if row >= rowCount { outOfRange += 1 }
      clicks.append("click \(row)")
    }
    func doubleClick(_ row: Int, in rows: Source) { clicks.append("double \(row)") }
    func press(_ row: Int, control: Int, in rows: Source) -> RowListAnchor<Int>? {
      clicks.append("press \(row) \(control)")
      return nil
    }
    func select(_ row: Int, in rows: Source) { selected.append(row) }
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

    override func control(at point: NSPoint) -> Int? {
      bounds.contains(point) && point.x >= bounds.maxX - 30 ? 0 : nil
    }
  }
}
