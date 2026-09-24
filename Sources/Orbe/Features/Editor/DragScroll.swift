import Foundation
import OrbeEditorCore

/// ドラッグ中の「この行を先頭に」を runloop 1 回に 1 つ（最新）へ間引く。遠くへ飛ぶスクロールはテキストエンジンの
/// layout が重く（1MB・4 万行で 1 回 100ms 超）、ドラッグの出来事ごとに走らせると古い位置の layout が溜まって指に
/// 遅れる。離したときに残っている分はその場で当てる。
@MainActor
final class DragScroll {
  private weak var document: EditorDocument?
  private var pending: CGFloat?

  /// 先頭行を `line` へ（次の runloop で、その時点の最新だけを当てる）。
  func scroll(_ document: EditorDocument, toFirstLine line: CGFloat) {
    self.document = document
    let scheduled = pending != nil
    pending = line
    guard !scheduled else { return }
    RunLoop.main.perform { [weak self] in
      MainActor.assumeIsolated { self?.flush() }
    }
  }

  /// 残っている分をその場で当てる。
  func flush() {
    guard let line = pending else { return }
    pending = nil
    document?.scroll(toFirstLine: line)
  }
}
