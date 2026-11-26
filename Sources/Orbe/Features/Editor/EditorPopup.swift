import AppKit
import SwiftUI

/// ポップアップの器が、載せる側へ問う口。中身（入力欄・ボタン・地の部品での包み方）・入力欄へのフォーカスの入れ方・
/// ↵ と ⌘↵ の意味・書きかけの保管は、載せる側が持つ。
@MainActor
protocol EditorPopupOwner: AnyObject {
  /// 中身の view（地の部品で包んだもの）。
  func popupContent() -> AnyView
  /// 開いた（中身は窓に載っている。自分の入力欄へフォーカスを入れる）。
  func popupDidOpen()
  /// 閉じる直前（中身はまだ窓に居る。変換中の字を確定し、書きかけへ入れる。この中で器を開閉しない）。
  func popupWillClose(_ dismissal: EditorDismissal)
  /// フォーカスが置き場の中にある間の ⌘ つきのキー。扱ったら true。
  func popupKeyEquivalent(_ event: NSEvent) -> Bool
}

/// ポップアップの器——上のバーの右端のボタンから、バーの右下に開くポップアップの開閉と、載せる側を持つ。器の状態を書くのは
/// 器だけで、置き方・フォーカス・閉じ方の監視は、器を持つ pane が `onOpen` / `onClose` で受ける。
@MainActor @Observable
final class EditorPopup {
  private(set) var isOpen = false
  @ObservationIgnored private(set) weak var owner: EditorPopupOwner?
  /// 開いた（pane が置き直し、開く前のフォーカスの場所を覚え、フォーカスの監視を始める）。載せる側へ知らせる前に呼ぶ。
  @ObservationIgnored var onOpen: () -> Void = {}
  /// 閉じた（引数はきっかけ）。載せる側へ知らせ、閉じた状態にした後に呼ぶ。
  @ObservationIgnored var onClose: (EditorDismissal) -> Void = { _ in }

  /// `owner` の中身で開く（開いていれば何もしない）。
  func open(_ owner: EditorPopupOwner) {
    guard !isOpen else { return }
    self.owner = owner
    isOpen = true
    onOpen()
    owner.popupDidOpen()
  }

  /// 閉じる。先に載せる側へ知らせ（中身がまだ窓に居るうち）、閉じた状態にしてから pane へ知らせる（知らせの中でフォーカスが
  /// 動き、ここへ戻っても何もしない）。
  func close(_ dismissal: EditorDismissal) {
    guard isOpen else { return }
    owner?.popupWillClose(dismissal)
    isOpen = false
    owner = nil
    onClose(dismissal)
  }

  /// 開いていれば閉じ、閉じていれば `owner` の中身で開く（右端のボタンを押した）。
  func toggle(_ owner: EditorPopupOwner) {
    if isOpen {
      close(.toggle)
    } else {
      open(owner)
    }
  }

  /// ⌘ つきのキーを中身へ渡す。扱ったら true。
  func keyEquivalent(_ event: NSEvent) -> Bool {
    guard isOpen, let owner else { return false }
    return owner.popupKeyEquivalent(event)
  }
}
