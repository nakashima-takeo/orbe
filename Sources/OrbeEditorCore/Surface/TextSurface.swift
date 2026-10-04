import AppKit

/// 文字を描き編集を受ける面の、エンジン非依存の契約。undo・選択・スクロールの正は面にある。契約に面の本文を読む口は
/// 無い——面は編集の通知で置換後の文字列を渡し、Orbe の中で本文を読むのは文書の写し（ロープ）だけ。文書は面の delegate
/// として編集を受け、役割が変わった区間と行の印を知らせる。面は本文を持たず、文書の写し（`surfaceContent`）を引いて
/// 描く（役割→色だけを知る）。
@MainActor
public protocol TextSurface: AnyObject {
  /// 器へ載せる view（スクロールを含む全体）。
  var view: NSView { get }
  /// first responder にする view。
  var responder: NSView { get }

  /// 見えている範囲を本文の言葉で（面の pt は出ない）。
  var viewport: TextViewport { get }

  /// 右列（ミニマップ＋縦スクロールバー）の幅（pt）。面は俯瞰（ミニマップ・縦横のスクロールバーと印・影）を自分で描き、
  /// 載せる側は面の上に浮かべる部品（検索バー）をこの幅から置く。本文の座標ではなく view の配置の事実で、view の幅と
  /// 行番号の列の桁で変わる。載せる側は大きさを変えたときと見えている範囲の知らせで読み直す（本文の変化の知らせの中では
  /// 変化の前の幅を答える）。
  var rightColumnWidth: CGFloat { get }

  /// 区間を見せる——縦は方針 `policy` で、横は区間が見えるところまで最小限にスクロールする（区間が 1 行の中なら区間の
  /// 両端、行をまたぐなら先頭。スクロールできる範囲の端で止まる）。判定は面の最新の位置（まだ描いていない位置を含む）で
  /// 行う。選択は動かさない。
  func reveal(_ range: NSRange, policy: TextReveal)

  /// 選択（UTF-16）。置いても見せない——見せるのは `reveal`。
  var selectedRange: NSRange { get set }

  /// キャレットのオフセット——選択の動く側の端（前へ伸ばした選択なら先頭、それ以外は終わり。選択が空ならその位置）。
  var caretLocation: Int { get }

  /// 全カーソルの選択（主が先頭。カーソルが 1 本なら `selectedRange` だけ）。読むだけで、外から置く選択は `selectedRange`
  /// の 1 本。
  var cursorSelections: [NSRange] { get }

  /// 続いている ⌘D・⌘⇧L の問い（続いていなければ nil）。選択文字列の出現の強調が、⌘D と同じ問いで出すために読む。
  var searchContinuation: SearchQuestion? { get }

  /// 強調の地（種類ごと）。選択の地の上・文字の下に描く。本文と undo に載らない描画で、次に置き直すか空を置くまで
  /// 残る。`ranges` は昇順・重ならないこと（面は二分探索で可視ぶんだけ描く）。現在の一致の行は行全体にも地が付く。
  func setHighlights(_ ranges: [NSRange], for kind: TextHighlightKind)

  /// 字下げの作法（単位とタブか）。文書が本文から検出して押し、面は単位をタブの表示幅と装備の段に写す。編集する面は、
  /// Tab で入れる字（空白かタブか）と字下げの幅にも使う。
  func setIndentation(_ indentation: Indentation)

  /// 改行の作法。文書が本文から検出して押す。編集する面は、Enter で入れる改行と、貼る・落とす文字列の改行に使う。
  func setLineBreak(_ lineBreak: LineBreak)

  /// undo の履歴にここで区切りを置く。打鍵のまとまりは区切りをまたがない
  /// （保存が呼ぶ——⌘Z が保存前の打鍵まで一緒に戻さないため）。
  func markUndoBoundary()

  /// 変換中の IME の文字を確定する（変換中でなければ何もしない）。未確定の文字は既に本文にあるので、本文は変わらない
  /// ——変換の状態と IME の状態を揃える。載せる側が、面の外へ焦点や読み取りが移るコマンドを走らせる前に呼ぶ。
  func commitMarkedText()

  /// 本文を丸ごと置き換える編集。通常の編集と同じく undo に載り、`didChange` を呼び出しから
  /// 戻るまでに同期で 1 回通す（外部で書き換えられたファイルの差し替えが呼ぶ——文書の写し・構文・ハンクが
  /// 打鍵と同じ経路で追従する）。変換中の IME セッションは置き換える前に畳む（その取り消しの `didChange`
  /// が 1 回先に通る）。置き換え後の選択は解け、キャレットは同じオフセット（本文が短ければ末尾）。
  func replaceAll(with text: String)

