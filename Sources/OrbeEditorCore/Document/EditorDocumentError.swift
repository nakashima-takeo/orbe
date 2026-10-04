import Foundation

public enum EditorDocumentError: Error, Equatable {
  case unreadable(URL)
  case notUTF8(URL)
  /// ディスクの内容が最後に読んだ／書いたものと違う。force でない保存はディスクに触れずこれで返る。
  case diskChanged(URL)
}
