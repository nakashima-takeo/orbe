import AppKit
import OrbeEditorCore

/// Metal で描くテキスト面を作る唯一の入口。本文は渡さない——面は文書と結ばれたときに文書の写しを引く。`omittedLabel` は
/// 打ち切った行の末尾に出す印の文言（打ち切って描かない UTF-16 の単位の数から）。Metal の装置が取れない環境では nil。
@MainActor
public func makeMetalTextSurface(
  style: TextSurfaceStyle, omittedLabel: @escaping @Sendable (Int) -> String
) -> (any TextSurface)? {
  guard RenderThread.device != nil else { return nil }
  return MetalTextSurface(style: style, omittedLabel: omittedLabel)
}

/// Metal の装置を取り、描画スレッドを起こし、シェーダをコンパイルする——どれも裏で行い、呼び手を待たせない（何度呼んで
/// もよい。装置が無ければ何もしない）。最初の面を出すときにこれらの待ち（合わせて数十 ms）を見せないよう、面が要りそうに
/// なった時点で呼ぶ。済む前に面が要れば、面を作る・描くのは済んでから。
public func prepareMetalTextEngine() {
  DispatchQueue.global(qos: .userInitiated).async {
    guard RenderThread.device != nil else { return }
    _ = RenderThread.shared
  }
}