  /// 役割が変わった（裏から届いた役割で）。面は区間に掛かる行を描き直す。
  func rolesDidChange(_ ranges: IndexSet)

  /// 行の印（git ガター）。文書がハンクから作って押す（UTF-16 オフセット）。面は描くだけで規則を持たない。
  func setLineMarks(_ spans: LineMarkSpans)

  /// 面を載せる側（弱い参照）。面が本文の外のこと（ファイルを開く・パスの文字列・右クリックのメニュー・URL）を問う口。
  var host: TextSurfaceHost? { get set }

  var delegate: TextSurfaceDelegate? { get set }
}

/// 面を載せる側——開くこと・根・言語は載せる側の関心で、面は知らない。面はそれらをこの口で問う。
@MainActor
public protocol TextSurfaceHost: AnyObject {
  /// ファイルを開く（Finder から本文へ落とされた）。
  func openFiles(_ urls: [URL])
  /// ファイルのパスを本文に入れる文字列（⇧ を押して落とされた・Finder でコピーしたファイルを貼った）。
  func insertionText(forFiles urls: [URL]) -> String
  /// 右クリックのメニュー。項目は target を持たず、焦点の面へ届く。
  func contextMenu() -> NSMenu
  /// 本文の URL が ⌘クリックされた。
  func openLink(_ url: URL)
  /// 面で Esc が押された（変換中でない）。載せる側が使えば true——面は使われなかった Esc だけを自分で使う（カーソルを
  /// 1 本に戻す・選択を解く）。順序は VS Code と同じく、載せる側の部品（検索バー）が先。
  func consumeEscape() -> Bool
}

@MainActor
public protocol TextSurfaceDelegate: AnyObject {
  /// 本文が変わった（置換後の文字列つき）。面の本文のすべての変更がここを通る。1 回の操作の編集を束で渡す——束は重ならない
  /// 昇順の列で、どの範囲も束の前の本文の座標で書く（VS Code の編集の適用と同じ）。
  func surface(_ surface: any TextSurface, didChange edits: [TextEdit])
  func surface(_ surface: any TextSurface, focusDidChange focused: Bool)
  /// `viewport` が変わった（スクロール・窓の高さ）。
  func surfaceDidChangeViewport(_ surface: any TextSurface)
  /// 選択が変わった——どれかのカーソルの選択か、続いている ⌘D の問いが変わった。
  func surfaceDidChangeSelection(_ surface: any TextSurface)
  /// 文書の写し（本文・役割の並び・版）。面が、結ばれたとき・`rolesDidChange` と `setLineMarks` を受けたとき・自分が
  /// 出した編集の通知から戻ったときに引いて描く。文書はどの知らせも自分の写しを更新した後に出すので、
  /// 引いた写しは知らせと同じ版。
  func surfaceContent(_ surface: any TextSurface) -> SurfaceContent
}

/// 文書の写し——本文のロープ・役割の並び・版の組。値として写すのは O(1) で、変わらないので、描画のスレッドがロックも
/// 複写も無しで読める。
public struct SurfaceContent: Sendable {
  public let text: TextRope
  public let roles: RoleRuns
  public let version: Int

  public init(text: TextRope, roles: RoleRuns, version: Int) {
    self.text = text
    self.roles = roles
    self.version = version
  }
}

/// 強調の地の種類。重ね順は下から 選択文字列の出現 → 語の出現 → 検索の一致 → 現在の一致（現在の一致の行全体の地は
/// それらより下）。
public enum TextHighlightKind: Sendable {
  case selectionOccurrence
  case wordOccurrence
  case findMatch
  case currentFindMatch
}

/// 見えている範囲を本文の言葉で表したもの。`firstVisible` は先頭に見えている行（文書の行）の行頭オフセット、
/// `visibleLines` は見えている高さに入る行数（小数）。文書の構文が、見えている行を先に解くのに使う。
public struct TextViewport: Equatable, Sendable {
  public var firstVisible: Int
  public var visibleLines: CGFloat

  public init(firstVisible: Int, visibleLines: CGFloat) {
    self.firstVisible = firstVisible
    self.visibleLines = visibleLines
  }

  public static let empty = TextViewport(firstVisible: 0, visibleLines: 0)
}

