import AppKit
import Observation
import SwiftUI

/// メニューバー投影（NSStatusItem）の所有者。AppDelegate が起動時に生成し、
/// `AttentionStore`（単一情報源）を SwiftUI（`MenuBarStatusView`）へ橋渡しする。
///
/// 4 態: ①要対応 0＝減光 ◐ ②状態変化の瞬間（`store.transient` が生きている間）＝滲み出しピル
/// ③収縮後＝◐＋件数（waiting+done のみ） ④クリック＝ドロップダウン（`MenuBarDropdown`）。
/// ②の間のクリックだけは該当ペインへ直行する（前面化＋focus）。main スレッド規律
/// （AppKit・AttentionStore と同じ）で、monitor / timer / target-action はすべて main で届く。
///
/// ②の開閉は `MenuBarArrivalDriver` が位相として持ち、controller が tween 中だけ 1/60s の
/// ticker を回して「位相を進める → intrinsic を確定させる → `statusItem.length` へ反映」を
/// 同期で撃つ。滞留中は ticker を止める（回るのは最大 2.3 秒＋0.6 秒）。
final class MenuBarController: NSObject {
  private let store: AttentionStore
  private unowned let windowController: WindowController
  private let localization: LocalizationStore
  private let statusItem: NSStatusItem
  private let host: MenuBarItemHostingView
  private let ui = MenuBarUIState()
  private let driver = MenuBarArrivalDriver()
  private var dropdown: MenuBarDropdown?
  private var transientTimer: Timer?
  private var ticker: Timer?
  /// 直近に driver へ渡した到来時刻。同じペインの積み替えも「新しい到来」なのでここで見分ける。
  private var lastArrivedAt: Date?

  init(store: AttentionStore, windowController: WindowController, localization: LocalizationStore) {
    self.store = store
    self.windowController = windowController
    self.localization = localization
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    host = MenuBarItemHostingView(
      rootView: MenuBarStatusView(store: store, ui: ui, phase: .closed))
    super.init()

    // button に SwiftUI を貼る（静的 NSImage では②の滲み出しが表現できない）。
    // クリックは button の target/action で受けるため、hosting view はヒットテストを素通しする。
    //
    // サイズは制約でなく statusItem.length へ明示反映する——variableLength の status bar は
    // button 内子ビューの制約を幅に読まず、既定の空 button 幅（実測 16px）へ潰して content を
    // 切り詰める（最小再現スパイクで確定）。intrinsic 変化のたびに length と frame を同期する。
    host.sizingOptions = .intrinsicContentSize
    if let button = statusItem.button {
      button.target = self
      button.action = #selector(statusItemClicked)
      host.autoresizingMask = [.width, .height]
      button.addSubview(host)
      host.onIntrinsicSizeChange = { [weak self] in
        DispatchQueue.main.async { self?.syncItemSize() }
      }
      syncItemSize()
    }
    // メニューバーはアプリの theme 強制（NSApp.appearance）でなく**システム外観**で描かれる。
    // 強制テーマのままだと明るいメニューバーに dark 用インクを塗って不可視になるため、
    // hosting view の外観をシステム外観へ固定し、切替の配信通知で追従する。
    syncSystemAppearance()
    DistributedNotificationCenter.default().addObserver(
      self, selector: #selector(systemAppearanceChanged),
      name: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil)
    syncReduceMotion()
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(reduceMotionChanged),
      name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    observeTransient()
  }

  deinit {
    DistributedNotificationCenter.default().removeObserver(self)
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    transientTimer?.invalidate()
    ticker?.invalidate()  // 繰り返しなので、放置すると main runloop に空撃ちが残る
  }

  /// hosting view の intrinsic 幅を statusItem.length へ反映し、frame を button に合わせる。
  private func syncItemSize() {
    statusItem.length = max(host.intrinsicContentSize.width, 1)
    if let button = statusItem.button {
      host.frame = button.bounds
    }
  }

  @objc private func systemAppearanceChanged() {
    DispatchQueue.main.async { [weak self] in self?.syncSystemAppearance() }
  }

  private func syncSystemAppearance() {
    let dark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
  }

  @objc private func reduceMotionChanged() {
    DispatchQueue.main.async { [weak self] in self?.syncReduceMotion() }
  }

