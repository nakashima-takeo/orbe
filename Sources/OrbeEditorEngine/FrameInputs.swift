import AppKit
import CoreText
import OrbeEditorCore
import os

/// 行の印（git ガター）を行に写したもの。面が印を受け取ったときに、引いた写しで写す。
struct RowMarks: Equatable, Sendable {
  struct Bar: Equatable, Sendable {
    var rows: ClosedRange<Int>
    var kind: LineMarks.Kind
  }

  /// 削除の三角。`atBottom` は行の下端（改行で終わらない本文の末尾）、そうでなければ行の上端。
  struct Deletion: Equatable, Sendable {
    var row: Int
    var atBottom: Bool
  }

  var bars: [Bar] = []
  var deletions: [Deletion] = []

  static let empty = RowMarks()

  init() {}

  /// 区間は改行込みなので、最後の行は区間の最後の字の行。境は次の行の行頭（本文が改行で終わらない末尾なら最後の行の下端）。
  init(_ spans: LineMarkSpans, in text: TextRope) {
    bars = spans.marks.map { mark in
      let rows = text.rows(of: NSRange(location: mark.range.location, length: mark.range.length))
      return Bar(rows: rows, kind: mark.kind)
    }
    deletions = spans.deletions.map { offset in
      let row = text.row(containing: offset)
      return Deletion(row: row, atBottom: text.lineStart(row) != offset)
    }
  }
}

/// 面を作るときに決まり、閉じるまで変わらない見え方。フォントは不変で、Core Text はスレッドをまたいだ利用を保証する。
struct SurfaceConfig: @unchecked Sendable {
  /// 装備の寸法。
  struct Decorations: Sendable {
    var whitespaceDiameter: CGFloat
    var linkUnderlineThickness: CGFloat
    var linkUnderlineOffset: CGFloat
  }

  struct Marks: Sendable {
    var gutterWidth: CGFloat
    var barWidth: CGFloat
    var barInset: CGFloat
    var barRadius: CGFloat
    var triangleSize: CGFloat
  }

  let font: CTFont
  let gutterFont: CTFont
  let lineHeight: CGFloat
  let topInset: CGFloat
  let caretSize: CGSize
  let gutterWidth: CGFloat
  let gutterTrailingInset: CGFloat
  let marks: Marks
  let decorations: Decorations
  let overview: Overview
  /// 打ち切った行の末尾に出す印の文言（打ち切った単位の数から）。
  let omittedLabel: @Sendable (Int) -> String
  /// 1 桁の幅（空白の送り）。
  let cell: CGFloat
  let ascent: CGFloat
  let descent: CGFloat
  let gutterAscent: CGFloat
  let gutterDescent: CGFloat
  /// 行番号の数字 0…9 のグリフと送り。
  let digitGlyphs: [CGGlyph]
  let digitAdvances: [CGFloat]

  init(style: TextSurfaceStyle, omittedLabel: @escaping @Sendable (Int) -> String) {
    font = style.font as CTFont
    gutterFont = style.gutterFont as CTFont
    lineHeight = style.lineHeight
    topInset = style.topInset
    caretSize = style.caretSize
    gutterWidth = style.gutterWidth
    gutterTrailingInset = style.gutterTrailingInset
    marks = Marks(
      gutterWidth: style.marks.gutterWidth, barWidth: style.marks.barWidth,
      barInset: style.marks.barInset, barRadius: style.marks.barRadius,
      triangleSize: style.marks.triangleSize)
    decorations = Decorations(
      whitespaceDiameter: style.decorations.whitespaceDiameter,
      linkUnderlineThickness: style.decorations.linkUnderlineThickness,
      linkUnderlineOffset: style.decorations.linkUnderlineOffset)
    overview = Overview(style.overview)
    self.omittedLabel = omittedLabel
    cell = Self.advances(of: [0x20], in: font).advances[0]
    ascent = CTFontGetAscent(font)
    descent = CTFontGetDescent(font)
    gutterAscent = CTFontGetAscent(gutterFont)
    gutterDescent = CTFontGetDescent(gutterFont)
    (digitGlyphs, digitAdvances) = Self.advances(of: Array("0123456789".utf16), in: gutterFont)
  }

