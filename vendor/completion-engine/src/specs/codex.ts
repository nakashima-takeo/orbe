// codex（OpenAI Codex CLI）の自家最小 spec。上流 @withfig/autocomplete に無いため直置き。
// codex 0.144.4 の `codex --help` 実測から主要 subcommand/option のみ収載（純静的・
// generator/テンプレートは持たない。追加網羅はしない）。
const spec: Fig.Spec = {
  name: "codex",
  description: "Codex CLI - interactive agent by default",
  subcommands: [
    { name: "exec", description: "Run Codex non-interactively" },
    { name: "review", description: "Review changes in the current repository" },
    { name: "login", description: "Manage login" },
    { name: "logout", description: "Remove stored authentication credentials" },
    { name: "mcp", description: "Manage MCP servers" },
    { name: "resume", description: "Resume a previous interactive session" },
    { name: "fork", description: "Fork a previous session into a new one" },
    { name: "apply", description: "Apply the latest diff produced by the agent" },
    { name: "update", description: "Check for updates and install if available" },
    { name: "doctor", description: "Diagnose the local Codex installation" },
    { name: "completion", description: "Generate shell completion scripts" },
    { name: "sandbox", description: "Run commands in the Codex sandbox" },
  ],
  options: [
    {
      name: ["-m", "--model"],
      description: "Model the agent should use",
      args: { name: "model" },
    },
    {
      name: ["-c", "--config"],
      description: "Override a configuration value (key=value)",
      args: { name: "key=value" },
    },
    {
      name: ["-i", "--image"],
      description: "Image(s) to attach to the initial prompt",
      args: { name: "file" },
    },
    {
      name: ["-p", "--profile"],
      description: "Configuration profile from config.toml",
      args: { name: "profile" },
    },
    {
      name: ["-s", "--sandbox"],
      description: "Sandbox policy for executed commands",
      args: { name: "mode" },
    },
    {
      name: ["-a", "--ask-for-approval"],
      description: "When to ask the user for approval",
      args: { name: "policy" },
    },
    {
      name: ["-C", "--cd"],
      description: "Root directory for the session",
      args: { name: "dir" },
    },
    { name: "--search", description: "Enable web search for the session" },
    { name: "--oss", description: "Use a local open source model provider" },
    { name: ["-h", "--help"], description: "Print help" },
    { name: ["-V", "--version"], description: "Print version" },
  ],
};

export default spec;
