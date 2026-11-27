import AppKit
import SwiftUI

/// コミットのポップアップの持ち主（面ごとに 1 つ。根が変われば `ScmPanel` と組で作り直す）。上のバーの右端の「コミット」と
/// 変更の列の ⌘↑ で、面のポップアップの器に開閉を頼み、中身（→ `ScmCommitPopupView`）を渡す。
/// - 開いたらメッセージ欄へフォーカスを入れる（欄が窓に載った時点で当てる）。欄の ↵ はコミット、⌘↵ はコミットしてプッシュ
///   （押し続けたキーリピートは無視して何もしない）、変換中でない esc は閉じる。
/// - コミット・amend・コミットしてプッシュの 1 段目が通ったら閉じる（取り消しでは閉じない。続けて書き直せる）。
/// - 閉じる直前に、欄の変換を確定し、▾ のメニューを閉じる。赤い行に出していた失敗は消さない（閉じた後は失敗の札に出る）。
///
/// ▾ のメニューは一覧の器をもう 1 つ持つ。項目の可否と働きは、開いた時点の写しで決める。開くとフォーカスはメニューの行の列へ
/// 移り、メニューだけを閉じたらメッセージ欄へ戻る（フォーカスが外へ移って閉じたときは触れない）。
@MainActor @Observable
final class ScmCommitPopup {
  /// ▾ のメニューの項目。
  enum MenuItem: Hashable {
    case amend
    case commitAndPush
    case undo
  }

  let panel: ScmPanel
  /// ▾ のメニュー（一覧の器）。
  let menu = EditorItemList()
  /// 面のポップアップの器。
  @ObservationIgnored private weak var popup: EditorPopup?
  /// ▾ を開いた時点の写し（項目の可否と働き）。
  @ObservationIgnored private var menuSnapshot: ScmCommitSnapshot?
  /// メッセージ欄へフォーカスを入れる要求。
  @ObservationIgnored private var wantsFieldFocus = false
  /// 載っているメッセージ欄（ポップアップを開くたびに作り直される）。
  @ObservationIgnored weak var field: MessageTextView?
  /// 閉じる途中（メニューを閉じても、フォーカスを欄へ戻さない——器が開く前の場所へ戻す）。
  @ObservationIgnored private var isClosing = false
  /// メニューの項目の文言の言語（面が配る。使う時点で読む）。
  @ObservationIgnored var language: () -> Language = { .systemDefault }
  /// ▾ のメニューを閉じた。閉じたきっかけを面へ渡す（esc で閉じたなら、面が押し続けた esc を捨て始める）。
  @ObservationIgnored var menuDidClose: (EditorDismissal) -> Void = { _ in }

  init(panel: ScmPanel, popup: EditorPopup) {
    self.panel = panel
    self.popup = popup
    panel.control.addObserver(self)
    menu.onClose = { [weak self] dismissal in
      guard let self else { return }
      menuDidClose(dismissal)
      guard dismissal.returnsFocus, !isClosing else { return }
      focusField()
    }
  }

  /// ポップアップが開いている（器が開いていて、中身がこの持ち主）。
  var isOpen: Bool { popup?.isOpen == true && popup?.owner === self }

  /// 右端の「コミット」を押した（開いていれば閉じる）。
  func toggle() {
    popup?.toggle(self)
  }

  /// 開く（開いていれば何もしない）。
  func open() {
    popup?.open(self)
  }

  /// 器に閉じるよう頼む。
  func close(_ dismissal: EditorDismissal) {
    guard isOpen else { return }
    popup?.close(dismissal)
  }

  /// 欄へのフォーカスの要求を適用する（欄が窓に載っていなければ、載った時点で欄が呼ぶ）。
  func applyFieldFocus() {
    guard wantsFieldFocus, isOpen, let field, let window = field.window else { return }
    wantsFieldFocus = false
    window.makeFirstResponder(field)
  }

  private func focusField() {
    wantsFieldFocus = true
    applyFieldFocus()
  }

  // MARK: - ▾ のメニュー

