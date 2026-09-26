import AppKit
import OrbeEditorCore

/// 新しい面の選び方のうち、面を作るときに決まるもの。
public struct MetalTextSurfaceOptions: Sendable {
  /// 端を越えて引っ張ると伸びて戻る（無ければ端で止まる）。
  public var elasticScroll: Bool
  /// 字の色の明るさに応じて字を太らせる（macOS の font smoothing 相当）。
  public var fontSmoothing: Bool
  /// 打ち切った行の末尾に出す印の文言（打ち切って描かない UTF-16 の単位の数から）。
  public var omittedLabel: @Sendable (Int) -> String

  public init(
    elasticScroll: Bool, fontSmoothing: Bool, omittedLabel: @escaping @Sendable (Int) -> String
  ) {
    self.elasticScroll = elasticScroll
    self.fontSmoothing = fontSmoothing
    self.omittedLabel = omittedLabel
  }
}

/// Metal で描く新しいテキスト面を作る唯一の入口。本文は渡さない——面は文書と結ばれたときに文書の写しを引く。Metal の装置が
/// 取れない環境では nil（呼び手は今の面を作る）。
@MainActor
public func makeMetalTextSurface(style: TextSurfaceStyle, options: MetalTextSurfaceOptions)
  -> (any TextSurface)?
{
  guard RenderThread.device != nil else { return nil }
  return MetalTextSurface(style: style, options: options)
}

/// 描画スレッドを起こし、シェーダのコンパイルを裏で始める（何度呼んでもよい。装置が無ければ何もしない）。最初の面を
/// 出すときにコンパイルの待ちを見せないよう、新しい面を使うと決まった時点で呼ぶ。済む前に面が要れば、描くのは済んでから。
public func prepareMetalTextEngine() {
  guard RenderThread.device != nil else { return }
  _ = RenderThread.shared
}
