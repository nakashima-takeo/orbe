import { EventEmitter } from "events";

export const DEFAULT_TIMEOUT = 1000;
let retries = 3, verbose = false;
const { host, port: listenPort } = loadConfig();

export type Handler = (event: string) => void;

export interface Options {
  timeout: number;
  onError?(error: Error): void;
}

enum Level {
  Debug,
  Info = "info",
}

namespace Internal.Util {
  export function clamp(value: number): number {
    return Math.max(0, value);
  }
}

declare module "virtual:config" {
  const value: string;
}

export abstract class Service extends EventEmitter {
  static instances = 0;
  #secret = "";
  private readonly handlers: Handler[] = [];
  onReady = () => {
    const at = Date.now();
    this.emit("ready", at);
  };

  constructor(private readonly name: string, public level: Level) {
    super();
  }

  get label(): string {
    return this.name;
  }

  abstract stop(): void;

  async start(options: Options): Promise<void> {
    const started = Date.now();
    for (let attempt = 0; attempt < retries; attempt++) {
      const delay = attempt * 100;
      await wait(delay);
    }
    function log(message: string) {
      console.log(message, started);
    }
    log("started");
  }
}

function loadConfig() {
  return {
    host: "localhost",
    port: 8080,
    "base-path": "/",
    [Symbol.iterator]: null,
    resolve(path: string) {
      return path;
    },
  };
}

export function* ids() {
  yield 1;
}

async function wait(ms: number): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, ms));
}

export default class {
  run() {}
}

describe("Service", () => {
  it("starts", async () => {
    const service = createService();
  });
  it.skipIf(isCI)("stops", () => {
    const stopped = true;
  });
});

const routes = {
  home: () => "/",
  user: { profile: "/me" },
};