  /// ▾ を押した。開いていれば閉じ（フォーカスは欄へ戻る）、閉じていれば今の写しで開いて行の列へフォーカスを移す。
  func toggleMenu() {
    if menu.isOpen {
      menu.close(.toggle)
    } else {
      menu.open(self)
      menu.requestFocus()
    }
  }

  /// メニューの外のポップアップの地を押した。
  func pressGround() {
    menu.close(.outsidePress)
  }
}

extension ScmCommitPopup: EditorPopupOwner {
  func popupContent() -> AnyView {
    AnyView(ScmCommitPopupView(owner: self))
  }

  func popupDidOpen() {
    focusField()
  }

  func popupWillClose(_ dismissal: EditorDismissal) {
    isClosing = true
    defer { isClosing = false }
    panel.confirmComposition()
    menu.close(dismissal)
    wantsFieldFocus = false
  }

  /// ⌘↵ はコミットしてプッシュ（押した時点の写しで押せなければ音で断る）。押し続けたキーリピートは無視して何もしない。
  func popupKeyEquivalent(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
    guard flags == [.command] else { return false }
    switch event.specialKey {
    case .carriageReturn?, .enter?, .newline?:
      if !event.isARepeat { panel.commitFromMessage(andPush: true) }
      return true
    default:
      return false
    }
  }
}

extension ScmCommitPopup: EditorItemListOwner {
  /// 開いた時点の写しで、可否が偽の項目は選べない行にする。最初は何も選ばない（↵ で思わず amend しない）。
  func itemListContent() -> EditorItemListContent {
    let snapshot = panel.commitSnapshot()
    menuSnapshot = snapshot
    let language = self.language()
    let state = snapshot.state
    return EditorItemListContent(
      rows: ScmCommitMenuRows(items: [
        .init(
          id: .amend, title: L10n.string(.editorScmAmend, language), isEnabled: state.canAmend),
        .init(
          id: .commitAndPush, title: L10n.string(.editorScmCommitAndPush, language), key: "⌘↵",
          isEnabled: state.canCommitAndPush),
        .init(id: .undo, title: L10n.string(.editorScmUndo, language), isEnabled: state.canUndo),
      ]),
      initialSelection: nil, hints: [])
  }

  func itemListDetail(of id: AnyHashable) -> EditorItemListContent? { nil }

  /// 写しの働きを実行し、メニューを閉じる（フォーカスは欄へ戻る）。
  func itemListCommit(_ id: AnyHashable) -> EditorItemListOutcome {
    guard let snapshot = menuSnapshot, let item = id.base as? MenuItem else { return .close }
    switch item {
    case .amend: snapshot.amend()
    case .commitAndPush: snapshot.commitAndPush()
    case .undo: snapshot.undoLastCommit()
    }
    return .close
  }

  func itemListPress(_ id: AnyHashable) {}
}

extension ScmCommitPopup: SourceControlObserver {
  /// コミット・amend・コミットしてプッシュの 1 段目が通ったら閉じる。
  func sourceControl(
    _ control: SourceControl, firstStepDidFinish operation: SourceControl.Operation,
    outcome: SourceControl.FirstStepOutcome
  ) {
    guard outcome == .passed, [.commit, .amend, .commitAndPush].contains(operation.kind) else {
      return
    }
    close(.owner)
  }

  func sourceControl(_ control: SourceControl, operationDidFinish kind: SourceControl.Kind) {}
}

/// ▾ のメニューの行の組——操作の行（題・右のキーの札・選べるか）だけ。
struct ScmCommitMenuRows: EditorItemListRows {
  struct Item {
    let id: ScmCommitPopup.MenuItem
    let title: String
    var key: String?
    let isEnabled: Bool
  }

  let items: [Item]

  var count: Int { items.count }

  func row(at index: Int) -> EditorItemListRow {
    .action(items[index].title, key: items[index].key)
  }

  func id(at index: Int) -> AnyHashable? { items[index].isEnabled ? items[index].id : nil }

  func index(of id: AnyHashable) -> Int? {
    items.firstIndex { $0.isEnabled && $0.id == id.base as? ScmCommitPopup.MenuItem }
  }
}
