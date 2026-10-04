import OrbeEditorCore
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

extension OrbeTestCase {
  /// 文書のテキスト面のエンジン。製品の契約に位置を置く口と横の位置を読む口は無いので、テストはエンジンの中で置き・読む。
  @MainActor
  func engine(
    _ document: EditorDocument, file: StaticString = #filePath, line: UInt = #line
  ) throws -> MetalTextSurface {
    try XCTUnwrap(document.surface as? MetalTextSurface, file: file, line: line)
  }
}
