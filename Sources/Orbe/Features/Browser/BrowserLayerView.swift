import AppKit
import QuartzCore
import SwiftUI
import WebKit

/// ウィンドウ最上層（Z=2）の内蔵ブラウザ AppKit 器。
/// 既存の `model.content`（Z=0 端末・ボード / Z=1 エディター）の上に兄弟配置され、
/// 開閉・幅変更・全面切替のいずれでも端末寸法へ一切干渉しない。
///
/// 不透明地は `barGround`（36pt ツールバー部）と `belowGround`（バーより下）へ分離し、
/// `sheetView` 自身は背景色を持たず左落ち影だけを担う（全面 `⌥` めくりで `belowBar.alphaValue = 0` にした際、
/// 不透明な 36pt バーだけを残して下層を露出させるため）。
/// `WKWebView` は初回表示まで遅延生成し、生成時は `BrowserDataStore.make()` で隔離する。
final class BrowserLayerView: NSView {
  let toolbar = BrowserToolbarModel()
  let snapBadge = BrowserSnapBadgeModel()

  let leftVeilView = BrowserPassthroughView()
  let sheetView = BrowserSheetContainerView()
  let leftBorderLine = NSView()
  let barGround = NSView()
  let barHost: BrowserBarHost
  let belowBar = BrowserFlippedView()
  let belowGround = NSView()
  let emptyOverlay: BrowserEmptyHost
  let resizeHandle = BrowserResizeHandleView()
  let snapBadgeHost: BrowserSnapBadgeHost
  let peekRailView = BrowserPassthroughView()

  /// `visual-check` 撮影中のみ `belowBar` へ一時配置する `WKWebView.takeSnapshot` 合成面。
  var snapshotOverlay: NSImageView?

  /// 初回表示時に遅延生成される `WKWebView`。閉じたままの間は nil。
  var webView: WKWebView?
  private(set) var mode: BrowserMode = .closed
  private(set) var isPeeking = false
  var sheetRatio: CGFloat = BrowserResizeSession.defaultRatio
  var hasNavigated = false
  var committedPage: CommittedPage?
  var committedURL: URL? { committedPage?.url }
  var lastRequestedURL: URL?
  var pendingNavigation: PendingNavigation?
  let navigationMetadata = NSMapTable<WKNavigation, NavigationMeta>.weakToStrongObjects()
  var isProvisionalNavigation: Bool { pendingNavigation != nil }

  /// 窓の key 状態とブラウザ内焦点から上位（`WindowController`）が与える真のブラウザ焦点状態。
  private(set) var isBrowserFocused = false
  var isSheetHovered = false
  var resizeSession: BrowserResizeSession?
  var kvoObservations: [NSKeyValueObservation] = []

  enum Fade: Equatable {
    case sheet(closingWidth: CGFloat? = nil)
    case belowBar
  }
  var fade: Fade?
  var isFading: Bool { fade != nil }
  var fadeGeneration = 0
  var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

  let localization: LocalizationStore

  /// ブラウザ層から上位への操作通知（一方向クロージャ）。
  var onWindowCommand: ((WindowCommand) -> Void)?
  var onRequestModeChange: ((BrowserMode, Bool) -> Void)?
  var onNavigationFinish: (() -> Void)?

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  var isEditingURL: Bool { toolbar.isEditingURL }

  /// first responder が自分か配下にあるか。
  var focusIsInside: Bool {
    guard let responder = window?.firstResponder as? NSView else { return false }
    return responder === self || responder.isDescendant(of: self)
  }

  /// ブラウザ内の焦点の宛先（遷移済みなら `webView`、初期空状態なら自分自身）。
  var focusTarget: NSView {
    if hasNavigated, let webView { return webView }
    return self
  }

