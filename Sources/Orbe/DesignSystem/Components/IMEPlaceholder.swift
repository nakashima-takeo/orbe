import AppKit
import SwiftUI

// MARK: - IME-aware プレースホルダ共通モディファイア

extension View {
  /// chrome 入力欄の自前プレースホルダを描きつつ、IME 変換中（field editor の marked text がある間）は
  /// 抑制する共通モディファイア。空欄かつ非変換のときだけ `text` を muted で左詰め描画する
  /// （純正 placeholder は色を握れず、かつ marked text 中も消えないため各欄が自前描画していた経緯を集約）。
  ///
  /// - Parameters:
  ///   - text: プレースホルダ文言（String はリテラルでないため markdown 解釈されず、URL も verbatim 相当）。
  ///   - isEmpty: binding が空か（＝プレースホルダを出す候補か）。marked text は binding に来ないため単独では不十分。
  ///   - focused: その欄がフォーカス中か。true の間だけ marked text を監視し、cross-talk を防ぐ。
  ///   - font/color: 既存 overlay と同一の見た目を再現するためのタイポ・色。
  func imePlaceholder(
    _ text: String, showWhenEmpty isEmpty: Bool, focused: Bool, font: Font, color: Color
  ) -> some View {
    modifier(
      IMEPlaceholder(text: text, isEmpty: isEmpty, focused: focused, font: font, color: color))
  }
}

/// `imePlaceholder(...)` の実体。`composing`（field editor に marked text がある）を内部 state で持ち、
/// 空欄かつ非変換のときだけプレースホルダを描く。監視は `MarkedTextObserver` に委ねる。
private struct IMEPlaceholder: ViewModifier {
  let text: String
  let isEmpty: Bool
  let focused: Bool
  let font: Font
  let color: Color
  @State private var composing = false

  func body(content: Content) -> some View {
    content
      .overlay(alignment: .leading) {
        if isEmpty && !composing {
          Text(text)
            .font(font)
            .foregroundStyle(color)
            .allowsHitTesting(false)
        }
      }
      .background(MarkedTextObserver(active: focused, composing: $composing))
  }
}

// MARK: - marked text 監視（field editor の未確定変換を検知するゼロサイズの不可視 NSView）

/// フォーカス中の field editor（`NSTextView`）に marked text（未確定 IME 変換）があるかをイベント駆動で
/// 監視し、`composing` へ反映する。`active`（＝自欄がフォーカス中）の間だけ購読し、外れたら購読解除して
/// `composing` を false へ戻す（非フォーカス欄が他欄の変換でプレースホルダを誤抑制する cross-talk を防ぐ）。
private struct MarkedTextObserver: NSViewRepresentable {
  let active: Bool
  @Binding var composing: Bool

  func makeNSView(context: Context) -> ObserverView {
    ObserverView { composing = $0 }
  }

  func updateNSView(_ nsView: ObserverView, context: Context) {
    nsView.onComposingChange = { composing = $0 }
    nsView.setActive(active)
  }

  /// marked text の有無を firstResponder から読むだけの軽量 probe。サイズを持たず描画にも参加しない。
  final class ObserverView: NSView {
    var onComposingChange: (Bool) -> Void
    private var active = false
    private var observers: [NSObjectProtocol] = []

    init(onComposingChange: @escaping (Bool) -> Void) {
      self.onComposingChange = onComposingChange
      super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    /// フォーカス状態に応じて購読を開始/停止する。停止時は composing を false へ戻す。
    func setActive(_ active: Bool) {
      guard active != self.active else { return }
      self.active = active
      if active {
        subscribe()
      } else {
        unsubscribe()
        // 非フォーカス欄は変換していない＝composing は false 固定。update 経路から SwiftUI state を
        // 同期で触らないよう次 tick へ逃がす（WindowProbe と同流儀）。
        DispatchQueue.main.async { [weak self] in self?.onComposingChange(false) }
      }
    }

    /// marked text の設定・変化は field editor の selection 変化通知で必ず飛ぶ。didChange も保険で拾う。
    /// object=nil で全体購読し、評価時に firstResponder が自 window の field editor のときだけ反映する。
    private func subscribe() {
      let center = NotificationCenter.default
      for name in [NSTextView.didChangeSelectionNotification, NSText.didChangeNotification] {
        observers.append(
          center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            self?.evaluate()
          })
      }
      // 初回評価も update 経路（updateNSView→setActive→subscribe）から SwiftUI state を同期で
      // 触らないよう次 tick へ逃がす（false 経路・WindowProbe と同流儀）。通知駆動の evaluate は
      // 元々 .main queue 経由で非同期のため、これで両経路とも update フェーズ外に揃う。
      DispatchQueue.main.async { [weak self] in self?.evaluate() }
    }

    private func unsubscribe() {
      observers.forEach { NotificationCenter.default.removeObserver($0) }
      observers.removeAll()
    }

    /// firstResponder（＝フォーカス欄の field editor）の marked text 有無を composing へ反映。
    private func evaluate() {
      let editor = window?.firstResponder as? NSTextView
      onComposingChange(editor?.hasMarkedText() ?? false)
    }
  }
}
