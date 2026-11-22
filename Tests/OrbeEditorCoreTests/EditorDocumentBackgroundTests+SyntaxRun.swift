import OrbeTestSupport
import XCTest
import os

@testable import OrbeEditorCore

extension EditorDocumentBackgroundTests {
  /// 構文の裏の仕事の列に目印を積み、目印が走ってから、裏の仕事が置いた結果を main が受け取るまで待つ。作り直しの 1 回の
  /// 走りは列を譲らない 1 つの仕事なので、戻った時点で、目印より前に始まっていた走りは済み、その結果は文書に届いている。
  func waitForTheSyntaxRun(of document: EditorDocument) throws {
    let worker = try XCTUnwrap(document.syntax)
    let reached = OSAllocatedUnfairLock(initialState: false)
    Task.detached {
      await worker.mark()
      reached.withLock { $0 = true }
    }
    pumpMain(until: { reached.withLock { $0 } }, timeout: 30, "構文の裏の仕事の列の目印")
    nextTurn()
  }
}

extension SyntaxWorker {
  /// 何もしない仕事。列で、呼んだ時点より前に積まれた仕事の後に走る。
  fileprivate func mark() {}
}
