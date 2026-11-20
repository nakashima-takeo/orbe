import AppKit
import OrbeEditorCore

/// 絵の差し込みの当たりの表（main）——絵の層ごとの当たりの表（押せる場所・入力欄・選べる字の行と、まとまりの文。座標は層の
/// 原点から）と層の原点を、絵の層の順に持つ。点で引くときは層の原点を引いて層の座標で引き、後ろの層から当たる。次の写しで
/// 使い回す覚え（層を写した外観・字の行を組んだもの）も持つ。
struct ZoneHits {
  struct Button {
    var id: AnyHashable
    var frame: CGRect
    var cursor: NSCursor
  }

  struct Field {
    var frame: CGRect
    var field: ZoneTextField
  }

  /// 選べる字の行——まとまり・基線の左端・字の帯と、組んだ行（元の文の位置 ↔ x）。
  struct Line {
    var text: AnyHashable
    var origin: CGPoint
    var ascent: CGFloat
    var descent: CGFloat
    var layout: ZoneTextLayout.TypesetLine

    /// まとまりの中の範囲。
    var range: NSRange { layout.range }

    /// 行の当たる帯（y）。
    var band: ClosedRange<CGFloat> { (origin.y - ascent)...(origin.y + descent) }

    /// x にいちばん近い、まとまりの文の位置。
    func offset(atX x: CGFloat) -> Int { layout.offset(atX: x - origin.x) }

    /// まとまりの文の位置の x。
    func x(of offset: Int) -> CGFloat { origin.x + layout.x(of: offset) }

    /// 原点を `offset` だけずらした行。
    func moved(by offset: CGPoint) -> Line {
      var line = self
      line.origin = CGPoint(x: origin.x + offset.x, y: origin.y + offset.y)
      return line
    }
  }

  /// 選べる文のまとまり——文と、まとまりの行（層の `lines` の添字の範囲）。
  struct Text {
    var rope: TextRope
    var lines: Range<Int>
  }

  /// 層 1 つの当たりの表（座標は層の原点から）。
  struct Layer {
    var buttons: [Button] = []
    var fields: [Field] = []
    var lines: [Line] = []
    var texts: [AnyHashable: Text] = [:]
  }

  /// 絵の層 1 つ——原点と、写した層（同一性で使い回しを決める）と、その当たりの表。
  struct Placed {
    var origin: CGPoint
    var layer: ZoneLayer
    var hits: Layer

    /// 絵の差し込みの中の点の、層の座標。
    func local(_ point: CGPoint) -> CGPoint {
      CGPoint(x: point.x - origin.x, y: point.y - origin.y)
    }
  }

  var layers: [Placed] = []
  /// 層を写した外観（同じ外観の次の写しで、同じ層の材料と当たりの表を使い回す）。
  var look: ZonePainter.LookKey?
  /// 字の行を組んだもの（次の写しで、字と字体が同じ字の行は組み直さずに使い回す）。
  var labels: [ZoneLabelKey: [ZonePainter.Glyphs]] = [:]

  /// 入力欄（矩形は絵の差し込みの座標）。
  var fields: [Field] {
    layers.flatMap { placed in
      placed.hits.fields.map {
        Field(frame: $0.frame.offsetBy(dx: placed.origin.x, dy: placed.origin.y), field: $0.field)
      }
    }
  }

  /// 絵の差し込みの中の点の下の入力欄（矩形は絵の差し込みの座標）。
  func field(at point: CGPoint) -> Field? {
    for placed in layers.reversed() {
      let local = placed.local(point)
      if let field = placed.hits.fields.last(where: { $0.frame.contains(local) }) {
        return Field(
          frame: field.frame.offsetBy(dx: placed.origin.x, dy: placed.origin.y), field: field.field)
      }
    }
    return nil
  }

  /// 絵の差し込みの中の点の下の押せる場所（矩形は絵の差し込みの座標）。
  func button(at point: CGPoint) -> Button? {
    for placed in layers.reversed() {
      let local = placed.local(point)
      if var button = placed.hits.buttons.last(where: { $0.frame.contains(local) }) {
        button.frame = button.frame.offsetBy(dx: placed.origin.x, dy: placed.origin.y)
        return button
      }
    }
    return nil
  }

  /// 絵の差し込みの中の点の下の選べる文（まとまりと、いちばん近い位置）。字の行の帯と、その左右に少しの余白の上だけ。
  func text(at point: CGPoint) -> (AnyHashable, Int)? {
    let slop: CGFloat = 4
    for placed in layers.reversed() {
      let local = placed.local(point)
      if let line = placed.hits.lines.last(where: {
        $0.band.contains(local.y) && local.x >= $0.origin.x - slop
          && local.x <= $0.origin.x + $0.layout.width + slop
      }) {
        return (line.text, line.offset(atX: local.x))
      }
    }
    return nil
  }

  /// まとまり `text` を持つ層（無ければ nil）。仕事は層の数に比例する。
  func layer(containing text: AnyHashable) -> Placed? {
    layers.first { $0.hits.texts[text] != nil }
  }

  /// まとまり `text` の文。
  func rope(of text: AnyHashable) -> TextRope? {
    layer(containing: text)?.hits.texts[text]?.rope
  }

  /// まとまり `text` の字の行（原点は絵の差し込みの座標）。
  func lines(of text: AnyHashable) -> [Line] {
    guard let placed = layer(containing: text), let found = placed.hits.texts[text] else {
      return []
    }
    return placed.hits.lines[found.lines].map { $0.moved(by: placed.origin) }
  }

  /// まとまり `text` の字の行のうち、絵の差し込みの中の y にいちばん近い行の、x にいちばん近い位置（上の行より上は文の
  /// 始まり、下の行より下は文の終わり）。まとまりの行が無ければ nil。
  func offset(in text: AnyHashable, at point: CGPoint) -> Int? {
    let candidates = lines(of: text)
    guard let first = candidates.first, let last = candidates.last else { return nil }
    if point.y < first.band.lowerBound { return first.range.location }
    if point.y > last.band.upperBound { return NSMaxRange(last.range) }
    let line =
      candidates.first { $0.band.contains(point.y) }
      ?? candidates.min { abs($0.origin.y - point.y) < abs($1.origin.y - point.y) }!
    return line.offset(atX: point.x)
  }
}

/// 字の行を組んだものを使い回す鍵——連なりごとの字（UTF-16 の並び）と字体。色は含めない。
struct ZoneLabelKey: Hashable {
  let units: [[UInt16]]
  let fonts: [CTFont]

  init(_ runs: [ZoneTextRun]) {
    units = runs.map { Array($0.string.utf16) }
    fonts = runs.map { $0.font as CTFont }
  }
}
