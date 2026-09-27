import AppKit
import OrbeEditorCore
import QuartzCore
import simd

/// `TextSurface` の Metal 実装（main 側）。本文を持たず、文書の写し（本文・役割・版）を契約の口（`surfaceContent`）で
/// 引いて描く側。main がするのは「出来事をスクロールの状態の箱に書く」「写し・選択・見え方を描く材料の箱に置く」だけで、
/// 組版も描画も描画スレッドが行う。写しは自分の欄に持たず、要るとき（`viewport` の計算・編集の規則・行の印の行への写像）は
/// 箱から読む。
///
/// 編集は面の編集係（`SurfaceEditor`）が持ち、1 回の操作を 1 つの取引にする（→ `transact`）。IME・コピー・ペースト・
/// 強調の地・装備・アクセシビリティはまだ持たない（強調の地は値を受け取るだけで描かない）。
@MainActor
final class MetalTextSurface: TextSurface {
  private static var nextID = 0

  let id: Int
  let config: SurfaceConfig
  let material = MaterialBox()
  let scroll: ScrollBox
  private let style: TextSurfaceStyle
  let textView = MetalTextView()
  private(set) lazy var editor = SurfaceEditor(surface: self)
  let lineStops: LineStopsCache

  var view: NSView { textView }
  var responder: NSView { textView }
  weak var delegate: TextSurfaceDelegate? {
    didSet { pullContent() }
  }
  var onOpenLink: ((URL) -> Void)?
  var viewport = TextViewport.empty
  /// 面の大きさ（pt）・倍率・描く色空間。
  var size = CGSize.zero
  private var scale: CGFloat = 2
  private var space = FrameMaterial.defaultSpace
  private(set) var indentation = Indentation.fallback
  /// 面に焦点がある（first responder で、窓が key）。
  private(set) var focused = false
  /// 進行中の取引（→ `transact`）。
  var transaction: Transaction?
  /// 描画スレッドへ頼んだ横の「見えるところまで」の通し番号。
  var revealSerial = 0

  init(style: TextSurfaceStyle, options: MetalTextSurfaceOptions) {
    Self.nextID += 1
    id = Self.nextID
    self.style = style
    config = SurfaceConfig(
      style: style, fontSmoothing: options.fontSmoothing, omittedLabel: options.omittedLabel)
    scroll = ScrollBox(elastic: options.elasticScroll)
    lineStops = LineStopsCache(font: config.font)
    textView.surface = self
    let id = id
    let material = material
    let scroll = scroll
    let config = config
    let notify: @Sendable () -> Void = { [weak self] in
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.scrollDidAdvance() }
      }
    }
    RenderThread.shared.perform { renderer in
      renderer.attach(id: id, material: material, scroll: scroll, config: config, notify: notify)
    }
    appearanceDidChange()
  }

  deinit {
    let id = id
    RenderThread.shared.perform { $0.detach(id) }
  }

  // MARK: - 選択と編集（契約）

  var selectedRange: NSRange {
    get { editor.state.cursors.primary.selection }
    set { editor.setSelection(newValue) }
  }

  var caretLocation: Int { editor.state.cursors.primary.position }

  func markUndoBoundary() {
    editor.markBoundary()
  }

  /// 本文の丸ごとの置き換え（外部変更の差し替え）。通常の編集と同じく undo に載る。
  func replaceAll(with text: String) {
    editor.replaceAll(with: text)
  }

  func setHighlights(_ ranges: [NSRange], for kind: TextHighlightKind) {}

  func setIndentation(_ indentation: Indentation) {
    self.indentation = indentation
    write { $0.tabColumns = indentation.unit }
  }

  /// 標準のセレクタが写ったコマンドを、面の編集係で行う。
  func perform(_ command: EditCommand) {
    editor.perform(command)
  }

  // MARK: - 写しと材料

  /// 文書の写しを引いて箱に置く（結ばれたとき・役割が変わったとき・行の印を受けたとき）。取引の中なら、その取引の終わりに
  /// まとめて置く。
  private func pullContent(marks spans: LineMarkSpans? = nil) {
    guard let delegate else { return }
    transact {
      transaction?.content = delegate.surfaceContent(self)
      if let spans { transaction?.marks = spans }
    }
  }

  func rolesDidChange(_ ranges: IndexSet) {
    pullContent()
  }

  /// 印は文書がオフセットで押してくる。引いた写しで行へ写してから箱に置く。
  func setLineMarks(_ spans: LineMarkSpans) {
    pullContent(marks: spans)
  }

  /// 外観・色空間・倍率で色を解き直して置く。
  func appearanceDidChange() {
    let palette = FramePalette(
      style: style, appearance: textView.effectiveAppearance, space: space,
      fontSmoothing: config.fontSmoothing, scale: scale)
    write { $0.palette = palette }
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

  func wake() {
    let id = id
    RenderThread.shared.perform { $0.wake(id) }
  }

  // MARK: - 焦点と撮影

  /// 焦点（first responder で、窓が key）が変わりうる。変われば点滅を表示からやり直し、選択の地の色を替える。
  func updateFocus(_ focused: Bool) {
    guard focused != self.focused else { return }
    transact { self.focused = focused }
  }

  func focusDidChange(_ focused: Bool) {
    delegate?.surface(self, focusDidChange: focused)
  }

  /// 今の位置の 1 コマを画面外に描いた絵（撮影）。描画スレッドの仕事の完了を待つ。
  func snapshot() -> CGImage? {
    let id = id
    return RenderThread.shared.performAndWait { Transfer(value: $0.snapshot(id)) }.value
  }
}
