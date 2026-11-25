import AppKit

/// 右シート左端内側の 9pt ドラッグハンドル（`SidebarResizeHandle` と同型）。
/// ホバーまたはドラッグ中のみ左端 2pt のアクセント線を点灯させ、ダブルクリックで全面表示へ切り替える。
/// ドラッグ中は `NSCursor.resizeLeftRight.push()` で `WKWebView` によるカーソル上書きを防ぎ、
/// 異常離脱（`windowDidResignKey`・窓離脱・`deinit`）でも必ず `pop()` とドラッグ終了を保証する。
final class BrowserResizeHandleView: NSView {
  /// ドラッグ座標を変換する基準ビュー（`BrowserLayerView`）。
  weak var coordinateView: NSView?
  var onDragStart: (() -> Void)?
  var onDragMove: ((CGFloat) -> Void)?
  var onDragEnd: ((_ cancelled: Bool) -> Void)?
  var onDoubleClick: (() -> Void)?

  private let accentLine = NSView()
  private var isHovered = false
  private var isDragging = false
  private var isCursorPushed = false
  private var resignObserver: NSObjectProtocol?

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    accentLine.wantsLayer = true
    accentLine.alphaValue = 0
    addSubview(accentLine)
    addTrackingArea(
      NSTrackingArea(
        rect: .zero,
        options: [.cursorUpdate, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
        owner: self))
    paintAccentLine()
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  deinit {
    if let resignObserver {
      NotificationCenter.default.removeObserver(resignObserver)
    }
    if isCursorPushed {
      NSCursor.pop()
    }
  }

  override func layout() {
    super.layout()
    accentLine.frame = NSRect(
      x: 0, y: 0, width: Theme.Layout.browserResizeLineWidth, height: bounds.height)
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    paintAccentLine()
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil {
      cancelDragIfNeeded()
      isHovered = false
      syncAccentLine()
    }
    if let resignObserver {
      NotificationCenter.default.removeObserver(resignObserver)
      self.resignObserver = nil
    }
    if let newWindow {
      resignObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.didResignKeyNotification, object: newWindow, queue: .main
      ) { [weak self] _ in
        self?.cancelDragIfNeeded()
      }
    }
    super.viewWillMove(toWindow: newWindow)
  }

  override func cursorUpdate(with event: NSEvent) {
    NSCursor.resizeLeftRight.set()
  }

  override func mouseEntered(with event: NSEvent) {
    isHovered = true
    syncAccentLine()
  }

  override func mouseExited(with event: NSEvent) {
    isHovered = false
    syncAccentLine()
  }

  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2 {
      cancelDragIfNeeded()
      onDoubleClick?()
      return
    }
    isDragging = true
    if !isCursorPushed {
      NSCursor.resizeLeftRight.push()
      isCursorPushed = true
    }
    syncAccentLine()
    onDragStart?()
  }

  override func mouseDragged(with event: NSEvent) {
    guard isDragging else { return }
    onDragMove?(pointerX(in: event))
  }

  override func mouseUp(with event: NSEvent) {
    guard isDragging else { return }
    finishDrag(cancelled: false)
  }

  /// ドラッグ中であれば安全に中断し、カーソルスタックを元に戻す。
  func cancelDragIfNeeded() {
    guard isDragging else { return }
    finishDrag(cancelled: true)
  }

  private func finishDrag(cancelled: Bool) {
    isDragging = false
    if isCursorPushed {
      NSCursor.pop()
      isCursorPushed = false
    }
    syncAccentLine()
    onDragEnd?(cancelled)
  }

  private func pointerX(in event: NSEvent) -> CGFloat {
    let target = coordinateView ?? superview?.superview ?? self
    return target.convert(event.locationInWindow, from: nil).x
  }

  private func syncAccentLine() {
    accentLine.alphaValue = (isHovered || isDragging) ? 1 : 0
  }

  private func paintAccentLine() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      accentLine.layer?.backgroundColor = Theme.Color.browserResizeLine.cgColor
    }
  }
}
