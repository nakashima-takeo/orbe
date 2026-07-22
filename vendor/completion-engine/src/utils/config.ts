// inshellisense の設定ファイル読込は不要。runtime が参照するフラグだけを固定で返す。
// Orbe は Nerd Font アイコンを使わず（説明テキストのみ表示）、エイリアス読込もしない。
export type Config = { useNerdFont: boolean; useAliases: boolean };

const config: Config = { useNerdFont: false, useAliases: false };

export const getConfig = (): Config => config;
