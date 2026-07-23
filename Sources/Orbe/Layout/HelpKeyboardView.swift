import AppKit
import Combine
import SwiftUI

/// キーボード物理可視化（6段配列）。点灯＝行ホバーの combo ∪ 実押下 ∪ キー絞り込み選択。
/// 使用キー（ショートカットに登場するキー）はクリックで絞り込みトグル、非使用キーは暗く非対話。
/// 実押下は表示中のみ張る NSEvent ローカルモニタで拾う（イベントは消費せず素通し）。
struct HelpKeyboardView: View {
  @Bindable var model: HelpModel
  let ink: HelpInk
  @Environment(\.localization) private var l10n
  @State private var keyHover: String?
  /// ローカルモニタのハンドル。表示中のみ非 nil（onAppear で張り onDisappear で外す）。
  @State private var monitor: Any?

  /// キー 1 単位の幅と間隔（デザイン見本の U/GAP。コンポーネント局所定数）。
  private let unit: CGFloat = 34
  private let gap: CGFloat = 4

  var body: some View {
    // 行はデザイン見本どおり左揃え（行幅は fn 行が最長で不揃い。中央揃えにしない）。
    // 行ブロックごとパネル中央に置き、キャプションはその下で中央。
    VStack(spacing: gap) {
      VStack(alignment: .leading, spacing: gap) {
        ForEach(Array(HelpCatalog.keyboard.enumerated()), id: \.offset) { rowIndex, row in
          HStack(spacing: gap) {
            ForEach(row, id: \.id) { key in
              keyCap(key, fnRow: rowIndex == 0)
            }
          }
        }
      }
      Text(l10n.string(.helpKeyboardCaption))
        .font(Font.theme.helpCaption)
        .foregroundStyle(Color.theme.textMuted)
        .opacity(0.8)
        .multilineTextAlignment(.center)
        .padding(.top, Theme.Space.hair)
    }
    .padding(.vertical, 10)
    .padding(.horizontal, Theme.Space.bar)
    .frame(maxWidth: .infinity)
    .onAppear(perform: installMonitor)
    .onDisappear(perform: removeMonitor)
    // ウィンドウが key を失ったら押下残留を全クリア（keyUp が届かないため）。
    .onReceive(
      NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)
    ) { _ in
      model.pressed = []
    }
  }

  // MARK: - キー 1 枚

  private func keyCap(_ key: HelpCatalog.Key, fnRow: Bool) -> some View {
    let isSel = key.id == model.fkey
    let isLit = litKeys.contains(key.id)
    let usable = HelpCatalog.usedKeys.contains(key.id)
    let modifier = HelpCatalog.modifierKeys.contains(key.id)
    let shape = RoundedRectangle(cornerRadius: 5)
    let bottomAligned = !fnRow && modifier
    return Text(key.label)
      .font(font(for: key, fnRow: fnRow))
      .lineSpacing(1)
      .multilineTextAlignment(.center)
      .foregroundStyle(textColor(isActive: isSel || isLit, usable: usable))
      .padding(.bottom, bottomAligned ? Theme.Space.tick : 0)
      .frame(
        width: (unit * key.width + gap * (key.width - 1)).rounded(),
        height: fnRow ? 18 : 30,
        alignment: bottomAligned ? .bottom : .center
      )
      .background(
        shape.fill(
          isSel || isLit
            ? Color.theme.accentPrimary.opacity(0.3)
            : usable ? ink.surface(0.06) : ink.surface(0.03))
      )
      // 非点灯時の inset 0 -1px（キー下端の落ち影）。角丸内に収める。
      .overlay(alignment: .bottom) {
        if !(isSel || isLit) {
          keycapShadow.frame(height: 1).clipShape(shape)
        }
      }
      .overlay(shape.strokeBorder(borderColor(isSel: isSel, isLit: isLit, id: key.id)))
      .shadow(
        color: isSel || isLit ? Color.theme.accentPrimary.opacity(0.4) : .clear, radius: 7
      )
      .contentShape(shape)
      .onTapGesture {
        guard usable else { return }
        model.fkey = model.fkey == key.id ? nil : key.id
      }
      .onHover { entered in
        if entered {
          keyHover = key.id
        } else if keyHover == key.id {
          keyHover = nil
        }
      }
      .animation(
        .linear(duration: Theme.Motion.quick),
        value: [isSel, isLit, keyHover == key.id])
  }

  /// 点灯集合＝行ホバーの combo ∪ 実押下。
  private var litKeys: Set<String> {
    Set(model.hoverRow?.combo ?? []).union(model.pressed)
  }

  private func font(for key: HelpCatalog.Key, fnRow: Bool) -> Font {
    if fnRow { return Font.theme.helpKeyFn }
    if key.id == "ud" { return Font.theme.helpKeyArrow }
    return Font.theme.meta
  }

  private func textColor(isActive: Bool, usable: Bool) -> Color {
    if isActive { return Color.theme.textPrimary }
    return usable ? Color.theme.kbKeyText : Color.theme.kbKeyMutedText
  }

  private func borderColor(isSel: Bool, isLit: Bool, id: String) -> Color {
    if isSel { return Color.theme.accentPrimary.opacity(0.85) }
    if isLit { return Color.theme.accentPrimary.opacity(0.6) }
    if keyHover == id { return Color.theme.accentPrimary.opacity(0.5) }
    return ink.border(0.1)
  }

  /// キー下端の inset 影色（shadowRgb: dark=黒 / light=紫灰）。
  private var keycapShadow: Color {
    ink.dark
      ? Color.black.opacity(0.25)
      : Color(red: 90 / 255, green: 70 / 255, blue: 150 / 255).opacity(0.12)
  }

  // MARK: - 実押下の NSEvent ローカルモニタ

  /// keyDown/keyUp/flagsChanged を表示中のみ購読する。イベントは必ず素通し（return event）＝
  /// 検索欄への入力・⌘H トグル・esc 閉じ等の既存経路と共存する。
  private func installMonitor() {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(
      matching: [.keyDown, .keyUp, .flagsChanged]
    ) { event in
      switch event.type {
      case .keyDown:
        if let id = HelpKeyMonitor.keyID(for: event) { model.pressed.insert(id) }
      case .keyUp:
        if let id = HelpKeyMonitor.keyID(for: event) { model.pressed.remove(id) }
      case .flagsChanged:
        model.pressed = HelpKeyMonitor.syncingModifiers(model.pressed, with: event)
      default:
        break
      }
      return event
    }
  }

  private func removeMonitor() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    model.pressed = []
  }
}