  private static func advances(of characters: [UniChar], in font: CTFont) -> (
    glyphs: [CGGlyph], advances: [CGFloat]
  ) {
    var characters = characters
    var glyphs = [CGGlyph](repeating: 0, count: characters.count)
    CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count)
    var sizes = [CGSize](repeating: .zero, count: glyphs.count)
    CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &sizes, glyphs.count)
    return (glyphs, sizes.map(\.width))
  }

  /// 行番号の数字の幅。
  func numberWidth(_ number: Int) -> CGFloat {
    var n = number
    var width: CGFloat = 0
    repeat {
      width += digitAdvances[n % 10]
      n /= 10
    } while n > 0
    return width
  }

  /// タブの刻み（pt）。
  func tabWidth(columns: Int) -> CGFloat { CGFloat(columns) * cell }

  /// 行の上端から基線まで（行の中で字を縦の中央に置く）。
  var baseline: CGFloat { (lineHeight - (ascent + descent)) / 2 + ascent }
}

/// 変わった行——本文の編集では編集前の行 `rows` が編集後の `inserted` 行に置き換わり、後ろの行はずれる。役割だけが変わった
/// 行（`rolesOnly`）は中身も行の数も同じで色だけが変わる（組版は捨てず、色を覚えたもの——ミニマップの字——だけを捨てる）。
/// 本文の編集と役割の変化は、届いた順に 1 本の列に積む（前後して届いても、行のずれを順に当てれば正しい行を捨てる）。
/// `version` は変わった後の写しの版。
struct RowEdit: Equatable, Sendable {
  var rows: Range<Int>
  var inserted: Int
  var version: Int
  var rolesOnly = false
  /// 本文の編集。行へ写した区間を編集でずらして使い回すのに使う（全部の行が変わった・役割だけが変わったなら nil）。
  var text: TextChange?

  /// 本文の編集の区間（編集前の本文の座標）と置き換えの長さ。
  struct TextChange: Equatable, Sendable {
    var range: NSRange
    var replacementLength: Int
  }

  /// 全部の行が変わった。
  static func all(version: Int) -> RowEdit {
    RowEdit(rows: 0..<Int.max, inserted: 0, version: version)
  }

  init(rows: Range<Int>, inserted: Int, version: Int, rolesOnly: Bool = false) {
    self.rows = rows
    self.inserted = inserted
    self.version = version
    self.rolesOnly = rolesOnly
  }

  /// 編集前の本文 `text` への編集 `edit`。置き換えた区間の始まりの行から終わりの行までが、置き換えの中身の行に変わる。
  init(_ edit: TextEdit, in text: TextRope, version: Int) {
    let first = text.row(containing: edit.range.location)
    let last = text.row(containing: NSMaxRange(edit.range))
    rows = first..<last + 1
    inserted = edit.replacement.reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }
    self.version = version
    self.text = TextChange(range: edit.range, replacementLength: edit.replacementLength)
  }
}

/// 選択の地とキャレット。main の取引が本文と同じ書き込みで置く。
struct CaretMaterial: Equatable, Sendable {
  /// 選択の範囲（昇順）。空の選択は含めない。
  var selections: [NSRange] = []
  /// キャレットのオフセット（昇順。描画は見えている行のものだけを二分探索で引く）。
  var carets: [Int] = []
  /// 選択の無いカーソルの位置（昇順。ミニマップがその行を出す）。
  var collapsed: [Int] = []
  /// 点滅の起点（`CACurrentMediaTime`）。キャレットが動くたびに置き直し、表示から始める。
  var epoch: Double = 0
  /// 場が主で、面に焦点がある（first responder で、窓が key）。無ければキャレットを描かず、選択の地は弱い色。
  var focused = false
  /// 点滅させるか（アクセシビリティの「点滅しない挿入ポイント」が有効なら、点滅せず描き続ける）。
  var blinks = true
  /// 変換中の文字（変換中でなければ nil）。変換中のキャレットは、変換に入った各カーソルの IME の注目位置。
  var marked: MarkedMaterial?

  /// 点滅の刻み（表示・非表示それぞれの長さ）。
  static let blinkInterval = 0.5

  /// 焦点があり、キャレットがある。
  var showsCaret: Bool { focused && !carets.isEmpty }

  /// 時刻 `t` にキャレットを描くか。
  func caretVisible(at t: Double) -> Bool {
    showsCaret
      && (!blinks || Int((max(0, t - epoch) / Self.blinkInterval).rounded(.down)) % 2 == 0)
  }

