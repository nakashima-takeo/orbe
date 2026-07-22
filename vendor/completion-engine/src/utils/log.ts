// inshellisense のファイルロガーは JSC では不要。runtime が呼ぶ debug を no-op にする。
export default {
  debug: (_: unknown) => {},
};
