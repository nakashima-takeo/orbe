import SwiftUI

/// タブ行のドラッグ&ドロップ並び替え（同一 workspace 内・commit-on-drop）。掴み中はデータを変異させず、
/// 移動量から挿入先 index を出してキャレットで示し、指を離した瞬間に 1 回だけ `onReorder` を呼ぶ。
extension StatusRowView {
  /// タブ i の掴み。閾値超過でドラッグに確定し、移動量から挿入先 index を出してキャレットを更新する。
  /// no-op（同位置）で離しても store 側の範囲ガードが弾く。
  func tabDragGesture(i: Int, widths: [CGFloat]) -> some Gesture {
    DragGesture(minimumDistance: dragActivation)
      .onChanged { value in
        if dragFrom == nil { dragWidths = widths }  // 掴み開始時の幅を固定（以降 live な幅を見ない）
        dragFrom = i
        dragTranslation = value.translation.width
        dropIndex = insertionIndex(
          from: i, translation: value.translation.width, widths: dragWidths)
      }
      .onEnded { value in
        let j = insertionIndex(from: i, translation: value.translation.width, widths: dragWidths)
        dragFrom = nil
        dragTranslation = 0
        dropIndex = nil
        dragWidths = []
        model.onReorder(i, j)
      }
  }

  /// 掴んだタブ i を translation ぶん動かしたときの挿入先 index（0…count）。ドラッグ開始時に固定した
  /// 各タブ中心 x（`widths`＋`tabGap` から積算）とポインタ x（中心＋translation）を比べ、中心を
  /// 追い越したタブ数を数える。scroll offset に依らない（全て同一レイアウト空間の相対量）。
  func insertionIndex(from: Int, translation: CGFloat, widths: [CGFloat]) -> Int {
    guard !widths.isEmpty else { return 0 }
    var centers: [CGFloat] = []
    var x: CGFloat = 0
    for w in widths {
      centers.append(x + w / 2)
      x += w + Chrome.tabGap
    }
    let base = centers.indices.contains(from) ? centers[from] : 0
    let pointer = base + translation
    let crossed = centers.filter { $0 < pointer }.count
    return min(max(crossed, 0), widths.count)
  }

  /// 挿入先 index j の隙間中央（キャレットの x）。j 本目の左端 − tabGap/2。
  func insertionCaretX(_ j: Int, widths: [CGFloat]) -> CGFloat {
    var x: CGFloat = 0
    for k in 0..<min(j, widths.count) { x += widths[k] + Chrome.tabGap }
    return max(0, x - Chrome.tabGap / 2)
  }
}
