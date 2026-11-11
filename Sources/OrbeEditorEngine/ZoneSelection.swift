import AppKit
import OrbeEditorCore
import simd

/// 絵の差し込みの文の選択——絵の差し込み 1 つの、選べる文のまとまり 1 つの中のカーソル（本文と同じ形。語・段落の単位で
/// 伸ばせる）。位置はまとまりの文の UTF-16。
struct ZoneTextSelection: Equatable {
  var zone: ObjectIdentifier
  var text: AnyHashable
  var cursor: Cursor

  var range: NSRange { cursor.selection }
}

/// 絵の差し込みの文の選択（main）。選べる文の上を押す・ドラッグする・ダブルクリックする・⇧クリックすると、主が
/// 絵の差し込みの文になる。選択はまとまりの中だけで伸びる（まとまりをまたがない。絵の差し込みの外へドラッグすれば本文と
/// 同じ自動スクロールで伸び、まとまりの端で止まる）。語の境は本文と同じ規則（`EditCommands`）。選択の地は、
/// 絵の差し込みの箱の上・字の下に描く（面に焦点があれば焦点のある選択の色）。絵の差し込みを描き直しても、まとまりと
/// 範囲が残っていれば選択は残る。
extension MetalTextSurface {
  /// 絵の差し込み `entry` のまとまり `text` の位置 `offset` を押した——主を絵の差し込みの文にし、押した回数で単位
  /// （字・語・段落）を決めて選ぶ。`extending`（⇧）なら、同じまとまりの今の選択を起点を保って伸ばす。
  func beginZoneSelection(
    _ entry: ZoneEntry, text: AnyHashable, offset: Int, clicks: Int, extending: Bool
  ) {
    guard let rope = entry.hits.texts[text] else { return }
    let zone = ObjectIdentifier(entry.zone)
    transact {
      if extending, let current = zoneSelection, current.zone == zone, current.text == text {
        zoneSelection?.cursor = Self.extend(current.cursor, to: offset, rope)
      } else {
        let cursor: Cursor
        switch clicks {
        case ...1: cursor = Cursor(offset)
        case 2: cursor = EditCommands.wordSelection(at: offset, rope)
        default:
          let row = rope.row(containing: offset)
          let range = NSRange(
            location: rope.lineStart(row), length: rope.lineEnd(row) - rope.lineStart(row))
          cursor = Cursor(selectionStart: range, unit: .line, position: NSMaxRange(range))
        }
        zoneSelection = ZoneTextSelection(zone: zone, text: text, cursor: cursor)
      }
      setPrimary(.zoneText)
      publishZoneSelection()
    }
  }

  /// ドラッグ——絵の差し込みの文の選択の動く端を、点（view の座標。`position` はスクロールの位置）にいちばん
  /// 近いまとまりの位置へ伸ばす（点が絵の差し込みの外なら、まとまりの端）。
  func extendZoneSelection(to point: CGPoint, position: SIMD2<Double>? = nil) {
    guard let selection = zoneSelection, let entry = zones[selection.zone],
      let rope = entry.hits.texts[selection.text],
      let local = zonePoint(point, in: selection.zone, position: position),
      let offset = entry.hits.offset(in: selection.text, at: local)
    else { return }
    let cursor = Self.extend(selection.cursor, to: offset, rope)
    guard cursor != selection.cursor else { return }
    transact {
      zoneSelection?.cursor = cursor
      publishZoneSelection()
    }
  }

  /// ⌘A——まとまり全体を選ぶ。
  func selectAllZoneText() {
    guard let selection = zoneSelection,
      let rope = zones[selection.zone]?.hits.texts[selection.text]
    else { return }
    transact {
      zoneSelection?.cursor = .selecting(NSRange(location: 0, length: rope.length))
      publishZoneSelection()
    }
  }

  /// 選んでいる絵の差し込みの文（空なら nil）。
  var zoneSelectedText: String? {
    guard let selection = zoneSelection, selection.range.length > 0,
      let rope = zones[selection.zone]?.hits.texts[selection.text]
    else { return nil }
    return rope.substring(selection.range)
  }

  /// 絵の差し込みの文の選択を解く（主が絵の差し込みの文から離れた）。
  func clearZoneSelection() {
    guard zoneSelection != nil else { return }
    zoneSelection = nil
    transaction?.writes.append { $0.zoneSelection = nil }
  }

  /// 絵の差し込みを描き直した——まとまりが描き直した絵に無いか、範囲がまとまりの文の外になれば主を本文に、そうでなければ
  /// 選択の地を描き直す。
  func validateZoneSelection(_ entry: ZoneEntry) {
    guard let selection = zoneSelection else { return }
    guard let rope = entry.hits.texts[selection.text],
      NSMaxRange(selection.cursor.selectionStart) <= rope.length,
      selection.cursor.position <= rope.length
    else { return setPrimary(.body) }
    publishZoneSelection()
  }

  /// 絵の差し込みの文の選択の地を材料に書く——字の行ごとに、選択と行の範囲の交わりを行の帯の高さで塗る（取引の中）。
  func publishZoneSelection() {
    guard let selection = zoneSelection, let entry = zones[selection.zone] else { return }
    let range = selection.range
    var rects: [CGRect] = []
    if range.length > 0 {
      for line in entry.hits.lines where line.text == selection.text {
        let lower = max(range.location, line.range.location)
        let upper = min(NSMaxRange(range), NSMaxRange(line.range))
        guard lower < upper else { continue }
        let x0 = line.x(of: lower)
        let x1 = line.x(of: upper)
        rects.append(
          CGRect(
            x: x0, y: line.band.lowerBound, width: x1 - x0,
            height: line.band.upperBound - line.band.lowerBound))
      }
    }
    let material = ZoneSelectionMaterial(zone: selection.zone, rects: rects, focused: focused)
    transaction?.writes.append { $0.zoneSelection = material }
  }

  /// 面に焦点があるかに合わせて、絵の差し込みの文の選択の地の色を替える。
  func zoneSelectionFocusDidChange() {
    guard zoneSelection != nil else { return }
    publishZoneSelection()
  }

  /// 起点の範囲と単位を保って `offset` まで伸ばす（本文のマウスの選択と同じ）。
  private static func extend(_ cursor: Cursor, to offset: Int, _ rope: TextRope) -> Cursor {
    switch cursor.unit {
    case .character: cursor.moved(to: offset, extending: true)
    case .word: EditCommands.extendByWord(cursor, to: offset, rope)
    case .line: EditCommands.extendByLine(cursor, toRow: rope.row(containing: offset), rope)
    }
  }
}