/// 面の見え方。色は名前付き（dynamic）の NSColor を渡し、外観は描画時に解く。装備と俯瞰の寸法と色もここで渡し、
/// エンジンは値を持たない。
public struct TextSurfaceStyle {
  public var font: NSFont
  /// 行の高さ（pt）。フォントの自然な行高に依らず固定する。
  public var lineHeight: CGFloat
  /// 本文の上端の余白。
  public var topInset: CGFloat
  /// 役割を持たない文字の色。
  public var textColor: NSColor
  /// 本文の地の不透明な色。面は地を描かず下を透かす。色付きで書き出す（コピーの HTML）ときの地に使う。
  public var backgroundColor: NSColor
  public var caretColor: NSColor
  public var caretSize: CGSize
  /// 選択の地の色。焦点が無い面では `inactiveSelectionColor`。
  public var selectionColor: NSColor
  public var inactiveSelectionColor: NSColor
  public var gutterFont: NSFont
  public var gutterTextColor: NSColor
  /// 行番号の数字の部分の幅（右の印の列を除く）。最大の行番号と右の余白（`gutterTrailingInset`）がこの幅に収まる
  /// 限り、列は広がらない。
  public var gutterWidth: CGFloat
  /// 行番号の右端と本文の間。
  public var gutterTrailingInset: CGFloat
  public var roleColors: [SyntaxRole: NSColor]
  public var marks: Marks
  public var decorations: Decorations
  public var highlights: Highlights
  public var overview: Overview

  /// git ガター（行番号の右の列）の見え方。色は α 込み。
  public struct Marks {
    public var gutterWidth: CGFloat
    public var barWidth: CGFloat
    /// 列の左端からバーの左端まで。
    public var barInset: CGFloat
    public var barRadius: CGFloat
    /// 削除の三角（右向き）の一辺。
    public var triangleSize: CGFloat
    public var added: NSColor
    public var modified: NSColor
    public var removed: NSColor

    public init(
      gutterWidth: CGFloat, barWidth: CGFloat, barInset: CGFloat, barRadius: CGFloat,
      triangleSize: CGFloat, added: NSColor, modified: NSColor, removed: NSColor
    ) {
      self.gutterWidth = gutterWidth
      self.barWidth = barWidth
      self.barInset = barInset
      self.barRadius = barRadius
      self.triangleSize = triangleSize
      self.added = added
      self.modified = modified
      self.removed = removed
    }
  }

  /// 本文に重なる装備（空白の丸点・URL の下線）の見え方。
  public struct Decorations {
    public var whitespaceColor: NSColor
    public var whitespaceDiameter: CGFloat
    public var linkUnderlineThickness: CGFloat
    /// ベースラインから下線の上端まで。
    public var linkUnderlineOffset: CGFloat

    public init(
      whitespaceColor: NSColor, whitespaceDiameter: CGFloat, linkUnderlineThickness: CGFloat,
      linkUnderlineOffset: CGFloat
    ) {
      self.whitespaceColor = whitespaceColor
      self.whitespaceDiameter = whitespaceDiameter
      self.linkUnderlineThickness = linkUnderlineThickness
      self.linkUnderlineOffset = linkUnderlineOffset
    }
  }

  /// 強調の地の色（α 込み。行の高さいっぱい・角なしで塗る）。選択文字列の出現は面に焦点が無いときだけ
  /// `selectionOccurrenceInactive`。現在の一致の行全体は `currentFindLine`。
  public struct Highlights {
    public var findMatch: NSColor
    public var currentFindMatch: NSColor
    public var currentFindLine: NSColor
    public var selectionOccurrence: NSColor
    public var selectionOccurrenceInactive: NSColor
    public var wordOccurrence: NSColor

    public init(
      findMatch: NSColor, currentFindMatch: NSColor, currentFindLine: NSColor,
      selectionOccurrence: NSColor, selectionOccurrenceInactive: NSColor, wordOccurrence: NSColor
    ) {
      self.findMatch = findMatch
      self.currentFindMatch = currentFindMatch
      self.currentFindLine = currentFindLine
      self.selectionOccurrence = selectionOccurrence
      self.selectionOccurrenceInactive = selectionOccurrenceInactive
      self.wordOccurrence = wordOccurrence
    }
  }

