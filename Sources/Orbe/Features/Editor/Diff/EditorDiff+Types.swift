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
    /// PR。PR ごとの状態そのものを持ち、識別は状態の key（手元のリポジトリと PR の同一性）——状態を手にしている者
    /// だけが開ける。コミットは識別に入れない——PR に push があっても同じ diff のまま。
    case pullRequest(PullRequestState)

    /// この種類の diff を出す画面。
    var screen: EditorScreen {
      switch self {
      case .workingTree, .staged: .changes
      case .pullRequest: .pullRequest
      }
    }

    static func == (lhs: Kind, rhs: Kind) -> Bool {
      switch (lhs, rhs) {
      case (.workingTree, .workingTree), (.staged, .staged): true
      case (.pullRequest(let a), .pullRequest(let b)): a.key == b.key
      default: false
      }
    }

    func hash(into hasher: inout Hasher) {
      switch self {
      case .workingTree: hasher.combine(0)
      case .staged: hasher.combine(1)
      case .pullRequest(let state):
        hasher.combine(2)
        hasher.combine(state.key)
      }
    }
  }

  /// 見せ方。本体の幅で決まる（→ `init(bodyWidth:)`）。
  enum Mode {
    case inline
    case side

    /// 本体の幅 `bodyWidth` での見せ方——境の値（`Theme.Layout.editorDiffSideWidth`）以上なら並列、未満ならインライン。
    init(bodyWidth: CGFloat) {
      self = bodyWidth >= Theme.Layout.editorDiffSideWidth ? .side : .inline
    }
  }

  /// 表示できない理由。
  enum Unavailable: Equatable {
    /// UTF-8 として読めない（バイナリ・別の符号化）。
    case notText
    /// 作業ツリーのパスがシンボリックリンク。
    case symlink
    /// 作業ツリーのパスが、サブモジュールとして見せられないディレクトリ。
    case directory
    /// 作業ツリーのファイルを読めない。
    case unreadable
    /// 競合中。
    case conflicted
    /// git から取れない。
    case failed
    /// 両側とも無い（作業ツリー: 作業ツリーにも index にも無い。ステージ済み: HEAD にも index にも無い。PR: マージベースにも
    /// PR の先頭にも無い）。
    case nowhere
    /// PR のコミットが手元に無く、取りに行っても揃わない。
    case pullRequestCommitsMissing
    /// PR がベースブランチと共通のコミットを持たない。
    case pullRequestUnrelated
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
    /// diff が作業ツリーの姿で新しい側の文書を替えた（引数は前の文書。無かったなら nil）。前の文書は開いている文書の列に
    /// 無ければ閉じる。
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

  /// 古い側と新しい側の本文（その版に無い側は nil）。
  struct SideTexts: Equatable {
    let old: String?
    let new: String?
  }
}
