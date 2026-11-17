import AppKit

/// 絵の差し込み——面の縦の並びの、文書の行と行の間に置き、載せる側が絵を描くもの（→ `RowInsertion.Content.zone`。PR の
/// スレッドなど）。面は載せる側から view でなく絵（`ZonePicture`）を受け、本文と同じ 1 コマに描く。絵の差し込みと本文が
/// ずれて動く余地は無い。
///
/// 面は本文の区画の幅を渡して絵を問い（置いたとき・幅が変わったとき・`TextSurface.redrawZone` のとき）、返った高さを
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

/// 角の丸い矩形（円は、半径が辺の半分の箱）。角の半径は角ごとに持てる。塗り・枠線・影はどれも省ける。枠線は箱の内側に
/// 引く。影は箱の外へはみ出してよい（CSS の box-shadow と同じく、絵の差し込みの外の行にも落ちる）。
public struct ZoneBox {
  public var frame: CGRect
  public var radius: Radius
  public var fill: NSColor?
  public var stroke: Stroke?
  public var shadow: Shadow?

  /// 角ごとの半径（どの角も、短い辺の半分を超える分は短い辺の半分に収める）。数の字は 4 つの角に同じ半径。
  public struct Radius: Equatable, ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral {
    public var topLeft: CGFloat
    public var topRight: CGFloat
    public var bottomRight: CGFloat
    public var bottomLeft: CGFloat

    public init(topLeft: CGFloat, topRight: CGFloat, bottomRight: CGFloat, bottomLeft: CGFloat) {
      self.topLeft = topLeft
      self.topRight = topRight
      self.bottomRight = bottomRight
      self.bottomLeft = bottomLeft
    }

    /// 上の 2 角と下の 2 角。
    public init(top: CGFloat, bottom: CGFloat) {
      self.init(topLeft: top, topRight: top, bottomRight: bottom, bottomLeft: bottom)
    }

    public init(_ radius: CGFloat) {
      self.init(top: radius, bottom: radius)
    }

    public init(floatLiteral value: Double) { self.init(CGFloat(value)) }
    public init(integerLiteral value: Int) { self.init(CGFloat(value)) }
  }

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
    frame: CGRect, radius: Radius = 0, fill: NSColor? = nil, stroke: Stroke? = nil,
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

/// 選べる文のまとまり——id（描き直しをまたいで載せる側が安定に保つ値。絵の差し込みの中で一意）と、見え方つきの文と、文を
/// 描く行の列。
public struct ZoneText {
  public var id: AnyHashable
  public var content: ZoneStyledText
  public var lines: [ZoneSelectableLine]

  public init(id: AnyHashable, content: ZoneStyledText, lines: [ZoneSelectableLine]) {
    self.id = id
    self.content = content
    self.lines = lines
  }
}

/// 見え方つきの文——字の連なりを、見え方とともに先頭から順に足して作る。見え方の長さは足した字の連なりの長さで決まるので、
/// 見え方は文の全部を、余りも重なりもなく覆う。どのスレッドへも渡せる。
public struct ZoneStyledText: Equatable, Sendable {
  public private(set) var string = ""
  /// 見え方（文の先頭から順に。長さは足した字の連なりの UTF-16 の長さ）。
  public private(set) var styles: [ZoneTextStyle] = []

  public init() {}

  /// 字の連なりと見え方の組を、順に足したもの。
  public init(_ runs: [(String, ZoneTextStyle)]) {
    for (string, style) in runs { append(string, style) }
  }

  /// 字の連なり `string` を見え方 `style` で後ろに足す。
  public mutating func append(_ string: String, _ style: ZoneTextStyle) {
    var style = style
    style.length = string.utf16.count
    self.string += string
    styles.append(style)
  }

  /// 文は UTF-16 の単位で比べる（String の == は正準等価で比べ、字の並びの違う文を同じとみなす）。
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.styles == rhs.styles && lhs.string.utf16.elementsEqual(rhs.string.utf16)
  }
}

/// 字の見え方。見え方つきの文の中で、文の先頭から順に `length` 単位（UTF-16）ずつ当てる。余白（pt）は連なりの左右の字を
/// その幅ずつ押し出す（CSS のインラインの padding）。余白のある見え方は、周りの文と独立した向きのかたまりとして並び、先頭の余白は
/// かたまりの向きの始まりの側に、末尾の余白はその反対の側に付く——右から左の字のコードでも、余白はコードの外に出る。
/// 地は、余白を含めたかたまりの x 範囲に置く（→ `ZoneTextLayout.Line.spans(of:)`）。折り返しで割れた側と、改行で割れた
/// 側には余白が付かない。
///
/// 字体は CTFont で持ち（載せる側の NSFont は、ここで受けるときに CTFont として持つ）、値はどのスレッドへも渡せる。
public struct ZoneTextStyle: Equatable, Sendable {
  /// 当てる長さ（UTF-16 の単位。見え方つきの文に足すときに決まる）。
  public internal(set) var length = 0
  public var font: CTFont {
    get { typeface.font }
    set { typeface = Typeface(font: newValue) }
  }
  public var color: NSColor
  public var leadingPadding: CGFloat
  public var trailingPadding: CGFloat
  private var typeface: Typeface

  public init(font: NSFont, color: NSColor, padding: CGFloat = 0) {
    self.typeface = Typeface(font: font as CTFont)
    self.color = color
    self.leadingPadding = padding
    self.trailingPadding = padding
  }

  /// 字体。Core Text は字体のオブジェクト（CTFont・CTFontDescriptor）を複数のスレッドから同時に使えると保証する
  /// （CTFont は不変で、変える API が無い）。SDK は CTFont を Sendable と宣言しないので、検査を外すのはこの型だけにする。
  private struct Typeface: Equatable, @unchecked Sendable {
    let font: CTFont
  }
}

/// 選べる字の行——まとまりの文の範囲 `range` を、基線の左端 `origin` から描く（折り返さない）。字と見え方はまとまりから
/// 引く（文の正は 1 か所）。行は、まとまりの文の中で範囲を含む段落を組んだものから切り出す（→ `ZoneTextLayout.lines(of:)`）。
public struct ZoneSelectableLine {
  public var origin: CGPoint
  public var range: NSRange

  public init(origin: CGPoint, range: NSRange) {
    self.origin = origin
    self.range = range
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
