import AppKit
import SwiftUI

/// ツールバー URL 欄・新タブ中央 URL 入力欄・ポップオーバー内フォームで共有するインライン `NSTextField` ラッパー。
/// - `controlTextDidBeginEditing` で毎回明示終了フラグをリセットし、常駐欄の再フォーカス後も `onBlur` を保つ。
/// - 日本語 IME 変換中（`hasMarkedText()`）は Enter / Esc を握って IME 変換を保護する。
/// - 非同期フォーカス直前に `canFocus()`・`window != nil`・可視性を検証し、非表示・閉鎖後のゴースト焦点を防ぐ。
struct BrowserInlineTextField: NSViewRepresentable {
  @Binding var text: String
  let placeholder: String
  var font: NSFont = Theme.Typography.browserURL
  var focusToken = 0
  var selectAllOnFocus = true
  var canFocus: () -> Bool = { true }
  var onFocusChange: ((Bool) -> Void)?
  var onCommit: (String) -> Bool
  var onCancel: () -> Void
  var onBlur: () -> Void = {}

  func makeNSView(context: Context) -> NSTextField {
    let field = NSTextField(string: text)
    field.font = font
    field.textColor = Theme.Color.textPrimary
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.usesSingleLineMode = true
    field.lineBreakMode = .byClipping
    field.cell?.isScrollable = true
    field.placeholderString = placeholder
    field.delegate = context.coordinator
    return field
  }

  func updateNSView(_ nsView: NSTextField, context: Context) {
    let coordinator = context.coordinator
    coordinator.onTextChange = { text = $0 }
    coordinator.canFocus = canFocus
    coordinator.onFocusChange = onFocusChange
    coordinator.onCommit = onCommit
    coordinator.onCancel = onCancel
    coordinator.onBlur = onBlur
    nsView.placeholderString = placeholder
    if nsView.font != font { nsView.font = font }

    let isEditingNow =
      nsView.window?.firstResponder != nil
      && nsView.window?.firstResponder === nsView.currentEditor()
    let tokenChanged = coordinator.lastFocusToken != focusToken

    if tokenChanged {
      coordinator.lastFocusToken = focusToken
      if focusToken > 0 {
        coordinator.endedExplicitly = false
        if nsView.stringValue != text { nsView.stringValue = text }
        let selectAll = selectAllOnFocus
        DispatchQueue.main.async {
          guard coordinator.canFocus(),
            let window = nsView.window,
            !nsView.isHiddenOrHasHiddenAncestor
          else { return }
          if window.makeFirstResponder(nsView), selectAll {
            (window.firstResponder as? NSTextView)?.selectAll(nil)
          }
        }
        return
      }
    }

    if !isEditingNow && nsView.stringValue != text {
      nsView.stringValue = text
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(
      onTextChange: { text = $0 },
      canFocus: canFocus,
      onFocusChange: onFocusChange,
      onCommit: onCommit,
      onCancel: onCancel,
      onBlur: onBlur)
  }

  final class Coordinator: NSObject, NSTextFieldDelegate {
    var onTextChange: (String) -> Void
    var canFocus: () -> Bool
    var onFocusChange: ((Bool) -> Void)?
    var onCommit: (String) -> Bool
    var onCancel: () -> Void
    var onBlur: () -> Void
    var lastFocusToken = 0
    var endedExplicitly = false

    init(
      onTextChange: @escaping (String) -> Void,
      canFocus: @escaping () -> Bool,
      onFocusChange: ((Bool) -> Void)?,
      onCommit: @escaping (String) -> Bool,
      onCancel: @escaping () -> Void,
      onBlur: @escaping () -> Void
    ) {
      self.onTextChange = onTextChange
      self.canFocus = canFocus
      self.onFocusChange = onFocusChange
      self.onCommit = onCommit
      self.onCancel = onCancel
      self.onBlur = onBlur
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
      endedExplicitly = false
      onFocusChange?(true)
    }

    func controlTextDidChange(_ obj: Notification) {
      guard let field = obj.object as? NSTextField else { return }
      onTextChange(field.stringValue)
    }

    func control(
      _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
      if textView.hasMarkedText() {
        return commandSelector == #selector(NSResponder.insertNewline(_:))
          || commandSelector == #selector(NSResponder.cancelOperation(_:))
      }
      if commandSelector == #selector(NSResponder.insertNewline(_:)) {
        endedExplicitly = true
        if !onCommit(control.stringValue) {
          endedExplicitly = false
        }
        return true
      }
      if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
        endedExplicitly = true
        onCancel()
        return true
      }
      return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
      onFocusChange?(false)
      guard !endedExplicitly else { return }
      onBlur()
    }
  }
}
