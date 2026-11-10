import AppKit

/// 絵の差し込み——面の縦の並びの、文書の行と行の間に置き、載せる側が絵を描くもの（→ `RowInsertion.Content.zone`。PR の
/// スレッドなど）。面は載せる側から view でなく絵（`ZonePicture`）を受け、本文と同じ 1 コマに描く。絵の差し込みと本文が
/// ずれて動く余地は無い。
///
/// 面は本文の区画の幅を渡して中身を問い（置いたとき・幅が変わったとき・`TextSurface.redrawZone` のとき）、返った高さを
/// 絵の差し込みの高さにする。面は配置の仕組みを持たない。要素の座標は、載せる側が絵の差し込みの中の pt で決める（字の
/// 折り返しは `ZoneTextLayout`）。押せる場所のホバーと押下は `zone(_:)` で載せる側へ知らせる。
@MainActor
public protocol SurfaceZone: AnyObject {
  /// 幅 `width`（本文の区画の幅、pt）で組んだ絵。
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

/// 載せる側が描く絵——高さと、要素の列（重ね順は種類で決まる → `ZoneElement`）と、選べる文のまとまり。座標は、
/// 絵の差し込みの左上を原点にした pt（y は下向き）。
public struct ZonePicture {
  public var height: CGFloat
  public var elements: [ZoneElement]
  /// 選べる文のまとまり——文と、それを描く行。コピーで渡す文の正。
  public var texts: [ZoneText]

  public init(height: CGFloat, elements: [ZoneElement] = [], texts: [ZoneText] = []) {
    self.height = height
    self.elements = elements
    self.texts = texts
  }
}

/// 絵の差し込みの要素。重ね順は種類で決まる（下から 箱 → 画像 → 選んだ文の地 → 字 → 入力欄の中身）。同じ種類の中は
/// 列の順。
public enum ZoneElement {
  case box(ZoneBox)
  case text(ZoneTextLine)
  case image(ZoneImage)
  case button(ZoneButton)
  case field(ZoneField)
}

/// 角の丸い矩形（円は、半径が辺の半分の箱）。塗り・枠線・影はどれも省ける。枠線は箱の内側に引く。影は箱の外へはみ
/// 出してよい（CSS の box-shadow と同じく、絵の差し込みの外の行にも落ちる）。
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

/// 選べる文のまとまり——id（描き直しをまたいで載せる側が安定に保つ値。絵の差し込みの中で一意）と文と、文を描く行の列。
public struct ZoneText {
  public var id: AnyHashable
  public var string: String
  public var lines: [ZoneSelectableLine]

  public init(id: AnyHashable, string: String, lines: [ZoneSelectableLine]) {
    self.id = id
    self.string = string
    self.lines = lines
  }
}

/// 字の見え方を、文の範囲の先頭から順に `length` 単位（UTF-16）ずつ当てたもの。余白（pt）は連なりの左右の字をその幅ずつ
/// 押し出す（CSS のインラインの padding）。地は、連なりの字の x 範囲を余白の幅ずつ広げて置く（→ `ZoneTextLayout.Line`
/// の `ground(_:)`）。先頭の余白は段落の向きの始まりの側（左から右の段落では左、右から左の段落では右）に、末尾の余白は
/// その反対の側に付く。余白は組版で 1 つにまとまる字の塊の外に付き、絵文字や結合文字を割らない。ただし、余白に接する
/// 字の塊にタイ語の ำ やラオ語の ຳ（1 字を 2 つのグリフで描く字）が入ると、塊の中にも余白の幅の隙間ができる。折り返しで
/// 割れた側には付かない（→ `ZoneTextLayout.styles(_:in:)`）。
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

/// 選べる字の行——まとまりの文の範囲 `range` を、基線の左端 `origin` から描く（折り返さない）。字はまとまりの文から引く
/// （文の正は 1 か所）。行は、まとまりの文の中で範囲を含む段落の向きで組む（→ `ZoneTextLayout.Line`）。
public struct ZoneSelectableLine {
  public var origin: CGPoint
  public var range: NSRange
  public var styles: [ZoneTextStyle]

  public init(origin: CGPoint, range: NSRange, styles: [ZoneTextStyle]) {
    self.origin = origin
    self.range = range
    self.styles = styles
  }
}

/// 画像（矩形に合わせて、画面の倍率で描く）。描く画素の辺は 511px まで（2x の画面で 255.5pt。超えれば描かない）。同じ
/// 画像は描き直しをまたいで同じ参照で渡す（面は画像の同一性と大きさで描いた画素を使い回す）。
public struct ZoneImage {
  public var frame: CGRect
  public var image: NSImage

  public init(frame: CGRect, image: NSImage) {
    self.frame = frame
    self.image = image
  }
}

/// 押せる場所——id（描き直しをまたいで安定。絵の差し込みの中で一意）・矩形・上にあるときのポインタの形。
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