/// NSEvent → キーボード可視化のキー id 解決と修飾キー同期（純ロジック・テスト可能）。
enum HelpKeyMonitor {
  /// keyDown/keyUp → キー id。可視化対象外（F キー・未知文字）は nil。↑↓ は `ud` に合流。
  static func keyID(for event: NSEvent) -> String? {
    if let special = event.specialKey {
      switch special {
      case .tab, .backTab: return "tab"
      case .carriageReturn, .enter, .newline: return "return"
      case .delete, .backspace, .deleteForward: return "delete"
      case .leftArrow: return "left"
      case .rightArrow: return "right"
      case .upArrow, .downArrow: return "ud"
      default: return nil
      }
    }
    // デザイン見本 keyId() の移植: charactersIgnoringModifiers の 1 文字で解決する
    // （Shift 併用の記号（⇧5=%等）は見本同様に対象外。修飾キー自体は flagsChanged が担う）。
    guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else {
      return nil
    }
    if scalar.value == 0x1b { return "esc" }
    if scalar.value == 0x20 { return "space" }
    let s = String(Character(scalar)).lowercased()
    guard "abcdefghijklmnopqrstuvwxyz0123456789`-=[];',./\\".contains(s) else { return nil }
    return s
  }

  /// 修飾キーの押下集合を flagsChanged で同期する（左右を device マスクで区別。ctrl は左右とも
  /// 物理配列の単一 `ctrl` へ合流）。⌘ が完全に離れたら非修飾キーの残留を全クリアする
  /// （macOS は ⌘ 押下中の他キー keyUp を配らないため）。
  static func syncingModifiers(_ pressed: Set<String>, with event: NSEvent) -> Set<String> {
    var next = pressed
    let raw = event.modifierFlags.rawValue
    let device: [(id: String, mask: UInt)] = [
      ("cmd", 0x0008), ("rcmd", 0x0010),  // NX_DEVICEL/RCMDKEYMASK
      ("shift", 0x0002), ("rshift", 0x0004),  // NX_DEVICEL/RSHIFTKEYMASK
      ("opt", 0x0020), ("ropt", 0x0040),  // NX_DEVICEL/RALTKEYMASK
      ("ctrl", 0x0001 | 0x2000),  // NX_DEVICEL/RCTLKEYMASK（配列は単一 ctrl）
    ]
    for entry in device {
      if raw & entry.mask != 0 { next.insert(entry.id) } else { next.remove(entry.id) }
    }
    if event.modifierFlags.contains(.function) { next.insert("fn") } else { next.remove("fn") }
    let hadCommand = pressed.contains("cmd") || pressed.contains("rcmd")
    if hadCommand, !event.modifierFlags.contains(.command) {
      next = next.filter { HelpCatalog.modifierKeys.contains($0) }
    }
    return next
  }
}
