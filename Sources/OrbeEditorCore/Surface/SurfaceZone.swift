import AppKit

/// 区画——面の縦の並びの、文書の行と行の間に置く載せる側の絵（→ `RowInsertion.Content.zone`。PR のスレッドなど）。面は
/// 区画を view でなく絵として受け、本文と同じ 1 コマに描く（区画と本文がずれて動く余地が無い）。
///
/// 面は本文の区画の幅を渡して絵を問い（差し込んだとき・幅が変わったとき・`TextSurface.redrawZone` のとき）、絵の高さを
/// 区画の高さにする。配置の仕組みは持たない——要素の座標は載せる側が区画の中の pt で決める（字の折り返しは
/// `ZoneTextLayout`）。押せる場所のホバーと押下は `zone(_:)` で載せる側へ知らせる。
@MainActor
public protocol SurfaceZone: AnyObject {
  /// 幅 `width`（本文の区画の幅、pt）で組んだ区画の絵。
  func picture(width: CGFloat) -> ZonePicture
  /// 押せる場所の知らせ。載せる側は見た目を変えるなら `redrawZone` で描き直させる。
  func zone(_ event: ZoneEvent)
}

/// 押せる場所の知らせ（id は `ZoneButton.id`）。
public enum ZoneEvent: Equatable {
  /// ポインタが入った・出た（スクロールで押せる場所がポインタの下へ来た・去ったときも）。
  case entered(AnyHashable)
  case exited(AnyHashable)
  /// 押して、同じ押せる場所で離した。
  case pressed(AnyHashable)
}

/// 区画の絵——高さと、描く順の要素の列と、選べる文のまとまり。座標は区画の左上を原点にした pt（y は下向き）。
public struct ZonePicture {
  public var height: CGFloat
  public var elements: [ZoneElement]
  /// 選べる文のまとまり（コピーで渡す文の正）。描かないので要素の列には入れない——選べる字の行が範囲で指す。
  public var texts: [ZoneText]

  public init(height: CGFloat, elements: [ZoneElement] = [], texts: [ZoneText] = []) {
    self.height = height
    self.elements = elements
    self.texts = texts
  }
}

/// 区画の要素。重ね順は種類で決まる（下から 箱 → 画像 → 選んだ文の地 → 字 → 入力欄の中身）。同じ種類の中は列の順。
public enum ZoneElement {
  case box(ZoneBox)
  case text(ZoneTextLine)
  case selectable(ZoneSelectableLine)
  case image(ZoneImage)
  case button(ZoneButton)
  case field(ZoneField)
}

/// 角の丸い矩形（円は、半径が辺の半分の箱）。塗り・枠線・影はどれも省ける。枠線は箱の内側に引き、影は箱の外へはみ出して
/// よい（CSS の box-shadow と同じく、区画の外の行にも落ちる）。
public struct ZoneBox {
  public var frame: CGRect
  public var radius: CGFloat
  public var fill: NSColor?
  public var stroke: Stroke?
  public var shadow: Shadow?

  public struct Stroke {
    public var color: NSColor
    public var width: CGFloat

    public init(color: NSColor, width: CGFloat) {
      self.color = color
      self.width = width
    }
  }

  /// 縦のずれ `offset` とぼかし `blur`（CSS の blur radius）の影。
  public struct Shadow {
    public var color: NSColor
    public var offset: CGFloat
    public var blur: CGFloat

    public init(color: NSColor, offset: CGFloat, blur: CGFloat) {
      self.color = color
      self.offset = offset
      self.blur = blur
    }
  }

  public init(
    frame: CGRect, radius: CGFloat = 0, fill: NSColor? = nil, stroke: Stroke? = nil,
    shadow: Shadow? = nil
  ) {
    self.frame = frame
    self.radius = radius
    self.fill = fill
    self.stroke = stroke
    self.shadow = shadow
  }
}

/// 字の連なり 1 つ（折り返さない）。
public struct ZoneTextRun {
  public var string: String
  public var font: NSFont
  public var color: NSColor

  public init(_ string: String, font: NSFont, color: NSColor) {
    self.string = string
    self.font = font
    self.color = color
  }
}

/// 字の行（選べない）。`origin` は基線の左端。
public struct ZoneTextLine {
  public var origin: CGPoint
  public var runs: [ZoneTextRun]

  public init(origin: CGPoint, runs: [ZoneTextRun]) {
    self.origin = origin
    self.runs = runs
  }
}

/// 選べる文のまとまり——id（描き直しをまたいで載せる側が安定に保つ値。区画の中で一意）と文。
public struct ZoneText {
  public var id: AnyHashable
  public var string: String

  public init(id: AnyHashable, string: String) {
    self.id = id
    self.string = string
  }
}

/// 字の見え方を、文の範囲の先頭から順に `length` 単位（UTF-16）ずつ当てたもの。余白（pt）は連なりの前後の字をその幅ずつ
/// 押し出す（CSS のインラインの左右の padding。地は連なりの字の x 範囲をこの幅ずつ広げて置く）。折り返しで割れた側には
/// 付かない（→ `ZoneTextLayout.styles(_:in:)`）。
public struct ZoneTextStyle: Equatable {
  public var length: Int
  public var font: NSFont
  public var color: NSColor
  public var leadingPadding: CGFloat
  public var trailingPadding: CGFloat

  public init(length: Int, font: NSFont, color: NSColor, padding: CGFloat = 0) {
    self.length = length
    self.font = font
    self.color = color
    self.leadingPadding = padding
    self.trailingPadding = padding
  }
}

/// 選べる字の行——まとまり `text` の文の範囲 `range` を、基線の左端 `origin` から描く。字はまとまりの文から引く（文の正は
/// 1 か所）。
public struct ZoneSelectableLine {
  public var origin: CGPoint
  public var text: AnyHashable
  public var range: NSRange
  public var styles: [ZoneTextStyle]

  public init(origin: CGPoint, text: AnyHashable, range: NSRange, styles: [ZoneTextStyle]) {
    self.origin = origin
    self.text = text
    self.range = range
    self.styles = styles
  }
}

/// 画像（矩形に合わせて、画面の倍率で描く）。描く画素の辺は 511px まで（2x の画面で 255.5pt。超えれば描かない）。
public struct ZoneImage {
  public var frame: CGRect
  public var image: NSImage

  public init(frame: CGRect, image: NSImage) {
    self.frame = frame
    self.image = image
  }
}

/// 押せる場所——id（描き直しをまたいで安定。区画の中で一意）・矩形・上にあるときのポインタの形。
public struct ZoneButton {
  public var id: AnyHashable
  public var frame: CGRect
  public var cursor: NSCursor

  public init(id: AnyHashable, frame: CGRect, cursor: NSCursor = .pointingHand) {
    self.id = id
    self.frame = frame
    self.cursor = cursor
  }
}

/// 入力欄——文を打つ矩形（入力欄の枠は載せる側が箱で描く）と入力欄の型。入力欄は面の中の id（`ZoneTextField.id`）で
/// 1 つで、同じ id には描き直しをまたいで同じ型の参照を渡す。
public struct ZoneField {
  public var frame: CGRect
  public var field: ZoneTextField

  public init(frame: CGRect, field: ZoneTextField) {
    self.frame = frame
    self.field = field
  }
}