  private func syncReduceMotion() {
    driver.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  // MARK: - クリック分岐

  @objc private func statusItemClicked() {
    // ②の間のクリック＝該当ペインへ直行（前面化＋focus）。ドロップダウンは開かない。
    if let transient = store.transient {
      store.transient = nil
      NSApp.activate(ignoringOtherApps: true)
      windowController.window.makeKeyAndOrderFront(nil)
      windowController.focusAttentionPane(paneId: transient.row.paneId)
      closeDropdown()
      return
    }
    if dropdown == nil { showDropdown() } else { closeDropdown() }
  }

  // MARK: - ドロップダウン

  /// ドロップダウンを開く（アイテムクリック・権限ありの global ⌘⌘）。
  /// メニューバー非表示（フルスクリーン等）で statusItem の窓が無ければ no-op。
  func showDropdown() {
    guard dropdown == nil else { return }
    guard let buttonWindow = statusItem.button?.window else { return }
    let d = MenuBarDropdown(
      store: store, localization: localization,
      permissionGranted: CmdDoubleTapMonitor.globalMonitoringPermitted)
    d.onSelectRow = { [weak self] row in
      guard let self else { return }
      self.closeDropdown()
      NSApp.activate(ignoringOtherApps: true)  // 行クリック＝orbe 前面化＋ペインへ移動
      self.windowController.window.makeKeyAndOrderFront(nil)
      self.windowController.focusAttentionPane(paneId: row.paneId)
    }
    d.onOpenOrbe = { [weak self] in
      guard let self else { return }
      self.closeDropdown()
      NSApp.activate(ignoringOtherApps: true)
      self.windowController.window.makeKeyAndOrderFront(nil)
    }
    d.onPermissionHint = { [weak self] in
      guard let self else { return }
      self.closeDropdown()
      NSApp.activate(ignoringOtherApps: true)
      self.windowController.window.makeKeyAndOrderFront(nil)
      self.windowController.showSettingsPalette()  // 権限状態行は設定パレット root にある
    }
    d.onClose = { [weak self] in
      self?.dropdown = nil
      self?.ui.dropdownOpen = false
    }
    dropdown = d
    ui.dropdownOpen = true
    d.show(anchoredTo: buttonWindow.frame, on: buttonWindow.screen)
  }

  func closeDropdown() {
    dropdown?.close()  // onClose 経由で dropdown = nil / ui.dropdownOpen = false に落ちる
  }

  // MARK: - 一過性表示（②）の到来・滞留・収縮と幅同期

  /// store の変化（transient の到来/消滅・件数）を観測し、driver へ到来と取り下げを伝え、
  /// 期限タイマーを張り直して**アイテム幅を即時同期**する（Observation の標準ループ）。
  /// 幅は SwiftUI の再レイアウトを待ってから読む（layoutSubtreeIfNeeded → syncItemSize）。
  /// invalidateIntrinsicContentSize フックはこの経路の取りこぼし（フォント読み込み等の遅延
  /// サイズ確定）を拾う保険として残す。
  private func observeTransient() {
    withObservationTracking {
      _ = store.transient?.arrivedAt
      _ = store.transient?.expiresAt
      _ = store.rows.count
    } onChange: { [weak self] in
      DispatchQueue.main.async {
        guard let self else { return }
        self.syncTransient()
        // SwiftUI の更新適用が次 tick にずれる場合の取りこぼしを塞ぐ（幅同期は冪等）。
        DispatchQueue.main.async { self.syncItemSize() }
        self.observeTransient()
      }
    }
    scheduleTransientExpiry()
  }

  private func syncTransient() {
    let arrivedAt = store.transient?.arrivedAt
    if arrivedAt != lastArrivedAt {
      lastArrivedAt = arrivedAt
      if arrivedAt != nil {
        driver.arrived(at: Date())  // 積み替えも新しい到来（艶が走り直す）
      } else {
        driver.dismissed()  // 取り下げ・②中のクリック・収縮の撃ち終わり＝アニメなしで閉じ切り
        stopTicker()
      }
    }
    scheduleTransientExpiry()
    render()
    if driver.isAnimating { startTicker() }
  }

  /// 現在の位相を content へ流し、intrinsic を確定させてから `statusItem.length` へ反映する。
  private func render() {
    host.rootView = MenuBarStatusView(store: store, ui: ui, phase: driver.phase)
    host.layoutSubtreeIfNeeded()  // 新しい content の intrinsic を確定させてから幅を読む
    syncItemSize()
  }

  /// tween 中だけ回る 1/60s の ticker。位相を進めて幅を追随させ、収縮を撃ち終えたら②を落とす。
  private func startTicker() {
    guard ticker == nil else { return }
    let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
      self?.advance()  // main runloop の timer＝main で届く
    }
    RunLoop.main.add(timer, forMode: .common)
    ticker = timer
  }

  private func stopTicker() {
    ticker?.invalidate()
    ticker = nil
  }

  private func advance() {
    let collapsed = driver.tick(now: Date())
    render()
    if !driver.isAnimating { stopTicker() }
    if collapsed { store.transient = nil }
  }

  private func scheduleTransientExpiry() {
    transientTimer?.invalidate()
    transientTimer = nil
    guard let transient = store.transient else { return }
    let interval = max(0.1, transient.expiresAt.timeIntervalSinceNow)
    let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
      self?.transientExpired()  // main runloop の timer＝main で届く
    }
    RunLoop.main.add(timer, forMode: .common)
    transientTimer = timer
  }

  /// 滞留の満了。ホバー中は収縮を先送りし、そうでなければ収縮を撃つ（一度閉じ始めたら閉じ切る
  /// ——収縮中に期限タイマーは張られない）。
  private func transientExpired() {
    guard store.transient != nil else { return }
    if ui.transientHovered {
      // ホバー中は収縮しない（延長）。ホバーが外れた後の余韻ぶんだけ先送りする。
      store.transient?.expiresAt = Date().addingTimeInterval(2)
      return
    }
    driver.expired(at: Date())
    advance()
    if driver.isAnimating { startTicker() }
  }
}

/// メニューバー投影の UI 状態（controller と `MenuBarStatusView` の共有）。
@Observable final class MenuBarUIState {
  /// ドロップダウン表示中（④）＝ピル地を accent tint に。
  var dropdownOpen = false
  /// ②のピルをホバー中（収縮の延長判定に使う）。view が書き controller が読む。
  var transientHovered = false
}

/// メニューバーアイテム用の hosting view。クリックを NSStatusBarButton（背後の target/action）へ
/// 素通しし（ホバー〔tracking area 由来〕は生きたまま、ヒットテストだけ無効化）、
/// intrinsic サイズの変化を controller へ通知する（statusItem.length の明示反映に使う）。
private final class MenuBarItemHostingView: NSHostingView<MenuBarStatusView> {
  var onIntrinsicSizeChange: (() -> Void)?

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func invalidateIntrinsicContentSize() {
    super.invalidateIntrinsicContentSize()
    onIntrinsicSizeChange?()
  }
}
