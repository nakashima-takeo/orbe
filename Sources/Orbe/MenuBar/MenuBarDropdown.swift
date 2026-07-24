import AppKit
import SwiftUI

/// メニューバーのドロップダウン（④）。borderless の `.nonactivatingPanel` に SwiftUI を全面で載せ、
/// デザイン第11シーン（幅 420・radius 14・行はパレットと同一仕様）をそのまま再現する。
/// アプリを前面化せずに開け、パネルが key になるので Esc / ⌘O を受けられる。
/// 閉じる: 外クリック（global mouse monitor・権限不要）・resignKey・Esc。
final class MenuBarDropdown {
  var onSelectRow: (AttentionRow) -> Void = { _ in }
  var onOpenOrbe: () -> Void = {}
  var onPermissionHint: () -> Void = {}
  var onClose: () -> Void = {}

  private let panel: DropdownPanel
  private var mouseMonitor: Any?
  private var closed = false

  init(store: AttentionStore, localization: LocalizationStore, permissionGranted: Bool) {
    panel = DropdownPanel(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    panel.level = .statusBar
    panel.isMovable = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.hidesOnDeactivate = false

    let view = MenuBarDropdownView(
      store: store, localization: localization, permissionGranted: permissionGranted,
      onSelectRow: { [weak self] row in self?.onSelectRow(row) },
      onOpenOrbe: { [weak self] in self?.onOpenOrbe() },
      onPermissionHint: { [weak self] in self?.onPermissionHint() })
    panel.contentView = NSHostingView(rootView: view)
    panel.onEscape = { [weak self] in self?.close() }
    panel.onCmdO = { [weak self] in self?.onOpenOrbe() }
    panel.onResignKey = { [weak self] in self?.close() }
  }

  /// statusItem の button 窓 frame の直下・右揃えで表示する（画面端は visibleFrame へクランプ）。
  func show(anchoredTo buttonFrame: NSRect, on screen: NSScreen?) {
    guard let content = panel.contentView else { return }
    content.layoutSubtreeIfNeeded()
    let size = content.fittingSize
    var x = buttonFrame.maxX - size.width
    var y = buttonFrame.minY - size.height - 4
    if let visible = screen?.visibleFrame {
      x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
      y = max(y, visible.minY + 8)
    }
    panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    panel.orderFrontRegardless()
    panel.makeKey()  // Esc / ⌘O を受ける（nonactivating なのでアプリは前面化しない）
    // パネル外クリックで閉じる（自ウィンドウ内クリックは local イベントなので global には来ない）。
    mouseMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown]
    ) { [weak self] _ in
      self?.close()
    }
  }

  func close() {
    guard !closed else { return }
    closed = true
    if let mouseMonitor {
      NSEvent.removeMonitor(mouseMonitor)
      self.mouseMonitor = nil
    }
    panel.orderOut(nil)
    onClose()
  }
}

/// key になれる borderless panel（Esc / ⌘O / resignKey をクロージャで返す）。
private final class DropdownPanel: NSPanel {
  var onEscape: (() -> Void)?
  var onCmdO: (() -> Void)?
  var onResignKey: (() -> Void)?

  override var canBecomeKey: Bool { true }

  override func cancelOperation(_ sender: Any?) { onEscape?() }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
      event.charactersIgnoringModifiers == "o"
    {
      onCmdO?()
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  override func resignKey() {
    super.resignKey()
    onResignKey?()
  }
}

/// ドロップダウンの中身（幅 420・radius 14・地 rgba(panel, 0.94)・枠 border 8%）。
/// 行リスト＝waiting/done のみ（`AttentionRowView` 共用・ホバーで 1 行だけ着色・クリックで移動）、
/// 区切り線 → working 減光集約 1 行（クリック不可）、フッター、権限未付与時のみ控えめなヒント 1 行。
/// internal なのはギャラリー（DesignGallerySnapshotTests+Attention）が単体で描くため。
struct MenuBarDropdownView: View {
  let store: AttentionStore
  let localization: LocalizationStore
  let permissionGranted: Bool
  var onSelectRow: (AttentionRow) -> Void
  var onOpenOrbe: () -> Void
  var onPermissionHint: () -> Void

