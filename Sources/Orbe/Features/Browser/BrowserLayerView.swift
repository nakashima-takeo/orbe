import AppKit
import QuartzCore
import SwiftUI
import WebKit

/// ウィンドウ最上層（Z=2）の内蔵ブラウザ AppKit 器。
/// 既存の `model.content`（Z=0 端末・ボード / Z=1 エディター）の上に兄弟配置され、
/// 開閉・幅変更・全面切替のいずれでも端末寸法へ一切干渉しない。
///
/// 不透明地は `barGround`（36pt ツールバー部）・`belowGround`（バーより下）・`sidebarGround`（サイドバー部）へ分離し、
/// `sheetView` 自身は背景色を持たず左落ち影だけを担う（全面 `⌥` めくりで `belowBar.alphaValue = 0` にした際、
/// 不透明な 36pt バーだけを残して下層を露出させるため）。
/// アクティブタブ 1 枚の `BrowserTabRuntime` のみを弱参照でマウントし、強参照所有は `BrowserSession` に一本化する。
final class BrowserLayerView: NSView {
  let session: BrowserSession
  let toolbar = BrowserToolbarModel()
  let snapBadge = BrowserSnapBadgeModel()
  let newTabModel = BrowserNewTabModel()
  let newTabActions = BrowserNewTabActions()
  let sidebarActions = BrowserSidebarActions()
  let popoverModel = BrowserPopoverModel()

  let leftVeilView = BrowserPassthroughView()
  let sheetView = BrowserSheetContainerView()
  let leftBorderLine = NSView()
  let barGround = NSView()
  let barHost: BrowserBarHost
  let belowBar = BrowserFlippedView()
  let belowGround = NSView()
  let contentView = BrowserFlippedView()
  let newTabHost: BrowserNewTabHost
  let sidebarScrim = BrowserSidebarScrimView()
  let sidebarContainer = BrowserFlippedView()
  let sidebarGround = NSView()
  let sidebarHost: BrowserSidebarHost
  let sidebarBorder = NSView()
  let popoverHost: BrowserPopoverHost
  let resizeHandle = BrowserResizeHandleView()
  let snapBadgeHost: BrowserSnapBadgeHost
  let peekRailView = BrowserPassthroughView()

  /// `visual-check` 撮影中のみ `contentView` へ一時配置する `WKWebView.takeSnapshot` 合成面。
  var snapshotOverlay: NSImageView?

  /// 現在マウント中のアクティブタブ実行体（弱参照。強参照は `session.runtimes` が所有）。
  weak var mountedRuntime: BrowserTabRuntime?
  var displayedSpaceId: UUID?
  var displayedTabId: UUID?
  var webView: WKWebView? { mountedRuntime?.webView }
  var hasNavigated: Bool { mountedRuntime?.hasNavigated ?? false }
  var committedURL: URL? { mountedRuntime?.committedURL }
  var lastRequestedURL: URL? { mountedRuntime?.lastRequestedURL }
  var isProvisionalNavigation: Bool { mountedRuntime?.isProvisionalNavigation ?? false }

  private(set) var mode: BrowserMode = .closed
  private(set) var isPeeking = false
  var sheetRatio: CGFloat

  /// 右シート（既定: 閉）と全面（既定: 開）で独立に記憶するサイドバー開閉状態（メモリ保持のみ）。
  var sheetSidebarOpen = false
  var fullSidebarOpen = true
  var popoverState: BrowserPopoverState?
  var lastLayoutWasSidebarOverlay = false

  /// 窓の key 状態とブラウザ内焦点から上位（`WindowController`）が与える真のブラウザ焦点状態。
  private(set) var isBrowserFocused = false
  var isSheetHovered = false
  var resizeSession: BrowserResizeSession?

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
  var isPopoverOpen: Bool { popoverState != nil }

  var isSidebarOpen: Bool {
    switch mode {
    case .sheet: sheetSidebarOpen
    case .full: fullSidebarOpen
    case .closed: false
    }
  }

  var isSidebarOverlay: Bool {
    let width = currentSheetWidth()
    return isSidebarOpen && width > 0 && width < Theme.Layout.browserSidebarInlineThreshold
  }

  var isEditingNewTabURL: Bool {
    if newTabModel.isInputFocused { return true }
    guard let editor = window?.firstResponder as? NSTextView else { return false }
    return editor.isDescendant(of: newTabHost)
  }

  var isEditingAnyURL: Bool { isEditingURL || isEditingNewTabURL }