  /// 時刻 `t` の後で次に表示が切り替わる時刻（焦点が無いか点滅しなければ nil——止まっている間は起きない）。
  func nextBlink(after t: Double) -> Double? {
    guard showsCaret, blinks else { return nil }
    let phase = (max(0, t - epoch) / Self.blinkInterval).rounded(.down) + 1
    return epoch + phase * Self.blinkInterval
  }
}

/// 入力欄の場の描く材料——写し・キャレットと選択・横の送りの箱と頼まれた横の「見えるところまで」・見え方。main の取引が
/// 場の確定で置く。キャレットの `focused` は「入力欄が主で、面に焦点がある」。
struct FieldMaterial: @unchecked Sendable {
  var content: SurfaceContent
  var caret: CaretMaterial
  let scroll: FieldScroll
  var reveal: HorizontalReveal?
  var font: CTFont
  var lineHeight: CGFloat
  /// 行の上端から基線まで（pt）と、タブの桁と刻み（pt）——main の場の幾何と同じ値（→ `EditingSite`）。
  var baseline: CGFloat
  var tabColumns: Int
  var tabWidth: CGFloat
  var palette: FieldPalette
}

/// 入力欄の場の横の送り（pt。入力欄の左端から隠れている幅）。main が読み（当たり・IME の矩形）、描画スレッドだけが変える
/// ——取引が頼んだ「キャレットが見えるところまで」を、描画スレッドがその行を組んだ x で解く（本文の横の寄せと同じく、
/// main は打鍵のたびに行を組まない）。鍵の中では値の読み書きだけをする。
final class FieldScroll: Sendable {
  private let state = OSAllocatedUnfairLock(initialState: (x: 0.0, serial: 0))

  var x: Double { state.withLock { $0.x } }

  /// 通し番号 `serial` の頼みがまだなら、x 区間 `caret` が幅 `width` に見えるところまで最小限動かす。動いたら true。
  func reveal(serial: Int, caret: ClosedRange<Double>, width: Double) -> Bool {
    state.withLock { s in
      guard serial > s.serial else { return false }
      s.serial = serial
      let before = s.x
      if caret.lowerBound < s.x {
        s.x = caret.lowerBound
      } else if caret.upperBound > s.x + width {
        s.x = max(0, caret.upperBound - width)
      }
      return s.x != before
    }
  }
}

/// 入力欄の外観で解いた色。
struct FieldPalette: Equatable, Sendable {
  var text: InkColor
  var caret: FrameColor
  var selection: FrameColor
  var inactiveSelection: FrameColor
}

/// 取引が頼んだ横の「見えるところまで」。描画スレッドが区間の行を組んで x を引き、横の位置を寄せる——main は論理の位置
/// だけを持ち、打鍵のたびに行を組まない。`serial` が進むたびに 1 回だけ解く。
struct HorizontalReveal: Equatable, Sendable {
  var range: NSRange
  var serial: Int
}

/// 変換中の文字——全カーソルの未確定の範囲（昇順）と、どの範囲にも同じに写す見た目（文節の範囲は未確定の先頭から）。
struct MarkedMaterial: Equatable, Sendable {
  var ranges: [NSRange]
  var appearance: MarkedAppearance
}

