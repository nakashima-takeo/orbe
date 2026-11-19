import AppKit
import OrbeEditorCore

/// コメントの本文を本文の幅で測ったもの——コメントの本文の段と、段を幅で折り返した行。値だけを持ち、どのスレッドへも渡せる
/// （載せる側は裏で測り、main で覚える）。
struct PrCommentMeasure: Sendable {
  struct Block: Sendable {
    let block: PrCommentBlock
    let lines: [ZoneTextLayout.Line]
  }

  /// 測った本文（同じコメントでも本文が変われば測り直す）。
  let body: String
  let blocks: [Block]

  /// 本文 `body` を段に変換し、幅 `width` で測る。仕事は本文の長さに比例する。
  static func measure(_ body: String, width: CGFloat) -> PrCommentMeasure {
    PrCommentMeasure(
      body: body,
      blocks: PrCommentMarkdown.blocks(body).map { block in
        Block(
          block: block,
          lines: ZoneTextLayout.lines(block.text, width: max(1, width - inset(of: block))))
      })
  }

  /// 段の字の左端の、本文の左端からの距離（字下げと、コードブロックの余白）。
  static func inset(of block: PrCommentBlock) -> CGFloat {
    block.indent + (block.kind == .code ? Theme.Layout.editorPrBodyCodePad * 2 : 0)
  }
}

/// 本文の幅ごとに測ったコメントを覚え、無ければ裏で測る（→ code.md の「載せる側の作り方」）。絵を問われた幅の覚えが無い
/// 間は、ほかの幅で測った同じ本文（仮の行）で組ませ、測り終えたら `done` で描き直させる。覚える幅は最近使った数個だけ。
@MainActor
final class PrCommentMeasures {
  /// コメントの id と本文。
  typealias Comment = (id: String, body: String)

  private var byWidth: [CGFloat: [String: PrCommentMeasure]] = [:]
  /// 覚えた幅（使った時が古い順）。
  private var widths: [CGFloat] = []
  /// 裏で測っている幅と、測り終えた後に測りたい幅。
  private var measuring: CGFloat?
  private var wanted: (width: CGFloat, comments: [Comment])?
  /// 測り終えた（覚えから組めるようになった）。
  var done: () -> Void = {}

  private static let keptWidths = 3

  /// 裏で測っている。
  var isMeasuring: Bool { measuring != nil }

  /// 幅 `width` で組むコメント `comments` の測った本文。覚えに無いコメントは裏で測り始め、その間はほかの幅で測った同じ本文を
  /// 返す（どの幅でも測っていなければ返さない）。返した値の幅が `width` と違うことがある。
  func measures(_ comments: [Comment], width: CGFloat) -> [String: PrCommentMeasure] {
    if widths.last != width, let used = widths.firstIndex(of: width) {
      widths.append(widths.remove(at: used))
    }
    let known = byWidth[width] ?? [:]
    let missing = comments.filter { known[$0.id]?.body != $0.body }
    guard !missing.isEmpty else { return known }
    request(missing, width: width)
    var result = known
    for comment in missing {
      result[comment.id] = widths.reversed().lazy.compactMap { [byWidth] in
        byWidth[$0]?[comment.id]
      }.first { $0.body == comment.body }
    }
    return result
  }

  private func request(_ comments: [Comment], width: CGFloat) {
    guard measuring == nil else {
      wanted = (width, comments)
      return
    }
    measuring = width
    Task.detached(priority: .userInitiated) { [weak self] in
      let measured = comments.map { ($0.id, PrCommentMeasure.measure($0.body, width: width)) }
      await MainActor.run { [weak self] in self?.store(measured, width: width) }
    }
  }

  private func store(_ measured: [(String, PrCommentMeasure)], width: CGFloat) {
    measuring = nil
    if byWidth[width] == nil {
      widths.append(width)
      if widths.count > Self.keptWidths { byWidth[widths.removeFirst()] = nil }
    }
    for (id, measure) in measured { byWidth[width, default: [:]][id] = measure }
    let next = wanted
    wanted = nil
    if let next {
      let known = byWidth[next.width] ?? [:]
      let missing = next.comments.filter { known[$0.id]?.body != $0.body }
      if !missing.isEmpty { request(missing, width: next.width) }
    }
    done()
  }
}
