import Foundation
import TreeSitter
import os

/// 構文木 1 本（`TSTree`）。解放はこの型が持つ。構文の裏の仕事の中だけで使う。
final class SyntaxTree {
  let raw: OpaquePointer

  fileprivate init(_ raw: OpaquePointer) {
    self.raw = raw
  }

  deinit {
    ts_tree_delete(raw)
  }

  var root: TSNode { ts_tree_root_node(raw) }

  /// 別のスレッドで読むための写し（`ts_tree_copy`。部分木を共有し、この木に後から編集を当てても写しは変わらない）。
  func copy() -> TreeCopy {
    TreeCopy(tree: SyntaxTree(ts_tree_copy(raw)))
  }

  /// 構文の誤り（ERROR・MISSING）を含むか。
  var hasError: Bool { ts_node_has_error(root) }

  func edit(_ edit: TSInputEdit) {
    var edit = edit
    ts_tree_edit(raw, &edit)
  }

  /// 含める範囲を `ranges` に替えて差分解析する前に、前の範囲の終わりで入力の終わりを見た節を解析し直させる——tree-sitter
  /// は範囲の違いを節の位置と先読みの長さで見るが、最後の範囲の端で入力が終わった節は先読みがそこで止まるので、その後ろに
  /// 足した範囲の違いと交わらず、読み直さずに使い回される（閉じていない <script> の中身が、足した範囲の </script> まで
  /// 伸びない）。後ろに足した範囲の分だけ入力の終わりが動いたことを、前の最後の範囲の端での長さ 0 の編集として写す。
  func prepareToExtend(to ranges: [TSRange]) {
    var count: UInt32 = 0
    guard let old = ts_tree_included_ranges(raw, &count) else { return }
    defer { free(old) }
    guard count > 0, let last = ranges.last, last.end_byte > old[Int(count) - 1].end_byte else {
      return
    }
    let end = old[Int(count) - 1]
    edit(
      TSInputEdit(
        start_byte: end.end_byte, old_end_byte: end.end_byte, new_end_byte: end.end_byte,
        start_point: end.end_point, old_end_point: end.end_point, new_end_point: end.end_point))
  }

  /// この木（編集を写したもの）から `new` へ、構文が変わった区間（バイト）。
  func changedRanges(to new: SyntaxTree) -> [Range<Int>] {
    var count: UInt32 = 0
    guard let ranges = ts_tree_get_changed_ranges(raw, new.raw, &count) else { return [] }
    defer { free(ranges) }
    return UnsafeBufferPointer(start: ranges, count: Int(count)).map {
      Int($0.start_byte)..<Int($0.end_byte)
    }
  }
}

/// 構文木の写し。持ち主は 1 つだけで、持ち主が自分のスレッドで読み、手放す。
struct TreeCopy: @unchecked Sendable {
  let tree: SyntaxTree
}

/// 打ち切りの印。構文の裏の仕事では文書を閉じた印で、走っている解析を打ち切って止まる。アウトラインの裏の仕事では
/// 取り出し 1 回ごとの印で、新しい写しが届くか文書を閉じたら、走っている問い合わせを打ち切る。
final class SyntaxCancellation: Sendable {
  private let cancelled = OSAllocatedUnfairLock(initialState: false)

  func cancel() {
    cancelled.withLock { $0 = true }
  }

  var isCancelled: Bool { cancelled.withLock { $0 } }
}

/// 構文解析器 1 つ（`TSParser`）。文法と含める範囲を解析のたびに設定する。解析の入力は本文の写しを UTF-16 のまま、塊
/// 1 つぶんの使い回すバッファへ写しながら読ませる。閉じた印が立つと解析を打ち切り、以後は解析しない——打ち切った解析器を
/// 次の解析に使うと、初期化しない限り木が黙って誤るので、使う道を残さない。
final class SyntaxParser {
  enum Outcome {
    case parsed(SyntaxTree)
    /// 含める範囲を解析器が拒んだ（昇順で重ならない、を満たさない）。
    case rejected
    /// 文書を閉じた。
    case cancelled
  }

  private let raw: OpaquePointer
  private let reader = TextReader()
  let cancellation: SyntaxCancellation

  init(cancellation: SyntaxCancellation) {
    raw = ts_parser_new()
    self.cancellation = cancellation
  }

  deinit {
    ts_parser_delete(raw)
  }

  /// `text` の `origin`（UTF-16）を原点として解析する。`ranges` は含める範囲（原点からのバイトと行・桁。空なら全体）。
  /// `old` は編集を写した前の木。
  func parse(
    _ language: LanguagePointer, ranges: [TSRange], old: SyntaxTree?, text: TextRope, origin: Int
  ) -> Outcome {
    guard !cancellation.isCancelled else { return .cancelled }
    ts_parser_set_language(raw, language.raw)
    let accepted = ranges.withUnsafeBufferPointer {
      ts_parser_set_included_ranges(raw, $0.baseAddress, UInt32($0.count))
    }
    guard accepted else { return .rejected }
    reader.text = text
    reader.origin = origin
    defer { reader.text = TextRope() }
    let input = TSInput(
      payload: Unmanaged.passUnretained(reader).toOpaque(), read: readText,
      encoding: TSInputEncodingUTF16LE, decode: nil)
    let options = TSParseOptions(
      payload: Unmanaged.passUnretained(cancellation).toOpaque(), progress_callback: isCancelled)
    let tree = withExtendedLifetime((reader, cancellation)) {
      ts_parser_parse_with_options(raw, old?.raw, input, options)
    }
    guard let tree else { return .cancelled }
    return .parsed(SyntaxTree(tree))
  }
}

/// 解析の読み口。本文の写しの塊を、使い回すバッファへ写して貸す。
private final class TextReader {
  var text = TextRope()
  var origin = 0
  let buffer = UnsafeMutableBufferPointer<UInt16>.allocate(capacity: TextRope.chunkCapacity)

  deinit {
    buffer.deallocate()
  }
}

private let readText:
  @convention(c) (UnsafeMutableRawPointer?, UInt32, TSPoint, UnsafeMutablePointer<UInt32>?) ->
    UnsafePointer<CChar>? = { payload, byte, _, count in
      let reader = Unmanaged<TextReader>.fromOpaque(payload!).takeUnretainedValue()
      let units = reader.text.copyChunk(at: reader.origin + Int(byte / 2), into: reader.buffer)
      count!.pointee = UInt32(units * 2)
      return UnsafeRawPointer(reader.buffer.baseAddress!).assumingMemoryBound(to: CChar.self)
    }

private let isCancelled: @convention(c) (UnsafeMutablePointer<TSParseState>?) -> Bool = { state in
  Unmanaged<SyntaxCancellation>.fromOpaque(state!.pointee.payload!).takeUnretainedValue()
    .isCancelled
}