  @State private var hoveredPaneId: Int?

  /// 地色。Theme.Glass.surface と同基色（dark 0x1e1a26 / light 白）のドロップダウン専用濃度 0.94
  /// （デザイン rgba(panel, 0.94)。既存 GlassLevel の 0.72/0.85/0.90 とは別段のため局所で持つ）。
  private var panelFill: Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
          ? NSColor(srgbRed: 0x1e / 255, green: 0x1a / 255, blue: 0x26 / 255, alpha: 0.94)
          : NSColor(white: 1, alpha: 0.94)
      })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 0) {
        if store.listRows.isEmpty {
          Text(localization.string(.attentionEmpty))
            .font(Font.theme.workspaceName)
            .foregroundStyle(Color.theme.textMuted)
            .padding(.vertical, 5)
            .padding(.horizontal, Theme.Space.step + Theme.Space.hair)
        } else {
          ForEach(store.listRows, id: \.paneId) { row in
            AttentionRowView(row: row)
              .padding(.vertical, 5)
              .padding(.horizontal, Theme.Space.step + Theme.Space.hair)
              .background(
                RoundedRectangle(cornerRadius: Theme.Radius.row)
                  .fill(hoveredPaneId == row.paneId ? Color.theme.selectionFill : .clear)
              )
              .contentShape(Rectangle())
              .onTapGesture { onSelectRow(row) }
              .onHover { if $0 { hoveredPaneId = row.paneId } }
          }
        }
        if let workingLabel = store.workingLabel {
          Rectangle()
            .fill(Color.theme.borderInk.opacity(0.08))
            .frame(height: Theme.Stroke.hairline)
            .padding(.vertical, 5)
            .padding(.horizontal, Theme.Space.step)
          HStack(spacing: Theme.Space.step) {
            StatusGlyphView(kind: .working, size: 12)
            Text(workingLabel)
              .font(Font.theme.chrome)
              .foregroundStyle(Color.theme.textMuted)
              .lineLimit(1)
          }
          .padding(.vertical, Theme.Space.note)
          .padding(.horizontal, Theme.Space.step + Theme.Space.hair)
          .opacity(0.6)
        }
      }
      .padding(Theme.Space.note)

      Rectangle().fill(Color.theme.borderInk.opacity(0.08)).frame(height: Theme.Stroke.hairline)
      HStack(spacing: 0) {
        Text(localization.string(.menubarClickToPane))
          .foregroundStyle(Color.theme.textMuted)
        Spacer(minLength: Theme.Space.beat)
        HStack(spacing: Theme.Space.tick) {
          Text(localization.string(.menubarOpenOrbe))
            .foregroundStyle(Color.theme.textSecondary)
          Text("⌘O")
            .foregroundStyle(Color.theme.textMuted)
        }
        .contentShape(Rectangle())
        .onTapGesture { onOpenOrbe() }
      }
      .font(Font.theme.meta)
      .padding(.vertical, Theme.Space.step)
      .padding(.horizontal, Theme.Space.bar)

      if !permissionGranted {
        Text(localization.string(.menubarPermissionHint))
          .font(Font.theme.meta)
          .foregroundStyle(Color.theme.textMuted)
          .padding(.horizontal, Theme.Space.bar)
          .padding(.bottom, Theme.Space.step)
          .contentShape(Rectangle())
          .onTapGesture { onPermissionHint() }
      }
    }
    .frame(width: 420, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 14).fill(panelFill))
    .overlay(
      RoundedRectangle(cornerRadius: 14)
        .strokeBorder(Color.theme.borderInk.opacity(0.08), lineWidth: Theme.Stroke.hairline)
    )
    .environment(\.localization, localization)
  }
}
