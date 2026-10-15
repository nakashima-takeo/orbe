import OrbeEditorCore

/// 差し込んだ行の出どころ（テスト）——本文 `text` の写し（役割なし）。
@MainActor
final class TextRowSource: SurfaceRowSource {
  let rowSourceContent: SurfaceContent

  init(_ text: String) {
    let rope = TextRope(text)
    rowSourceContent = SurfaceContent(text: rope, roles: RoleRuns(length: rope.length), version: 0)
  }
}
