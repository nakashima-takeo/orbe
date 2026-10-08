import Accessibility
import AppKit
import OrbeEditorCore
import QuartzCore
import simd

/// `TextSurface` の Metal 実装（main 側）。本文を持たず、文書の写し（本文・役割・版）を契約の口（`surfaceContent`）で
/// 引いて描く側。main がするのは「出来事をスクロールの状態の箱に書く」「写し・選択・見え方を出す前の状態に積み、出す
/// 1 か所（`flush`）で描く材料の箱に置く」だけで、組版も描画も描画スレッドが行う。写しは自分の欄に持たず、要るとき
/// （`viewport` の計算・編集の規則・行の印の行への写像）は出す前の状態か箱から読む。
///
/// 編集は面の編集の場（`EditingSite`）の編集係（`SurfaceEditor`）が持ち、1 回の操作を 1 つの取引にする（→ `transact`）。
/// IME の変換も同じ道で文書に入る。契約の選択・キャレット・undo の区切り・丸ごとの置き換えは、本文の場を指す。
/// アクセシビリティは持たない。
@MainActor
final class MetalTextSurface: TextSurface {
  private static var nextID = 0

  let id: Int
  let config: SurfaceConfig
  let material = MaterialBox()
  let scroll: ScrollBox
  /// スクロールを共にする相手と、自分が先に結んだ面か（→ `shareScroll`）。
  weak var partner: MetalTextSurface?
  var leadsScroll = false
  /// 最後に描いたミニマップの配置（描画スレッドが書く）。
  let placementBox = MinimapPlacementBox()
  let style: TextSurfaceStyle
  let textView = MetalTextView()
  /// 本文の場（文書）。
  private(set) lazy var bodySite = EditingSite(surface: self, body: DocumentText(surface: self))
  let lineStops: LineStopsCache

  var view: NSView { textView }
  var responder: NSView { textView }
  weak var delegate: TextSurfaceDelegate? {
    didSet { pullContent() }
  }
  weak var host: TextSurfaceHost?
  var viewport = TextViewport.empty
  /// 面の大きさ（pt）・倍率・描く色空間。
  var size = CGSize.zero
  private(set) var scale: CGFloat = 2
  private(set) var space = FrameMaterial.defaultSpace
  private(set) var indentation = Indentation.fallback
  private(set) var lineBreak = LineBreak.lf
  /// 面に焦点がある（first responder で、窓が key）。
  private(set) var focused = false
  private var linkPointer: CGPoint?
  /// キャレットを点滅させるか（→ `setCaretBlinks`）。
  private(set) var caretBlinks = CaretBlinking.systemPreference
  /// 進行中の取引（→ `transact`）。
  var transaction: Transaction?
  /// 出す前の状態（→ `flush`）。
  var pending = Pending()
  /// 押された強調の地（同じ列の押し直しを書かない）。
  private var highlights = Highlights()
  /// 縦の並び（main の最新。取引の中で置き・ずらし・測り直し、出すときに材料へ書く）。
  var rows: RowLayout
  /// 表示の構成と、そのうち配置と描き方に効くもの。
  var presentation = SurfacePresentation.code
  var arrangement = SurfaceArrangement()
  /// 置いている区画（区画の同一性で引く）と、絵を材料に写す係。
  var zones: [ObjectIdentifier: ZoneEntry] = [:]
  let painter = ZonePainter()
  /// 入力欄の場（入力欄の id で引く）と、場に振る通し番号。
  var fields: [AnyHashable: EditingSite] = [:]
  var nextFieldSerial = 0
  /// 主（→ `Primary`）と、主が区画の文の間の区画の選択。
  var primary = Primary.body
  var zoneSelection: ZoneTextSelection?
  /// ポインタの下の押せる場所と、ホバーを知らせている最中か。
  var hoveredButton: HoveredButton?
  var hovering = false
  /// 取引の中で、区画の絵の高さが並びの高さと違うものを写した（取引の終わりに並びを組み直す）。
  var zoneHeightsChanged = false
  /// 取引の中で、区画を写したか外した（取引の終わりに、どの区画も指さない画像の覚えを手放す）。
  var zonesRepainted = false
  /// 面自身の入力の処理の入れ子の深さ（→ `inputScope`）。
  var inputDepth = 0
  /// 描画スレッドへ頼んだ横の「見えるところまで」の通し番号。
  var revealSerial = 0
  /// 前回の `refreshViewport` で見た、見せている位置（端を越えて見せている分を含む）。変換中かどうかに依らず
  /// 更新し、動いたら変換中の IME へ知らせる（→ `inputMethodScrollDidChange`）。
  var inputMethodPosition = SIMD2<Double>(0, 0)

