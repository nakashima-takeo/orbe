// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
//
// inshellisense `src/runtime/runtime.ts` の trim・改変版。
// 改変点: spec の取得を @withfig 全網羅 + dynamic import から curated registry の同期参照へ置換。
// alias 展開・config・log・上流 dynamic spec location 読込は持たない。
// 解析・spec 走査・postProcess は上流ロジックのまま（責務分界: ファイル操作とシェル実行のみ Swift）。
import { parseCommand, CommandToken } from "./parser.js";
import { getArgDrivenRecommendation, getSubcommandDrivenRecommendation, SuggestionIcons } from "./suggestion.js";
import { Suggestion, SuggestionBlob } from "./model.js";
import { resolveCwd } from "./utils.js";
import { Shell } from "../utils/shell.js";
import { specRegistry } from "../specs/index.js";

const loadSpec = async (cmd: CommandToken[], signal?: AbortSignal): Promise<Fig.Spec | undefined> => {
  const rootToken = cmd.at(0);
  if (!rootToken?.complete) return;
  signal?.throwIfAborted();
  return specRegistry[rootToken.token];
};

// curated registry のみを引く。上流の spec location / 別ファイル spec の遅延読込は持たない。
const lazyLoadSpecLocation = async (_location: Fig.SpecLocation, _signal?: AbortSignal): Promise<Fig.Spec | undefined> => {
  return;
};

export const getSuggestions = async (cmd: string, cwd: string, shell: Shell, signal?: AbortSignal): Promise<SuggestionBlob | undefined> => {
  const activeCmd = parseCommand(cmd, shell);
  const rootToken = activeCmd.at(0);
  if (activeCmd.length === 0) {
    return;
  }
  if (rootToken != null && !rootToken.complete) {
    return runCommand(rootToken);
  }

  signal?.throwIfAborted();
  const spec = await loadSpec(activeCmd, signal);
  if (spec == null) return;
  const subcommand = getSubcommand(spec);
  if (subcommand == null) return;

  signal?.throwIfAborted();
  const lastCommand = activeCmd.at(-1);
  const { cwd: resolvedCwd, pathy, complete: pathyComplete } = await resolveCwd(lastCommand, cwd, shell, signal);
  if (pathy && lastCommand) {
    lastCommand.isPath = true;
    lastCommand.isPathComplete = pathyComplete;
  }
  const result = await runSubcommand(activeCmd.slice(1), activeCmd, subcommand, resolvedCwd, shell, undefined, undefined, undefined, undefined, signal);
  if (result == null) return;
  if (result.suggestions.length == 0 && !result.argumentDescription) return;

  const activeToken = lastCommand?.complete ? undefined : lastCommand;
  return { ...result, activeToken };
};

export const getSpecNames = (): string[] => {
  return Object.keys(specRegistry).filter((spec) => !spec.startsWith("@") && spec != "-");
};

const getPersistentOptions = (persistentOptions: Fig.Option[], options?: Fig.Option[]) => {
  const persistentOptionNames = new Set(persistentOptions.map((o) => (typeof o.name === "string" ? [o.name] : o.name)).flat());
  return persistentOptions.concat(
    (options ?? []).filter(
      (o) => (typeof o.name == "string" ? !persistentOptionNames.has(o.name) : o.name.some((n) => !persistentOptionNames.has(n))) && o.isPersistent === true,
    ),
  );
};

const getSubcommand = (spec?: Fig.Spec): Fig.Subcommand | undefined => {
  if (spec == null) return;
  if (typeof spec === "function") {
    const potentialSubcommand = spec();
    if (Object.prototype.hasOwnProperty.call(potentialSubcommand, "name")) {
      return potentialSubcommand as Fig.Subcommand;
    }
    return;
  }
  return spec;
};