  init(localization: LocalizationStore, fontResolver: ChromeFontResolver) {
    self.localization = localization
    barHost = BrowserBarHost(
      rootView: BrowserBarRoot(
        model: toolbar, localization: localization, fontResolver: fontResolver))
    emptyOverlay = BrowserEmptyHost(rootView: BrowserEmptyView(localization: localization))
    snapBadgeHost = BrowserSnapBadgeHost(
      rootView: BrowserSnapBadge(model: snapBadge, localization: localization))
    super.init(frame: .zero)
    wantsLayer = true
    clipsToBounds = true
    assembleViews()
    wireCallbacks()
    observeLocalization()
    applyPresentation()
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(accessibilityDisplayOptionsDidChange),
      name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  deinit {
    NSWorkspace.shared.notificationCenter.removeObserver(self)
  }

  @objc private func accessibilityDisplayOptionsDidChange() {
    reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  private func assembleViews() {
    for view in [
      leftVeilView, sheetView, leftBorderLine, barGround, belowBar, belowGround, peekRailView,
    ] {
      view.wantsLayer = true
      view.autoresizingMask = []
    }
    sheetView.clipsToBounds = false
    sheetView.layer?.masksToBounds = false
    belowBar.clipsToBounds = true
    for host in [barHost, emptyOverlay, snapBadgeHost] as [NSView] {
      host.wantsLayer = true
      host.layer?.isOpaque = false
      host.autoresizingMask = []
    }
    barHost.clipsToBounds = true
    barHost.layer?.masksToBounds = true
    resizeHandle.autoresizingMask = []
    resizeHandle.coordinateView = self

    addSubview(leftVeilView)
    addSubview(sheetView)
    addSubview(peekRailView)

    sheetView.addSubview(leftBorderLine)
    sheetView.addSubview(barGround)
    sheetView.addSubview(belowBar)
    sheetView.addSubview(barHost)
    sheetView.addSubview(resizeHandle)
    sheetView.addSubview(snapBadgeHost)

    belowBar.addSubview(belowGround)
    belowBar.addSubview(emptyOverlay)
  }

  private func wireCallbacks() {
    sheetView.onHoverChange = { [weak self] hovered in
      guard let self, self.isSheetHovered != hovered else { return }
      self.isSheetHovered = hovered
      self.syncFocusAppearance()
    }
    resizeHandle.onDragStart = { [weak self] in self?.dragDidStart() }
    resizeHandle.onDragMove = { [weak self] x in self?.dragDidMove(to: x) }
    resizeHandle.onDragEnd = { [weak self] cancelled in self?.dragDidEnd(cancelled: cancelled) }
    resizeHandle.onDoubleClick = { [weak self] in
      guard let self, self.mode == .sheet else { return }
      self.requestModeChange(.full, animated: true)
    }

    toolbar.onBack = { [weak self] in
      guard let self else { return }
      self.endURLEditingExternally()
      self.goBack()
      self.focusBrowser()
    }
    toolbar.onForward = { [weak self] in
      guard let self else { return }
      self.endURLEditingExternally()
      self.goForward()
      self.focusBrowser()
    }
    toolbar.onReloadOrStop = { [weak self] in
      guard let self else { return }
      self.endURLEditingExternally()
      self.reloadOrStop()
      self.focusBrowser()
    }
    toolbar.onToggleFull = { [weak self] in
      guard let self else { return }
      self.endURLEditingExternally()
      let next: BrowserMode = self.mode == .full ? .sheet : .full
      self.requestModeChange(next, animated: true)
      self.focusBrowser()
    }
    toolbar.onBeginURLEditing = { [weak self] in self?.beginURLEditing() }
    toolbar.onCommitURL = { [weak self] text in self?.commitURLEditing(text) ?? false }
    toolbar.onCancelURL = { [weak self] in self?.cancelURLEditing() }
    toolbar.onBlurURL = { [weak self] in self?.endURLEditingExternally() }
  }

  private func observeLocalization() {
    resizeHandle.toolTip = localization.string(.browserResizeTooltip)
    withObservationTracking {
      _ = localization.language
    } onChange: { [weak self] in
      DispatchQueue.main.async { self?.observeLocalization() }
    }
  }

  // MARK: - モード・比率・透かし・焦点

  func setSheetRatio(_ ratio: CGFloat) {
    let clamped = BrowserResizeSession.clampRatio(ratio)
    guard clamped != sheetRatio else { return }
    sheetRatio = clamped
    needsLayout = true
  }

  func setPeekUnderlay(_ underlay: BrowserPeekUnderlay) {
    if toolbar.peekUnderlay != underlay {
      toolbar.peekUnderlay = underlay
    }
  }

  func setFocused(_ focused: Bool) {
    guard focused != isBrowserFocused else { return }
    isBrowserFocused = focused
    syncFocusAppearance()
  }

  func focusBrowser() {
    guard mode.isOpen else { return }
    window?.makeFirstResponder(focusTarget)
  }

  func windowDidResignKey() {
    resizeHandle.cancelDragIfNeeded()
    isSheetHovered = false
    setFocused(false)
  }

  func setMode(_ next: BrowserMode, animated: Bool) {
    guard next != mode else { return }
    let previous = mode
    let closingWidth: CGFloat? =
      previous.isOpen && next == .closed && sheetView.frame.width > 0
      ? sheetView.frame.width : nil
    resizeHandle.cancelDragIfNeeded()
    mode = next
    toolbar.mode = next
    endURLEditingExternally()
    if next.isOpen {
      _ = ensureWebView()
    } else {
      isPeeking = false
      toolbar.isPeeking = false
      isSheetHovered = false
    }
    let fadeTarget: Fade? =
      if previous == .closed && next.isOpen {
        .sheet()
      } else if previous.isOpen && next == .closed {
        .sheet(closingWidth: closingWidth)
      } else {
        nil
      }
    runFade(fadeTarget, duration: Theme.Motion.base, animated: animated)
    needsLayout = true
    layoutSubtreeIfNeeded()
  }

  func setPeeking(_ next: Bool, animated: Bool) {
    let normalized = mode.isOpen ? next : false
    guard normalized != isPeeking else { return }
    isPeeking = normalized
    toolbar.isPeeking = normalized
    if normalized {
      resizeHandle.cancelDragIfNeeded()
      showArrowPointer()
    }
    let fadeTarget: Fade? = mode == .full ? .belowBar : (mode == .sheet ? .sheet() : nil)
    runFade(fadeTarget, duration: Theme.Motion.quick, animated: animated)
  }

  func requestModeChange(_ next: BrowserMode, animated: Bool) {
    if let onRequestModeChange {
      onRequestModeChange(next, animated)
    } else {
      setMode(next, animated: animated)
    }
  }
}
