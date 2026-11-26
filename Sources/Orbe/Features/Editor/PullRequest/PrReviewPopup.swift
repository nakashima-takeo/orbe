import AppKit
import SwiftUI

/// レビューのポップアップの面ごとの持ち主——ポップアップの器（`EditorPopup`）に、全体へのコメント・未送信のコメントの一覧・
/// 種類・送信を載せる。規則（選べる種類・送れるか・送信）は PR ごとの状態が持ち、ここが持つのは、開いたときの PR ごとの
/// 状態・全体へのコメント欄の変換中の字（確定するまで書きかけに入れない。欄が写す）・器への頼み方。面ごとに 1 つで、根が
/// 替われば面が作り直す。
@MainActor @Observable
final class PrReviewPopup: EditorPopupOwner {
  /// worktree の今の PR（PR のパネルと同じ 1 つ）。
  let pullRequest: BranchPullRequest
  @ObservationIgnored let popup: EditorPopup
  /// 開いたときの PR ごとの状態（閉じている間は nil）。
  private(set) var openedState: PullRequestState?
  /// 全体へのコメント欄の変換中の字。
  var composition = ""
  /// 未送信のコメントの行を押した（今の diff に置ける行。面が、その場所を開く）。
  @ObservationIgnored var onReveal: (PullRequestState.PendingComment) -> Void = { _ in }
  /// URL をブラウザで開く。
  @ObservationIgnored var onOpenURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
  /// 全体へのコメント欄（欄が結ぶ）と、欄へフォーカスを入れる頼み（欄が窓に載っていなければ、載ったときに当てる）。
  @ObservationIgnored weak var field: MessageTextView?
  @ObservationIgnored private var wantsFocus = false

  init(pullRequest: BranchPullRequest, popup: EditorPopup) {
    self.pullRequest = pullRequest
    self.popup = popup
  }

  /// 今の PR の状態（PR があるときだけ）。
  var state: PullRequestState? { pullRequest.state }

  /// 「レビュー」のボタンを出すか——open の PR があり、中身が読めている。
  var isAvailable: Bool { state?.isOpenPullRequest == true }

  /// 開けるか——ボタンを出していて、選べる種類が空でない（レビューのやりとりを読めるまでは、自分の PR かどうかが分からず、
  /// 種類を出すかを決められない）。バーのボタンの押せる姿と、一覧の ⌘↑ が読む。
  var canOpen: Bool { isAvailable && state?.reviewEvents.isEmpty == false }

  /// この持ち主の中身で器が開いている。
  var isOpen: Bool { popup.isOpen && popup.owner === self }

  /// 右端のボタンを押した——開いていれば閉じ、閉じていて開けるなら開く。
  func toggle() {
    guard isOpen || canOpen else { return }
    popup.toggle(self)
  }

  /// 一覧の ⌘↑——開けるなら開く（開いていれば何もしない）。
  func requestOpen() {
    guard canOpen, !popup.isOpen else { return }
    popup.open(self)
  }

  /// 欄に見えている字（書きかけと変換中の字）で送れるか。
  var canSubmit: Bool { openedState?.canSubmitReview(composing: composition) ?? false }

  /// 送る。欄が変換中なら先に確定する（確定した字が書きかけに入るので、欄に見えていた字で決めた可否と、送る本文が揃う）。
  /// 送れなければ何もせず false を返す。通ったと返ったら、頼んだときの PR のまま開いていれば閉じる。
  @discardableResult
  func submit() -> Bool {
    confirmComposition()
    guard let state = openedState else { return false }
    return state.submitReview { [weak self, weak state] passed in
      guard passed, let self, let state, isOpen, openedState === state else { return }
      popup.close(.owner)
    }
  }

  /// 未送信のコメントの行を押した。今の diff に置ける行なら、閉じてからその場所を開くよう面へ頼み、置けない行なら GitHub の
  /// PR を開く。
  func press(_ comment: PullRequestState.PendingComment) {
    guard comment.isPlaceable else { return openOnGitHub() }
    popup.close(.owner)
    onReveal(comment)
  }

  /// PR の GitHub のページをブラウザで開く。
  func openOnGitHub() {
    guard let url = (openedState ?? state)?.content.flatMap({ URL(string: $0.url) }) else { return }
    onOpenURL(url)
  }

  /// 全体へのコメント欄で、変換中でない esc を押した。
  func escape() {
    popup.close(.escape)
  }

  /// worktree の今の PR が替わった・その PR の状態が変わった。開いたときの PR と違う・PR が open でなくなった（ボタンを
  /// 出さなくなった）なら閉じる（変換中の字は、閉じる直前に開いたときの PR の書きかけへ確定する）。
  func pullRequestDidChange() {
    guard isOpen, openedState !== state || !isAvailable else { return }
    popup.close(.itemGone)
  }

  /// 欄が窓に載った・開いた。頼まれていれば欄へフォーカスを入れる。
  func applyFocus() {
    guard wantsFocus, let field, let window = field.window else { return }
    wantsFocus = false
    window.makeFirstResponder(field)
  }

  /// 全体へのコメント欄の変換中の字を確定する。
  func confirmComposition() {
    field?.confirmComposition()
  }

  // MARK: - EditorPopupOwner

  func popupContent() -> AnyView {
    guard let state = openedState else { return AnyView(EmptyView()) }
    return AnyView(PrReviewPopupView(popup: self, state: state))
  }

  func popupDidOpen() {
    openedState = state
    wantsFocus = true
    applyFocus()
  }

  /// 閉じる直前。変換中の字を開いたときの PR の書きかけへ確定し、写していた字を空にする。送信の失敗は残し、閉じた後は
  /// 上のバーの右下の札が出す。
  func popupWillClose(_ dismissal: EditorDismissal) {
    confirmComposition()
    composition = ""
    wantsFocus = false
    openedState = nil
  }

  /// ⌘↵ は送信（送れなければ音で断る）。押し続けたキーリピートは食って何もしない。
  func popupKeyEquivalent(_ event: NSEvent) -> Bool {
    guard event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.command]
    else { return false }
    switch event.specialKey {
    case .carriageReturn?, .enter?, .newline?:
      if event.isARepeat { return true }
      if !submit() { NSSound.beep() }
      return true
    default:
      return false
    }
  }
}