const genSubcommand = async (command: string, parentCommand: Fig.Subcommand, signal?: AbortSignal): Promise<Fig.Subcommand | undefined> => {
  if (!parentCommand.subcommands || parentCommand.subcommands.length === 0) return;

  const subcommandIdx = parentCommand.subcommands.findIndex((s) => (Array.isArray(s.name) ? s.name.includes(command) : s.name === command));

  if (subcommandIdx === -1) return;
  const subcommand = parentCommand.subcommands[subcommandIdx];

  signal?.throwIfAborted();
  switch (typeof subcommand.loadSpec) {
    case "function": {
      // dynamic loadSpec（別 spec ファイル参照）は curated registry に無いため、
      // 既存の宣言だけで補完を続ける（深い spec は出さない劣化）。
      return { ...subcommand, loadSpec: undefined };
    }
    case "string": {
      return { ...subcommand, loadSpec: undefined };
    }
    case "object": {
      (parentCommand.subcommands as Fig.Subcommand[])[subcommandIdx] = {
        ...subcommand,
        ...(subcommand.loadSpec ?? {}),
        loadSpec: undefined,
      };
      return (parentCommand.subcommands as Fig.Subcommand[])[subcommandIdx];
    }
    case "undefined": {
      return subcommand;
    }
  }
};

const getOption = (activeToken: CommandToken, options: Fig.Option[]): Fig.Option | undefined => {
  return options.find((o) => (typeof o.name === "string" ? o.name === activeToken.token : o.name.includes(activeToken.token)));
};

const getPersistentTokens = (tokens: CommandToken[]): CommandToken[] => {
  return tokens.filter((t) => t.isPersistent === true);
};

const getArgs = (args: Fig.SingleOrArray<Fig.Arg> | undefined): Fig.Arg[] => {
  return args instanceof Array ? args : args != null ? [args] : [];
};

const runOption = async (
  tokens: CommandToken[],
  allTokens: CommandToken[],
  option: Fig.Option,
  subcommand: Fig.Subcommand,
  cwd: string,
  shell: Shell,
  persistentOptions: Fig.Option[],
  acceptedTokens: CommandToken[],
  signal?: AbortSignal,
): Promise<SuggestionBlob | undefined> => {
  if (tokens.length === 0) {
    throw new Error("invalid state reached, option expected but no tokens found");
  }
  const activeToken = tokens[0];
  const isPersistent = persistentOptions.some((o) => (typeof o.name === "string" ? o.name === activeToken.token : o.name.includes(activeToken.token)));
  if ((option.args instanceof Array && option.args.length > 0) || option.args != null) {
    const args = option.args instanceof Array ? option.args : [option.args];
    return runArg(tokens.slice(1), allTokens, args, subcommand, cwd, shell, persistentOptions, acceptedTokens.concat(activeToken), true, false, signal);
  }
  return runSubcommand(
    tokens.slice(1),
    allTokens,
    subcommand,
    cwd,
    shell,
    persistentOptions,
    acceptedTokens.concat({
      ...activeToken,
      isPersistent,
    }),
    undefined,
    undefined,
    signal,
  );
};