  /// 俯瞰の見え方——寸法・色（α 込み）・帯とつまみの現れる・消える時間。字の明るさの係数と全体の不透明度は VS Code の
  /// 規則で、見え方ではない（→ `MinimapCharSheet`）。
  public struct Overview {
    public var minimap: Minimap
    public var scrollbar: Scrollbar
    /// 先頭の行が上へ隠れている間の本文の上端の影と、本文が右に続くときのミニマップの左端の影の色。
    public var topShadow: NSColor
    public var minimapShadow: NSColor
    /// 帯とつまみが現れる時間・つまみが消える時間・スクロールが止まってからつまみが消え始めるまで（秒）。
    public var fadeIn: Double
    public var fadeOut: Double
    public var hideDelay: Double

    public init(
      minimap: Minimap, scrollbar: Scrollbar, topShadow: NSColor, minimapShadow: NSColor,
      fadeIn: Double, fadeOut: Double, hideDelay: Double
    ) {
      self.minimap = minimap
      self.scrollbar = scrollbar
      self.topShadow = topShadow
      self.minimapShadow = minimapShadow
      self.fadeIn = fadeIn
      self.fadeOut = fadeOut
      self.hideDelay = hideDelay
    }
  }

  /// ミニマップ——幅の上限と、帯（普段・帯の上・ドラッグ中）・選択・検索の一致・語の出現・git の印の色。
  public struct Minimap {
    public var maxWidth: CGFloat
    public var slider: NSColor
    public var sliderHover: NSColor
    public var sliderActive: NSColor
    public var selection: NSColor
    public var findMatch: NSColor
    public var wordOccurrence: NSColor
    public var added: NSColor
    public var modified: NSColor
    public var removed: NSColor

    public init(
      maxWidth: CGFloat, slider: NSColor, sliderHover: NSColor, sliderActive: NSColor,
      selection: NSColor, findMatch: NSColor, wordOccurrence: NSColor, added: NSColor,
      modified: NSColor, removed: NSColor
    ) {
      self.maxWidth = maxWidth
      self.slider = slider
      self.sliderHover = sliderHover
      self.sliderActive = sliderActive
      self.selection = selection
      self.findMatch = findMatch
      self.wordOccurrence = wordOccurrence
      self.added = added
      self.modified = modified
      self.removed = removed
    }
  }

  /// スクロールバー——縦の幅・横の高さと、つまみ（普段・つまみの上・ドラッグ中）・印（縁・検索の一致・語の出現・git・
  /// キャレット）の色。
  public struct Scrollbar {
    public var width: CGFloat
    public var horizontalHeight: CGFloat
    public var slider: NSColor
    public var sliderHover: NSColor
    public var sliderActive: NSColor
    public var border: NSColor
    public var findMatch: NSColor
    public var wordOccurrence: NSColor
    public var added: NSColor
    public var modified: NSColor
    public var removed: NSColor
    public var caret: NSColor

    public init(
      width: CGFloat, horizontalHeight: CGFloat, slider: NSColor, sliderHover: NSColor,
      sliderActive: NSColor, border: NSColor, findMatch: NSColor, wordOccurrence: NSColor,
      added: NSColor, modified: NSColor, removed: NSColor, caret: NSColor
    ) {
      self.width = width
      self.horizontalHeight = horizontalHeight
      self.slider = slider
      self.sliderHover = sliderHover
      self.sliderActive = sliderActive
      self.border = border
      self.findMatch = findMatch
      self.wordOccurrence = wordOccurrence
      self.added = added
      self.modified = modified
      self.removed = removed
      self.caret = caret
    }
  }

  public init(
    font: NSFont, lineHeight: CGFloat, topInset: CGFloat, textColor: NSColor,
    backgroundColor: NSColor, caretColor: NSColor, caretSize: CGSize, selectionColor: NSColor,
    inactiveSelectionColor: NSColor, gutterFont: NSFont, gutterTextColor: NSColor,
    gutterWidth: CGFloat, gutterTrailingInset: CGFloat,
    roleColors: [SyntaxRole: NSColor], marks: Marks, decorations: Decorations,
    highlights: Highlights, overview: Overview
  ) {
    self.font = font
    self.lineHeight = lineHeight
    self.topInset = topInset
    self.textColor = textColor
    self.backgroundColor = backgroundColor
    self.caretColor = caretColor
    self.caretSize = caretSize
    self.selectionColor = selectionColor
    self.inactiveSelectionColor = inactiveSelectionColor
    self.gutterFont = gutterFont
    self.gutterTextColor = gutterTextColor
    self.gutterWidth = gutterWidth
    self.gutterTrailingInset = gutterTrailingInset
    self.roleColors = roleColors
    self.marks = marks
    self.decorations = decorations
    self.highlights = highlights
    self.overview = overview
  }
}