  init(style: TextSurfaceStyle, omittedLabel: @escaping @Sendable (Int) -> String) {
    Self.nextID += 1
    id = Self.nextID
    self.style = style
    config = SurfaceConfig(style: style, omittedLabel: omittedLabel)
    rows = RowLayout(lineHeight: Double(style.lineHeight))
    scroll = ScrollBox(surface: id)
    lineStops = LineStopsCache(font: config.font)
    textView.surface = self
    let id = id
    let material = material
    let scroll = scroll
    let placement = placementBox
    let config = config
    let notify: @Sendable () -> Void = { [weak self] in
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.scrollDidAdvance() }
      }
    }
    RenderThread.shared.perform { renderer in
      renderer.attach(
        id: id, boxes: SurfaceBoxes(material: material, scroll: scroll, placement: placement),
        config: config, notify: notify)
    }
    appearanceDidChange()
    let rows = rows
    write { $0.rows = rows }
  }

  deinit {
    let id = id
    scroll.leave()
    RenderThread.shared.perform { $0.detach(id) }
  }

  // MARK: - 選択と編集（契約）

  /// 本文の場の編集係。
  var editor: SurfaceEditor { bodySite.editor }

  var selectedRange: NSRange {
    get { editor.state.cursors.primary.selection }
    set {
      transact {
        setPrimary(.body)
        editor.setSelection(newValue)
      }
    }
  }

  var caretLocation: Int { editor.state.cursors.primary.position }

  /// 本文の場を編集できるか。読むだけにするときは、本文の変換を確定し、AppKit に入力の文脈を取り直させる（読むだけの本文は
  /// 文脈を返さない）。
  var isEditable: Bool {
    get { bodySite.isEditable }
    set {
      guard newValue != bodySite.isEditable else { return }
      transact {
        bodySite.editor.finishComposition(.commit)
        bodySite.isEditable = newValue
        if textView.window?.firstResponder === textView { _ = NSTextInputContext.current }
      }
    }
  }

  var cursorSelections: [NSRange] { editor.state.cursors.selections }

  var searchContinuation: SearchQuestion? { editor.state.continuation }

  func markUndoBoundary() {
    editor.markBoundary()
  }

  func commitMarkedText() {
    primarySite?.editor.finishComposition(.commit)
  }

  /// 本文の丸ごとの置き換え（外部変更の差し替え）。通常の編集と同じく undo に載る（読むだけの面では載せず、それまでの
  /// 取り消しも捨てる）。この面から始めた本文のドラッグの途中なら、運んでいる範囲は古い本文の位置なので手放し、以後は
  /// コピーとして落とす（元の字は消さない）。
  func replaceAll(with text: String) {
    textView.draggedRange = nil
    editor.replaceAll(with: text)
  }

  /// 強調の地を材料に置く（同じ区間の列を押し直されても書かない）。
  func setHighlights(_ ranges: [NSRange], for kind: TextHighlightKind) {
    guard highlights[kind] != ranges else { return }
    highlights[kind] = ranges
    write { $0.highlights[kind] = ranges }
  }

  func setIndentation(_ indentation: Indentation) {
    self.indentation = indentation
    write { $0.tabColumns = indentation.unit }
  }

  func setLineBreak(_ lineBreak: LineBreak) {
    self.lineBreak = lineBreak
  }

  // MARK: - 写しと材料

  /// 文書の写しを引いて箱に置く（結ばれたとき・役割が変わったとき・行の印を受けたとき）。取引の中なら、その取引の終わりに
  /// まとめて置く。
  private func pullContent(marks spans: LineMarkSpans? = nil) {
    guard let delegate else { return }
    transact {
      bodySite.change?.content = delegate.surfaceContent(self)
      if let spans { transaction?.marks = spans }
    }
  }

  /// 役割が変わった。写しを引き、変わった区間をその写しの行へ写して、本文の編集と同じ列に「色だけ変わった行」として積む。
  func rolesDidChange(_ ranges: IndexSet) {
    guard let delegate else { return }
    transact {
      let content = delegate.surfaceContent(self)
      bodySite.change?.content = content
      let text = content.text
      bodySite.change?.rowEdits += ranges.rangeView.map { range in
        let rows = text.rows(of: NSRange(range))
        return RowEdit(
          rows: rows.lowerBound..<rows.upperBound + 1, inserted: rows.count,
          version: content.version, rolesOnly: true)
      }
    }
  }

  /// 印は文書がオフセットで押してくる。引いた写しで行へ写してから箱に置く。
  func setLineMarks(_ spans: LineMarkSpans) {
    pullContent(marks: spans)
  }

  /// 色付きで写す HTML の見え方（今の外観で sRGB に解いた色。HTML の色は sRGB）。
  func htmlStyle() -> HTMLCopy.Style {
    let appearance = textView.effectiveAppearance
    let hex = { (color: NSColor) -> String in
      let packed = FrameColor(color, appearance: appearance, space: FrameMaterial.defaultSpace)
        .packed
      return String(
        format: "#%02x%02x%02x", packed & 0xFF, (packed >> 8) & 0xFF, (packed >> 16) & 0xFF)
    }
    // システムの等幅（名前が「.」で始まる内部の名前）は、貼る先の WebKit が解く `ui-monospace` で書く。
    let family = CTFontCopyFamilyName(config.font) as String
    return HTMLCopy.Style(
      text: hex(style.textColor), background: hex(style.backgroundColor),
      roles: style.roleColors.mapValues(hex),
      fontFamily: family.hasPrefix(".") ? "ui-monospace, monospace" : "'\(family)', monospace",
      fontSize: CTFontGetSize(config.font), lineHeight: config.lineHeight)
  }

  /// 本文の色（ドラッグの像）。
  var textColor: NSColor { style.textColor }

  /// 外観・色空間・倍率で色を解き直して置く。
  func appearanceDidChange() {
    let palette = FramePalette(
      style: style, lineStyles: presentation.lineStyles, appearance: textView.effectiveAppearance,
      space: space, scale: scale)
    write { $0.palette = palette }
    zonesAppearanceDidChange()
  }

  /// view の大きさ・倍率・描く色空間・見えているかが変わった。
  func viewStateDidChange(
    size: CGSize, scale: CGFloat, space: CGColorSpace = FrameMaterial.defaultSpace, visible: Bool
  ) {
    transact {
      self.size = size
      write {
        $0.size = size
        $0.scale = scale
        $0.space = space
        $0.visible = visible
      }
      if scale != self.scale || space != self.space {
        self.scale = scale
        self.space = space
        appearanceDidChange()
      }
    }
  }

  /// view が窓に載った。view の display link を描画スレッドの run loop に載せる（初めて載ったときだけ）。
  func attachDisplayLink(to view: MetalTextView) {
    guard !hasDisplayLink, let layer = view.metalLayer else { return }
    hasDisplayLink = true
    let link = Transfer(
      value: view.displayLink(
        target: DisplayLinkTarget(id: id), selector: #selector(DisplayLinkTarget.step(_:))))
    let target = LayerTarget(layer: layer)
    let id = id
    RenderThread.shared.perform { renderer in
      renderer.bind(id, target: target, clock: DisplayLinkClock(link: link.value))
    }
  }

  private var hasDisplayLink = false

  /// 描画スレッドを起こす（スクロールを共にする相手も）。
  func wake() {
    let ids = scrollGroup.map(\.id)
    RenderThread.shared.perform { renderer in
      for id in ids { renderer.wake(id) }
    }
  }

  /// スクロールの状態を `other` と共にする。位置はこの面のものを引き継ぐ。
  func shareScroll(with other: any TextSurface) {
    guard let other = other as? MetalTextSurface, other !== self else {
      preconditionFailure("スクロールを共にできるのは、同じエンジンの別の面だけ")
    }
    precondition(partner == nil && other.partner == nil, "まだスクロールを共にしていない面どうしで結ぶ")
    flush()
    other.flush()
    scroll.share(with: other.scroll)
    partner = other
    other.partner = self
    leadsScroll = true
    wake()
    refreshViewport()
    other.refreshViewport()
  }

  // MARK: - 焦点と撮影

  /// ⌘ を押している間の、本文の上のポインタの位置（押していない・本文の外なら nil）。
  func setLinkPointer(_ point: CGPoint?) {
    guard point != linkPointer else { return }
    linkPointer = point
    inputScope { write { $0.linkPointer = point } }
  }

  /// 焦点（first responder で、窓が key）が変わりうる。変われば点滅を表示からやり直し、選択の地の色を替える。
  func updateFocus(_ focused: Bool) {
    guard focused != self.focused else { return }
    transact {
      self.focused = focused
      zoneSelectionFocusDidChange()
    }
  }

  /// キャレットを点滅させるか（アクセシビリティの「点滅しない挿入ポイント」の設定が変わった）。点滅しなければ、止まって
  /// いる間の描画スレッドの起床は 0。
  func setCaretBlinks(_ blinks: Bool) {
    guard blinks != caretBlinks else { return }
    transact { caretBlinks = blinks }
  }

  func focusDidChange(_ focused: Bool) {
    delegate?.surface(self, focusDidChange: focused)
  }

  /// 今の位置の 1 コマを画面外に描いた絵（撮影）。出す前の状態をその場で出し、描画スレッドの仕事の完了を待つ。
  func snapshot() -> CGImage? {
    flush()
    let id = id
    return RenderThread.shared.performAndWait { Transfer(value: $0.snapshot(id)) }.value
  }
}

/// アクセシビリティの「点滅しない挿入ポイント」（macOS 15 以降）。独自のキャレットを描くアプリはこれに従う。
enum CaretBlinking {
  /// キャレットを点滅させるか。
  @MainActor static var systemPreference: Bool {
    if #available(macOS 15, *) {
      return !AccessibilitySettings.prefersNonBlinkingTextInsertionIndicator
    }
    return true
  }

  /// 設定が変わった知らせ（macOS 15 より前は無い）。
  static var didChangeNotification: Notification.Name? {
    if #available(macOS 15, *) {
      return AccessibilitySettings.prefersNonBlinkingTextInsertionIndicatorDidChangeNotification
    }
    return nil
  }
}
