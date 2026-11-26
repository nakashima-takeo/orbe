import AppKit
import SwiftUI

/// 1 行の入力欄（AppKit の `NSTextField`）。命令でフォーカスを入れる欄（検索の列の入力欄・上のバーのファイル内検索の欄）が使う。
/// フォーカスの要求は、欄が窓に載った時点か、要求が来た時点に、欄が自分で first responder になって当てる。フォーカスの出入り・
/// 打った字（変換中の字は確定するまで入れない）・↵・⇧↵・esc は閉包で使う側へ知らせる。Tab は何もしない。取り消しの履歴は
/// 欄ごとに持つ。
struct EditorTextField: NSViewRepresentable {
  let text: String
  let placeholder: String
  let font: NSFont
  let placeholderColor: NSColor
  /// フォーカスを入れる要求があるか。当てたら（断られても）`requestDidApply` を呼ぶ。
  var wantsFocus = false
  var requestDidApply: () -> Void = {}
  var onTextChange: (String) -> Void = { _ in }
  var onFocusChange: (Bool) -> Void = { _ in }
  /// ↵（`shift` は ⇧↵）。変換の確定の ↵ では呼ばない。
  var onReturn: (_ shift: Bool) -> Void = { _ in }
  /// 変換中でない esc（`isRepeat` はキーリピート）。
  var onEscape: (_ isRepeat: Bool) -> Void = { _ in }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> Field {
    let field = Field()
    field.coordinator = context.coordinator
    context.coordinator.field = field
    return field
  }

  func updateNSView(_ field: Field, context: Context) {
    context.coordinator.view = self
    field.font = font
    field.placeholderAttributedString = NSAttributedString(
      string: placeholder, attributes: [.font: font, .foregroundColor: placeholderColor])
    field.setAccessibilityLabel(placeholder)
    if field.stringValue != text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
      field.stringValue = text
    }
    if wantsFocus { context.coordinator.scheduleFocusRequest() }
  }

  @MainActor
  final class Coordinator: NSObject {
    var view: EditorTextField?
    weak var field: Field?
    let undo = UndoManager()
    private var focusScheduled = false

    /// 要求を、SwiftUI の更新を終えた後に当てる（更新の途中で first responder を替えると、フォーカスの出入りの知らせが更新の
    /// 中で観測できる値を書き換える）。
    func scheduleFocusRequest() {
      guard !focusScheduled else { return }
      focusScheduled = true
      RunLoop.main.perform { [weak self] in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.focusScheduled = false
          self.applyFocusRequest()
        }
      }
    }

    /// 要求があり、欄が窓に載っていれば、first responder になって要求を消す。窓に載っていなければ、載ったときに当てる。
    func applyFocusRequest() {
      guard let view, view.wantsFocus, let field, let window = field.window else { return }
      if !window.makeFirstResponder(field) {
        NSLog("[editor] the text field could not become first responder")
      }
      view.requestDidApply()
    }
  }

  final class Field: NSTextField, NSTextViewDelegate {
    weak var coordinator: Coordinator?

    init() {
      super.init(frame: .zero)
      isBordered = false
      isBezeled = false
      drawsBackground = false
      focusRingType = .none
      textColor = Theme.Color.textPrimary
      lineBreakMode = .byClipping
      usesSingleLineMode = true
      cell?.isScrollable = true
      cell?.wraps = false
      setContentHuggingPriority(.defaultLow, for: .horizontal)
      setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window != nil { coordinator?.scheduleFocusRequest() }
    }

    override func becomeFirstResponder() -> Bool {
      let became = super.becomeFirstResponder()
      if became {
        (currentEditor() as? NSTextView)?.insertionPointColor = Theme.Color.accentPrimary
        coordinator?.view?.onFocusChange(true)
      }
      return became
    }

    override func textDidEndEditing(_ notification: Notification) {
      super.textDidEndEditing(notification)
      coordinator?.view?.onFocusChange(false)
    }

    override func textDidChange(_ notification: Notification) {
      super.textDidChange(notification)
      guard let editor = currentEditor() as? NSTextView, !editor.hasMarkedText() else { return }
      coordinator?.view?.onTextChange(editor.string)
    }

    func undoManager(for view: NSTextView) -> UndoManager? { coordinator?.undo }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      switch selector {
      case #selector(NSResponder.insertNewline(_:)):
        let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        coordinator?.view?.onReturn(shift)
        return true
      case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
        return true
      case #selector(NSResponder.cancelOperation(_:)):
        guard !textView.hasMarkedText() else { return false }
        coordinator?.view?.onEscape(NSApp.currentEvent?.isARepeat == true)
        return true
      default:
        return false
      }
    }
  }
}