  /// first responder が自分か配下にあるか。
  var focusIsInside: Bool {
    guard let responder = window?.firstResponder as? NSView else { return false }
    return responder === self || responder.isDescendant(of: self)
  }

  /// ブラウザ内の焦点の宛先。ポップオーバーまたは狭幅オーバーレイ表示中は背後 WebView へ流出させず `self` 固定。
  var focusTarget: NSView {
    if isPopoverOpen || isSidebarOverlay { return self }
    if let runtime = mountedRuntime, runtime.hasNavigated { return runtime.webView }
    return self
  }

  init(
    session: BrowserSession? = nil,
    localization: LocalizationStore,
    fontResolver: ChromeFontResolver
  ) {
    let resolvedSession = session ?? BrowserSession.inMemory(language: localization.language)
    self.session = resolvedSession
    self.sheetRatio = CGFloat(resolvedSession.store.sheetRatio)
    self.localization = localization
    barHost = BrowserBarHost(
      rootView: BrowserBarRoot(
        model: toolbar, localization: localization, fontResolver: fontResolver))
    newTabHost = BrowserNewTabHost(
      rootView: BrowserNewTabView(
        model: newTabModel, session: resolvedSession, localization: localization,
        fontResolver: fontResolver, actions: newTabActions))
    sidebarHost = BrowserSidebarHost(
      rootView: BrowserSidebarRoot(
        store: resolvedSession.store, localization: localization,
        fontResolver: fontResolver, actions: sidebarActions))
    popoverHost = BrowserPopoverHost(
      rootView: BrowserPopoverOverlayRoot(
        model: popoverModel, session: resolvedSession, localization: localization,
        fontResolver: fontResolver))
    snapBadgeHost = BrowserSnapBadgeHost(
      rootView: BrowserSnapBadge(model: snapBadge, localization: localization))
    super.init(frame: .zero)
    wantsLayer = true
    clipsToBounds = true
    assembleViews()
    wireCallbacks()
    wireSidebarAndPopoverCallbacks()
    wireSession()
    observeLocalization()
    mountRuntime(resolvedSession.activeRuntime)
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
      leftVeilView, sheetView, leftBorderLine, barGround, belowBar, belowGround,
      contentView, sidebarScrim, sidebarContainer, sidebarGround, sidebarBorder, peekRailView,
    ] {
      view.wantsLayer = true
      view.autoresizingMask = []
    }
    sheetView.clipsToBounds = false
    sheetView.layer?.masksToBounds = false
    belowBar.clipsToBounds = true
    contentView.clipsToBounds = true
    sidebarContainer.clipsToBounds = false
    sidebarContainer.layer?.masksToBounds = false
    for host in [barHost, newTabHost, sidebarHost, popoverHost, snapBadgeHost] as [NSView] {
      host.wantsLayer = true
      host.layer?.isOpaque = false
      host.autoresizingMask = []
    }
    barHost.clipsToBounds = true
    barHost.layer?.masksToBounds = true
    popoverHost.isHidden = true
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
    belowBar.addSubview(contentView)
    belowBar.addSubview(sidebarScrim)
    belowBar.addSubview(sidebarContainer)
    belowBar.addSubview(popoverHost)

    contentView.addSubview(newTabHost)

    sidebarContainer.addSubview(sidebarGround)
    sidebarContainer.addSubview(sidebarHost)
    sidebarContainer.addSubview(sidebarBorder)
  }

  private func wireSession() {
    session.onActiveDisplayChange = { [weak self] runtime in
      self?.mountRuntime(runtime)
    }
    session.onActiveRuntimeStateChange = { [weak self] runtime in
      self?.syncActiveRuntimeState(runtime)
    }
    session.onActiveNavigationFinish = { [weak self] in
      self?.onNavigationFinish?()
    }
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
    let wasFocused = isBrowserFocused
    guard focused != wasFocused else { return }
    isBrowserFocused = focused
    if wasFocused && !focused {
      closePopover()
    }
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
    let wasNarrowOverlay = isSidebarOverlay
    let closingWidth: CGFloat? =
      previous.isOpen && next == .closed && sheetView.frame.width > 0
      ? sheetView.frame.width : nil
    resizeHandle.cancelDragIfNeeded()
    closePopover()
    if !next.isOpen && wasNarrowOverlay {
      sheetSidebarOpen = false
    }
    mode = next
    toolbar.mode = next
    toolbar.isSidebarOpen = isSidebarOpen
    endURLEditingExternally()
    if !next.isOpen {
      isPeeking = false
      toolbar.isPeeking = false
      isSheetHovered = false
    }
    session.setBrowserOpen(next.isOpen)
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