const runArg = async (
  tokens: CommandToken[],
  allTokens: CommandToken[],
  args: Fig.Arg[],
  subcommand: Fig.Subcommand,
  cwd: string,
  shell: Shell,
  persistentOptions: Fig.Option[],
  acceptedTokens: CommandToken[],
  fromOption: boolean,
  fromVariadic: boolean,
  signal?: AbortSignal,
): Promise<SuggestionBlob | undefined> => {
  signal?.throwIfAborted();
  if (args.length === 0) {
    return runSubcommand(tokens, allTokens, subcommand, cwd, shell, persistentOptions, acceptedTokens, true, !fromOption, signal);
  } else if (tokens.length === 0) {
    return await getArgDrivenRecommendation(args, subcommand, persistentOptions, undefined, acceptedTokens, allTokens, fromVariadic, cwd, shell, signal);
  } else if (!tokens.at(0)?.complete) {
    return await getArgDrivenRecommendation(args, subcommand, persistentOptions, tokens[0], acceptedTokens, allTokens, fromVariadic, cwd, shell, signal);
  }

  const activeToken = tokens[0];
  if (args.every((a) => a.isOptional)) {
    if (activeToken.isOption) {
      const option = getOption(activeToken, persistentOptions.concat(subcommand.options ?? []));
      if (option != null) {
        return runOption(tokens, allTokens, option, subcommand, cwd, shell, persistentOptions, acceptedTokens, signal);
      }
      return;
    }

    const nextSubcommand = await genSubcommand(activeToken.token, subcommand, signal);
    if (nextSubcommand != null) {
      return runSubcommand(
        tokens.slice(1),
        allTokens,
        nextSubcommand,
        cwd,
        shell,
        persistentOptions,
        getPersistentTokens(acceptedTokens.concat(activeToken)),
        undefined,
        undefined,
        signal,
      );
    }
  }

  const activeArg = args[0];
  if (activeArg.isVariadic) {
    return runArg(tokens.slice(1), allTokens, args, subcommand, cwd, shell, persistentOptions, acceptedTokens.concat(activeToken), fromOption, true, signal);
  } else if (activeArg.isCommand) {
    if (tokens.length <= 0) {
      return;
    }
    const spec = await loadSpec(tokens, signal);
    if (spec == null) return;
    const subcommand = getSubcommand(spec);
    if (subcommand == null) return;
    return runSubcommand(tokens.slice(1), allTokens, subcommand, cwd, shell, undefined, undefined, undefined, undefined, signal);
  }
  return runArg(
    tokens.slice(1),
    allTokens,
    args.slice(1),
    subcommand,
    cwd,
    shell,
    persistentOptions,
    acceptedTokens.concat(activeToken),
    fromOption,
    false,
    signal,
  );
};

const runSubcommand = async (
  tokens: CommandToken[],
  allTokens: CommandToken[],
  subcommand: Fig.Subcommand,
  cwd: string,
  shell: Shell,
  persistentOptions: Fig.Option[] = [],
  acceptedTokens: CommandToken[] = [],
  argsDepleted = false,
  argsUsed = false,
  signal?: AbortSignal,
): Promise<SuggestionBlob | undefined> => {
  signal?.throwIfAborted();
  if (tokens.length === 0) {
    return getSubcommandDrivenRecommendation(subcommand, persistentOptions, undefined, argsDepleted, argsUsed, acceptedTokens, allTokens, cwd, shell, signal);
  } else if (!tokens.at(0)?.complete) {
    return getSubcommandDrivenRecommendation(subcommand, persistentOptions, tokens[0], argsDepleted, argsUsed, acceptedTokens, allTokens, cwd, shell, signal);
  }

  const activeToken = tokens[0];
  const activeArgsLength = subcommand.args instanceof Array ? subcommand.args.length : 1;
  const allOptions = [...persistentOptions, ...(subcommand.options ?? [])];

  if (activeToken.isOption) {
    const option = getOption(activeToken, allOptions);
    if (option != null) {
      return runOption(tokens, allTokens, option, subcommand, cwd, shell, persistentOptions, acceptedTokens, signal);
    }
    return;
  }

  const nextSubcommand = await genSubcommand(activeToken.token, subcommand, signal);
  if (nextSubcommand != null) {
    return runSubcommand(
      tokens.slice(1),
      allTokens,
      nextSubcommand,
      cwd,
      shell,
      getPersistentOptions(persistentOptions, subcommand.options),
      getPersistentTokens(acceptedTokens.concat(activeToken)),
      undefined,
      undefined,
      signal,
    );
  }

  if (activeArgsLength <= 0) {
    return;
  }

  const args = getArgs(subcommand.args);
  if (args.length != 0) {
    return runArg(tokens, allTokens, args, subcommand, cwd, shell, allOptions, acceptedTokens, false, false, signal);
  }
  return runSubcommand(tokens.slice(1), allTokens, subcommand, cwd, shell, persistentOptions, acceptedTokens.concat(activeToken), undefined, undefined, signal);
};

const runCommand = async (token: CommandToken): Promise<SuggestionBlob | undefined> => {
  const specs = getSpecNames()
    .filter((spec) => spec.startsWith(token.token))
    .sort();
  return {
    suggestions: specs.map(
      (spec) =>
        ({
          name: spec,
          type: "subcommand",
          allNames: [spec],
          icon: SuggestionIcons.Subcommand,
          priority: 40,
        }) as Suggestion,
    ),
    activeToken: token,
  };
};
