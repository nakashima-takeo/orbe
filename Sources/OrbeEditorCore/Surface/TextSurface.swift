import AppKit

/// 文字を描き編集を受ける面の、エンジン非依存の契約。undo・選択・スクロールの正は面にある。契約に面の本文を読む口は
/// 無い——面は編集の通知で置換後の文字列を渡し、Orbe の中で本文を読むのは文書の写し（ロープ）だけ。文書は面の delegate
/// として編集を受け、役割が変わった区間と行の印を知らせる。面は本文を持たず、文書の写し（`surfaceContent`）を引いて
/// 描く（役割→色だけを知る）。
///
/// 面の中で打てる文は本文と区画の入力欄（`ZoneTextField`）で、キーと IME はそのうち 1 つの「主」へ届く（区画の選べる文を
/// 選んでいる間は、どちらにも届かない）。選択・キャレット・カーソル・続く問い・見えている範囲・強調の地・字下げと改行の
/// 作法・丸ごとの置き換え・undo の区切り、と delegate への知らせは本文だけを指す。入力欄を指す口は名前で分ける。
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

  /// 選択（UTF-16）。置いても見せない——見せるのは `reveal`。置くと本文が主になる（区画の文の選択と入力欄から本文へ
  /// 戻る。同じ値でも）。
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

  /// 変換中の IME の文字を確定する（変換中でなければ何もしない。変換は面に 1 つで、主の場——本文か入力欄——のもの）。
  /// 未確定の文字は既に文にあるので、文は変わらない——変換の状態と IME の状態を揃える。載せる側が、面の外へ焦点や
  /// 読み取りが移るコマンドを走らせる前に呼ぶ。
  func commitMarkedText()

  /// 本文を丸ごと置き換える編集。通常の編集と同じく undo に載り（読むだけの面では載せず、それまでの取り消しも捨てる）、
  /// `didChange` を呼び出しから戻るまでに同期で 1 回通す（外部で書き換えられたファイルの差し替えが呼ぶ——文書の写し・
  /// 構文・ハンクが打鍵と同じ経路で追従する）。変換中の IME セッションは置き換える前に畳む（その取り消しの `didChange`
  /// が 1 回先に通る）。置き換え後の選択は解け、キャレットは同じオフセット（本文が短ければ末尾）。
  func replaceAll(with text: String)

  /// 役割が変わった（裏から届いた役割で）。面は区間に掛かる行を描き直す。
  func rolesDidChange(_ ranges: IndexSet)

  /// 行の印（git ガター）。文書がハンクから作って押す（UTF-16 オフセット）。面は描くだけで規則を持たない。
  func setLineMarks(_ spans: LineMarkSpans)

  /// 縦の並びに差し込むもの（文書に無い行・区画）と文書の行の区間の見え方を丸ごと置く。同じ値の押し直しは何もしない。境と
  /// 区間の始まりは置く時点の文書の写しの行で書き、その行の範囲（境は `0...行数`、区間の始まりは `0..<行数` で昇順・重ねない）
  /// に収め（編集の知らせの中なら編集後の写し。面はその編集の境のずらしを知らせの前に済ませている）、差し込みはミニマップを
  /// 出していない面（→ `setPresentation`）にだけ置く。同じ区画は並びに 1 度だけ置き、入力欄の
  /// id は面の中で重ねない。差し込んだ行が指す行は出どころ（`SurfaceRows.source`）の写しの行の範囲に収める——どれを破っても
  /// 呼び手の誤り。行の型の番号が表示の構成の `lineStyles` の外を指せば型なし。出どころの写しは置いたときに引く。
  /// 置いた後は、面自身の編集で境が上の行に付いて動く（境 `line` は
  /// 行 `line`−1 の中身の終わりに付き、そこから始まる編集では動かず、付き先を消した編集では消した区間の始まりの行の後へ
  /// 寄り、付き先より前の編集の行の増減だけずれる。境 0 は動かない。区間の始まりも同じ規則で動き、もう一方の番号は変わらない）。差し込みや区画の高さが変わっても、見えている先頭の
  /// 文書の行は画面の同じ位置に残る。区画は面が保持し（置き直しで外れた区画は手放す）、面の中の本文の区画の幅で絵を問う。
  func setRows(_ rows: SurfaceRows)

  /// 並びの出どころの役割が変わった（裏から届いた役割で。区間は出どころの写しの座標）。面は出どころの写しを引き直し、区間の
  /// 行を指す差し込んだ行を描き直す。
  func rowSourceRolesDidChange(_ ranges: IndexSet)

  /// 区画の中身や状態が変わった——面が今の幅で絵を問い直す（高さが変われば並びを組み直す）。取引の中（面の入力の処理の
  /// 中・入力欄の知らせの中）で呼べば、その取引と同じコマに出る。置いていない区画なら何もしない。
  func redrawZone(_ zone: SurfaceZone)

  /// 入力欄の文を置き換える（送った後に空にするなど）。入力欄の場の丸ごとの置き換えで、前後に undo の区切りを置く。
  func replaceText(of field: ZoneTextField, with text: String)

  /// 入力欄を主（キーと IME の行き先）にする。確定するときに、どの区画の絵にもその入力欄が無ければ本文が主になる。
  func focus(_ field: ZoneTextField)

  /// 表示の構成を置く。差し込みのある面でミニマップを出すのは呼び手の誤り。番号の列・記号の列・印の列で本文の区画の幅が
  /// 変われば、区画の絵を新しい幅で問い直す。
  func setPresentation(_ presentation: SurfacePresentation)

  /// 本文を編集できるか（既定は true）。false の面では、打鍵・削除・IME の変換・カット・ペースト・落とす・undo / redo・
  /// サービスの書き込みが本文を変えず、編集のメニューの項目も無効になる——選択・コピー・検索・スクロールは効く。載せる側の
  /// `replaceAll` は通るが、undo に載らず、それまでの取り消しも捨てる。区画の入力欄は、本文が読むだけでも打てる。
  var isEditable: Bool { get set }

  /// もう 1 枚の面 `other` とスクロールの状態を共にする（並列の diff の 2 面）。2 面は 1 枚の紙として動き、どちらで指を
  /// 動かしても、同じ刻みに同じ縦横の位置を描く。範囲は 2 面の大きい方（縦は並びの高さ、横は最も長い行）。2 面の並びは同じ
  /// 周に置く——同じ周に両面の並びが変われば、見えている先頭の文書の行の保持は先に結んだこの面を基準に 1 回だけ行う。
  /// 同じ周に両面が位置を置けば、後に置いた方を当てる（一方が置いた位置は、出したときに相手の読み取りにも揃う）。いま
  /// 共にしていない同じエンジンの面どうしでだけ結べ（相手が閉じた面は結び直せる）、どちらかの面が閉じれば外れ、残った面は
  /// 自分の範囲に収めた位置を描き直す。
  func shareScroll(with other: any TextSurface)

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
  /// 面の view が first responder になった・外れた（入力欄で打つ間も、面の view が first responder）。
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
