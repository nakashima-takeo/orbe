import AppKit
import GhosttyKit

/// libghostty ランタイム（プロセスに 1 つ）。
/// app/config の生成、runtime callbacks の配線、surface→view レジストリを持つ。
///
/// 注: コールバックは libghostty の任意スレッドから来うるが、本実装は
/// `ghostty_app_tick` を main で駆動するため action_cb も実質 main で発火する。
/// `nonisolated(unsafe)` は「main スレッド規律で同期を保証する」前提のエスケープ。
final class Ghostty {
  nonisolated(unsafe) static let shared = Ghostty()

  let app: ghostty_app_t
  private(set) var config: ghostty_config_t

  private final class WeakView {
    weak var view: SurfaceView?
    init(_ v: SurfaceView) { view = v }
  }
  nonisolated(unsafe) private var registry: [UnsafeMutableRawPointer: WeakView] = [:]

  private init() {
    if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
      fatalError("ghostty_init failed")
    }

    config = Config.load()

    var rt = ghostty_runtime_config_s()
    rt.userdata = nil
    rt.supports_selection_clipboard = false
    // 処理待ちイベント発生 → main で tick
    rt.wakeup_cb = { _ in
      DispatchQueue.main.async { Ghostty.shared.tick() }
    }
    // タイトル/描画要求/ベル等のアクション
    rt.action_cb = { appPtr, target, action in
      Ghostty.shared.handleAction(appPtr, target, action)
    }
    // クリップボード読み取り（ペースト）: NSPasteboard を読んで complete で返す。
    // confirmed=false で返すと、安全な内容はそのまま貼られ、危険なペーストや OSC 52 read
    // （端末アプリ発の読み取り）だけが confirm_read_clipboard_cb へ回る（upstream 準拠）。
    rt.read_clipboard_cb = { userdata, _, state in
      guard let userdata, let surface = SurfaceView.from(userdata).surfacePtr else { return false }
      let text = NSPasteboard.general.string(forType: .string) ?? ""
      text.withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, false) }
      return true
    }
    // 確認フェーズ。ここへ来るのは危険ペーストと OSC 52 read のみ。
    // OSC 52 read は情報漏洩になるため、実内容を返さず空文字で完了して拒否する
    // （空 + confirmed で完了させ state をリークさせない）。危険ペーストの確認 UI は v1.1、
    // 今は従来どおり許可する。
    rt.confirm_read_clipboard_cb = { userdata, str, state, request in
      guard let userdata, let surface = SurfaceView.from(userdata).surfacePtr else { return }
      if request == GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ {
        "".withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, true) }
        return
      }
      ghostty_surface_complete_clipboard_request(surface, str, state, true)
    }
    // クリップボード書き込み（コピー）: 先頭コンテンツを NSPasteboard へ
    rt.write_clipboard_cb = { _, _, contents, len, _ in
      guard let contents, len > 0, let data = contents[0].data else { return }
      let pb = NSPasteboard.general
      pb.clearContents()
      pb.setString(String(cString: data), forType: .string)
    }
    // surface クローズ要求（shell の exit 等）: 該当ペインを閉じる
    rt.close_surface_cb = { userdata, _ in
      guard let userdata else { return }
      let view = SurfaceView.from(userdata)
      DispatchQueue.main.async { view.controller?.close(view) }
    }

    guard let a = ghostty_app_new(&rt, config) else { fatalError("ghostty_app_new failed") }
    app = a
  }

  func tick() {
    ghostty_app_tick(app)
  }

  /// 設定をディスクから読み直して app 全体へ適用する（キーバインド reload_config の hard reload）。
  /// update は内部で複製され全 surface へ伝播するため、適用後に旧 config を解放して差し替える。
  func reloadConfig() {
    let new = Config.load()
    ghostty_app_update_config(app, new)
    ghostty_config_free(config)
    config = new
  }

  // MARK: - surface → view レジストリ

  func register(_ surface: ghostty_surface_t, view: SurfaceView) {
    registry[surface] = WeakView(view)
  }

  func unregister(_ surface: ghostty_surface_t) {
    registry.removeValue(forKey: surface)
  }

  func view(for surface: ghostty_surface_t) -> SurfaceView? {
    registry[surface]?.view
  }
}
