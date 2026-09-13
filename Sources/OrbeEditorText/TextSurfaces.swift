import OrbeEditorCore

/// テキスト面を作る唯一の入口。実装は STTextView だが、その型は外に出ない。
@MainActor
public func makeTextSurface(style: TextSurfaceStyle, text: String) -> any TextSurface {
  STTextSurface(style: style, text: text)
}
