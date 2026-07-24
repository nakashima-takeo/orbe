import AppKit
import Observation
import SwiftUI

/// メニューバー投影（NSStatusItem）の所有者。AppDelegate が起動時に生成し、
/// `AttentionStore`（単一情報源）を SwiftUI（`MenuBarStatusView`）へ橋渡しする。
///
/// 4 態: ①要対応 0＝減光 ◐ ②状態変化の瞬間（0〜6 秒・`store.transient`）＝滲み出しピル
/// ③収縮後＝◐＋件数（waiting+done のみ） ④クリック＝ドロップダウン（`MenuBarDropdown`）。
/// ②の間のクリックだけは該当ペインへ直行する（前面化＋focus）。main スレッド規律
/// （AppKit・AttentionStore と同じ）で、monitor / timer / target-action はすべて main で届く。
final class MenuBarController: NSObject {
  private let store: AttentionStore
  private unowned let windowController: WindowController
  private let localization: LocalizationStore
  private let statusItem: NSStatusItem
  private let host: MenuBarItemHostingView
  private let ui = MenuBarUIState()
  private var dropdown: MenuBarDropdown?
  private var transientTimer: Timer?

  init(store: AttentionStore, windowController: WindowController, localization: LocalizationStore) {
    self.store = store
    self.windowController = windowController
    self.localization = localization
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    host = MenuBarItemHostingView(rootView: MenuBarStatusView(store: store, ui: ui))
    super.init()

    // button に SwiftUI を貼る（静的 NSImage では②の滲み出し・波紋が表現できない）。
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
    observeTransient()
  }

  deinit {
    DistributedNotificationCenter.default().removeObserver(self)
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

  // MARK: - 一過性表示（②）の期限管理と幅同期

  /// store の変化（transient の出現/消滅・件数）を観測し、期限タイマーを張り直し
  /// **アイテム幅を即時同期**する（Observation の標準ループ）。幅は SwiftUI の再レイアウトを
  /// 待ってから読む（layoutSubtreeIfNeeded → syncItemSize）。invalidateIntrinsicContentSize
  /// フックはこの経路の取りこぼし（フォント読み込み等の遅延サイズ確定）を拾う保険として残す。
  private func observeTransient() {
    withObservationTracking {
      _ = store.transient?.expiresAt
      _ = store.rows.count
    } onChange: { [weak self] in
      DispatchQueue.main.async {
        guard let self else { return }
        self.scheduleTransientExpiry()
        self.host.layoutSubtreeIfNeeded()  // 新しい content の intrinsic を確定させてから幅を読む
        self.syncItemSize()
        // SwiftUI の更新適用が次 tick にずれる場合の取りこぼしを塞ぐ（幅同期は冪等）。
        DispatchQueue.main.async { self.syncItemSize() }
        self.observeTransient()
      }
    }
    scheduleTransientExpiry()
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

  private func transientExpired() {
    guard store.transient != nil else { return }
    if ui.transientHovered {
      // ホバー中は収縮しない（延長）。ホバーが外れた後の余韻ぶんだけ先送りする。
      store.transient?.expiresAt = Date().addingTimeInterval(2)
    } else {
      store.transient = nil
    }
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
