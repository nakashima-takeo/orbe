import AppKit

/// 区画の入力欄の型——入力欄の文の出どころ（`SiteText`）と見え方。打鍵・IME・undo は面が本文と同じ編集の仕組みで行い、
/// 文はここに持つ。文が変われば `didChange` を同期で呼ぶ——その中で載せる側が `redrawZone` を呼べば、伸びた入力欄と打った字
/// が同じコマに出る。入力欄は折り返さない（改行で行が増え、載せる側が入力欄を高くする。長い行は横に送る）。
@MainActor
public final class ZoneTextField: SiteText {
  /// 面の中で入力欄を指す id（面の中で一意。区画の絵の `ZoneField` はこの型を渡す）。
  public let id: AnyHashable
  public let style: Style
  public private(set) var text: TextRope
  private var version = 0
  private var roles: RoleRuns

  /// 文が変わった（打鍵・貼る・undo・置き換え）。
  public var didChange: ((ZoneTextField) -> Void)?
  /// 主（キーと IME の行き先）になった（true）・外れた（false）。
  public var didChangePrimary: ((ZoneTextField, Bool) -> Void)?

  /// 入力欄の見え方。色は名前付き（dynamic）の色で、外観は面が解く。
  public struct Style {
    public var font: NSFont
    /// 行の高さ（pt）。
    public var lineHeight: CGFloat
    public var textColor: NSColor
    public var caretColor: NSColor
    public var selectionColor: NSColor
    /// 入力欄が主でないか、面に焦点が無いときの選択の地。
    public var inactiveSelectionColor: NSColor

    public init(
      font: NSFont, lineHeight: CGFloat, textColor: NSColor, caretColor: NSColor,
      selectionColor: NSColor, inactiveSelectionColor: NSColor
    ) {
      self.font = font
      self.lineHeight = lineHeight
      self.textColor = textColor
      self.caretColor = caretColor
      self.selectionColor = selectionColor
      self.inactiveSelectionColor = inactiveSelectionColor
    }
  }

  public init(id: AnyHashable, text: String = "", style: Style) {
    self.id = id
    self.style = style
    self.text = TextRope(text)
    roles = RoleRuns(length: self.text.length)
  }

  /// 今の文。
  public var string: String { text.substring(NSRange(location: 0, length: text.length)) }

  /// 行の数（改行で割った行）。
  public var lineCount: Int { text.lineCount }

  public func apply(_ edits: [TextEdit]) {
    for edit in edits.reversed() { text.replace(edit.range, with: edit.replacement) }
    version += 1
    roles = RoleRuns(length: text.length)
    didChange?(self)
  }

  public var content: SurfaceContent? {
    SurfaceContent(text: text, roles: roles, version: version)
  }
}