/// 描く材料。main が置き、描画スレッドが表示の刻みごとに最新を読む。
struct FrameMaterial: Sendable {
  var content: SurfaceContent?
  /// 描画スレッドがまだ受け取っていない本文の編集（古い順）。
  var rowEdits: [RowEdit] = []
  /// 描画スレッドがまだ受け取っていない打鍵の時刻（その打鍵の取引が入ったコマで打鍵→画面の遅れを測る）。
  var keystrokes: [Double] = []
  var marks = RowMarks.empty
  /// 縦の並び（写しと同じ書き込みで置く——描画スレッドは引き取った写しの行の並びで描く）。
  var rows = RowLayout(lineHeight: 1)
  /// 差し込んだ行の出どころの写し（並びと同じ書き込みで置き、出どころの役割が変われば置き直す）。
  var rowSource: SurfaceContent?
  /// 表示の構成のうち、配置と描き方に効くもの。
  var arrangement = SurfaceArrangement()
  /// 区画の描く材料（区画の同一性で引く。並びの塊の中身と同じ書き込みで置く）。
  var zones: [ObjectIdentifier: ZoneMaterial] = [:]
  /// 入力欄の場の描く材料（場の通し番号で引く）。
  var fields: [Int: FieldMaterial] = [:]
  /// 区画の文の選択の地（区画の文が主の間だけ）。
  var zoneSelection: ZoneSelectionMaterial?
  /// 本文の選択の地とキャレット。`focused` は「本文が主で、面に焦点がある」。
  var caret = CaretMaterial()
  /// まだ解いていないかもしれない横の「見えるところまで」（本文を変えて見せない取引は、古い区間を捨てる）。
  var reveal: HorizontalReveal?
  /// ドラッグで落とす位置の印（ドラッグの間だけ）。
  var drop: Int?
  /// 強調の地（Orbe が押した区間）。
  var highlights = Highlights()
  /// 俯瞰の操作の状態。
  var overview = OverviewInput()
  /// ⌘ を押している間の、本文の上のポインタの位置（面の view の座標、pt）。描画スレッドがそのコマの配置で下の URL に
  /// 下線を引く（スクロールで URL がポインタの下から外れれば引かない）。
  var linkPointer: CGPoint?
  var palette: FramePalette?
  var tabColumns = Indentation.fallback.unit
  /// 面の大きさ（pt）と倍率。
  var size = CGSize.zero
  var scale: CGFloat = 2
  /// 描く色空間。面が載る窓の色空間（AppKit が窓の view を描く色空間）で、窓に無ければ sRGB。
  var space = FrameMaterial.defaultSpace
  /// 面が画面に見えているか（窓にあり、隠れておらず、窓が覆われていない）。
  var visible = false
  /// 何かが変わるたびに進む。
  var revision = 0

  static let defaultSpace = CGColorSpace(name: CGColorSpace.sRGB)!

  /// 主の場のキャレット——点滅を決める（主が編集の場でなければ、焦点の無い本文のキャレット）。
  var primaryCaret: CaretMaterial {
    guard !caret.focused else { return caret }
    return fields.values.first { $0.caret.focused }?.caret ?? caret
  }

  /// 本文の編集を積む（描画スレッドが長く受け取らなければ、全部の行が変わったことにまとめる）。
  mutating func note(_ edit: RowEdit) {
    rowEdits = rowEdits.count < 64 ? rowEdits + [edit] : [.all(version: edit.version)]
  }
}

/// 描く材料の箱。鍵の中では値の読み書きだけをする。書くのは main（面の取引）だけで、描画スレッドは読んで引き取るだけ
/// （版を進めない）——main は次の版を書く前に知れる。
final class MaterialBox: Sendable {
  private let state = OSAllocatedUnfairLock(initialState: FrameMaterial())

  /// 今の版。
  var revision: Int { state.withLock { $0.revision } }

  /// 書き換えて版を進め、進めた後の版を返す。書き換える前の写し（本文と差し込んだ行の出どころ）は裏で手放す——文書が役割の
  /// 並びを丸ごと差し替えた後は、箱が古い並びの最後の持ち主になりうる（大きな木の解放を main で行わない）。
  @discardableResult
  func update(_ body: @Sendable (inout FrameMaterial) -> Void) -> Int {
    let (revision, before) = state.withLock { material in
      let before = Copies(content: material.content, rowSource: material.rowSource)
      body(&material)
      material.revision += 1
      return (material.revision, before)
    }
    let parcel = OSAllocatedUnfairLock<Copies?>(initialState: before)
    DispatchQueue.global(qos: .utility).async { parcel.withLock { $0 = nil } }
    return revision
  }

  /// 書き換える前の写し（裏で手放す。配列にしない——打鍵ごとの書き換えで main に確保を足さない）。
  private struct Copies: Sendable {
    let content: SurfaceContent?
    let rowSource: SurfaceContent?
  }

  func read() -> FrameMaterial { state.withLock { $0 } }

  /// 描画スレッドが読み、まだ受け取っていない本文の編集と打鍵を引き取る。
  func take() -> FrameMaterial {
    state.withLock {
      let material = $0
      $0.rowEdits.removeAll()
      $0.keystrokes.removeAll()
      return material
    }
  }

  /// 中身を空にする（面を閉じたとき描画スレッドで呼び、写しの最後の解放をそこで行う）。
  func clear() -> FrameMaterial {
    state.withLock {
      let old = $0
      $0 = FrameMaterial()
      return old
    }
  }
}
