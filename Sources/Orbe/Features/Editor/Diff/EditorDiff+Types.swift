import Foundation
import OrbeEditorCore

extension EditorDiff {
  /// 識別——根・根からの相対パス・種類。
  struct Key: Hashable {
    let root: String
    let path: String
    let kind: Kind

    /// 作業ツリーのファイルの実体のパス。
    var url: URL { URL(fileURLWithPath: root).appendingPathComponent(path) }
  }

  enum Kind: Hashable {
    case workingTree
    case staged
  }

  /// 見せ方（アプリ全体で 1 つ。→ `EditorDiffModeState`）。
  enum Mode: String {
    case inline
    case side
  }

  /// 表示できない理由。
  enum Unavailable: Equatable {
    /// UTF-8 として読めない（バイナリ・別の符号化）。
    case notText
    /// 作業ツリーのパスがシンボリックリンク。
    case symlink
    /// 競合中。
    case conflicted
    /// git から取れない。
    case failed
    /// 両側とも無い（作業ツリー: 作業ツリーにも index にも無い。ステージ済み: HEAD にも index にも無い）。
    case nowhere
  }

  /// 見せられる中身。
  enum Content: Equatable {
    /// 版の本文がまだ届いていない。
    case loading
    case unavailable(Unavailable)
    case ready
  }

  /// 作業ツリー diff が新しい側の文書を引く口と、替わったと知らせる口（文書は実体ごとに 1 つで、セッションが持ち主を数える）。
  struct Documents {
    let open: (URL) throws -> EditorDocument
    /// diff が作業ツリーの姿で新しい側の文書を替えた（引数は前の文書。無かったなら nil）。前の文書はほかに使うタブが無ければ
    /// 閉じ、仮のタブとタブ行を今の文書に合わせる。
    let switched: (EditorDocument?) -> Void
  }

  /// 初めての位置決めの段階。開いた時点に追いついた最初の並びで 1 回だけ、最初の変更区間へ送る（以後の変化では送らない）。
  enum Placement {
    /// 開いた後の根のサービスの取り直しと、その後の状態から作った並びを待っている。
    case catchingUp
    /// 追いついた。面が大きさを持つのを待っている。
    case sizing
    /// 決めた。以後は作り直しで、見えていた所を引き継ぐだけ。
    case placed
  }

  /// 作り直した新しい側の面で先頭に置く所。
  enum Carried {
    /// 変わらない古い側の行の錨（新しい並びで位置に戻す）。
    case anchor(DiffRows.Anchor)
    /// 前の面の位置（両側とも変わったので錨が無い）。
    case position(RowPosition)
  }

  /// 作業ツリー diff の新しい側。
  enum WorkingSide {
    /// 開いた文書（ファイルタブと共有する）。
    case document(EditorDocument)
    /// 作業ツリーに無い（消した）。
    case missing
    /// ディレクトリ（`hasRepository` は中が取り出したリポジトリ）。index の版がサブモジュールか、中がリポジトリなら、
    /// サブモジュールとして「Subproject commit」の行で見せる。どちらでもなければ表示できない。
    case directory(hasRepository: Bool)
    case unavailable(Unavailable)
  }
}
