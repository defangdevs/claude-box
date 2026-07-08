# claude-box

Reproducible, multi-user coding-agent sandboxes - one click on AWS, on bare
metal, or as a VM image, from one declarative config. (Built on NixOS.)

Each agent is an **unprivileged user** running a supported agent CLI inside a
persistent `tmux` session. The only elevated power an agent gets is a tight,
explicit passwordless-`sudo` allowlist. Custom tokens (e.g. `GH_TOKEN`) are
injected via drop-in `EnvironmentFile`s that never enter the world-readable Nix
store.

Supported agents:

| Agent | Package | Autonomy flag used by `skipPermissions = true` | Notes |
| --- | --- | --- | --- |
| Claude Code | `pkgs.claude-code` | `--dangerously-skip-permissions` | Supports Claude Remote Control. |
| Codex | `pkgs.codex` | `--dangerously-bypass-approvals-and-sandbox` | Browser terminal access; Codex app-server/remote wiring is future work. |

**Name note.** `claude-box` still works as the module and service namespace for
compatibility, but the repo has outgrown that name. A better name would be
`agent-box`: short, literal, and broad enough for Claude Code, Codex, and future
terminal-native agents.

## 1-click AWS launch

Provisions one EC2 instance (NixOS 25.11) with the module + a browser terminal
(Caddy -> ttyd) already wired up. First load takes ~2-3 minutes while the AMI
provisions, `nixos-rebuild switch` applies the config, and Caddy issues a
Let's Encrypt cert against `<eip>.sslip.io`.

| Region | Launch |
| --- | --- |
| us-east-1 (N. Virginia) | [Launch stack →](https://console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/quickcreate?stackName=claude-box&templateURL=https%3A%2F%2Fdefang-claude-box.s3.amazonaws.com%2Ftemplate.yaml) |
| us-west-2 (Oregon) | [Launch stack →](https://console.aws.amazon.com/cloudformation/home?region=us-west-2#/stacks/quickcreate?stackName=claude-box&templateURL=https%3A%2F%2Fdefang-claude-box.s3.amazonaws.com%2Ftemplate.yaml) |
| eu-central-1 (Frankfurt) | [Launch stack →](https://console.aws.amazon.com/cloudformation/home?region=eu-central-1#/stacks/quickcreate?stackName=claude-box&templateURL=https%3A%2F%2Fdefang-claude-box.s3.amazonaws.com%2Ftemplate.yaml) |
| eu-west-1 (Ireland) | [Launch stack →](https://console.aws.amazon.com/cloudformation/home?region=eu-west-1#/stacks/quickcreate?stackName=claude-box&templateURL=https%3A%2F%2Fdefang-claude-box.s3.amazonaws.com%2Ftemplate.yaml) |

Choose `Agent` (`claude` or `codex`), set a `WebPassword` (16+ chars from
`[A-Za-z0-9._~-]`), pick an instance size, launch. The template creates its own
IPv6-enabled VPC/subnet so nothing on the account has to be pre-configured. The
stack Outputs show `https://agent@<v6-or-v4>.sslip.io/` - open it, enter your
`WebPassword` when prompted, complete the selected agent's one-time sign-in, done.

**Cost note (Feb-2024 AWS IPv4 pricing).** The default is **IPv6-only** to
avoid the ~$3.60/mo public-IPv4 charge that AWS bills for *every* public IPv4,
elastic or not. Works if your client has IPv6 connectivity (most consumer ISPs
in NA/EU do; corporate/coffee-shop nets often don't). If IPv6 isn't reachable
for you, set `PublicIpv4: true` at launch — allocates an EIP, adds $3.60/mo,
works everywhere.

Costs: ~$0.017/hr for `t4g.small` (Graviton/aarch64) on-demand + $0/hr for
the Elastic IP while attached (~$3.60/mo if you keep it up). Terminate the
stack to stop billing.

Template source: [`aws/template.yaml`](./aws/template.yaml).
See [`aws/README.md`](./aws/README.md) for the region -> AMI refresh workflow
and the S3-hosting setup.

## Why

Turns a hand-tuned, single-user, bare-metal agent setup into something others
can stand up identically - either as per-person accounts on a shared host or as
disposable, snapshot-able KVM guests.

## Quick start (bare metal, multiple users)

Add the flake as an input and import the module:

```nix
# flake.nix (your host)
{
  inputs.claude-box.url = "github:defangdevs/claude-box";
  # ...
}
```

```nix
# configuration.nix
{ pkgs, ... }:
{
  imports = [ inputs.claude-box.nixosModules.claude-box ];

  services.claude-box = {
    enable = true;
    agent = "claude"; # or "codex"
    users = {
      alice = { };
      bob   = { remoteControlName = "bob-box"; };
      coder = { agent = "codex"; };
      ci    = { skipPermissions = false; };   # keep approval prompts on
    };
    # The ONLY elevated powers the agents get - keep it tight.
    sudoAllowlist = [ "/run/current-system/sw/bin/systemctl reload caddy.service" ];
    extraPackages = with pkgs; [ git ripgrep jq ];
  };
}
```

Then `sudo nixos-rebuild switch`. Each user gets a `claude-box-<name>.service`.

**First login (per user):** attach to the session and complete the one-time
agent sign-in:

```bash
sudo -u alice env TMUX_TMPDIR=/run/agent-box-alice tmux -L agent-box attach -t main
```

`TMUX_TMPDIR` is required: the agent service runs with `PrivateTmp`, so its
tmux control socket lives under `/run/agent-box-<user>` rather than `/tmp`.

Credentials live in that user's home directory (`~/.claude` for Claude Code,
`~/.codex` for Codex) - per-user runtime state, never baked into the config.

**Claude Code quirks to know about first-time login in the browser terminal:**

- **The login URL may not be clickable at narrow browser widths.** The URL
  claude-code prints is ~400 chars; if your browser terminal is narrower
  than that, xterm.js wraps it across multiple rows and its link detector
  truncates the match somewhere in the middle. Fix is merged upstream in
  [xtermjs/xterm.js PR 6017](https://github.com/xtermjs/xterm.js/pull/6017)
  but not yet in a tagged xterm.js release, so it hasn't reached nixpkgs'
  ttyd. Until it lands: widen the browser window or zoom out (Cmd/Ctrl `-`)
  before running `claude auth login` so the URL fits on one row; then click
  it. Resizing after emission can make it worse (a related fix is in
  [xtermjs/xterm.js PR 5810](https://github.com/xtermjs/xterm.js/pull/5810)).
- **Pasting the auth code gives no visible feedback** — claude-code hides
  the code input like a password. Paste it, press Enter, and it should
  print `Login successful.`. If you're not sure the paste landed, that's
  by design; just Enter.

## VM image

Build from the same config:

```bash
nix build github:defangdevs/claude-box#vm   # -> qcow2 disk image
# or run a throwaway QEMU VM locally:
nixos-rebuild build-vm --flake github:defangdevs/claude-box#vm && ./result/bin/run-*-vm
```

The bundled `hosts/vm.nix` provisions a single `agent` user with console
autologin (change the initial password on first boot).

## Adding custom tokens (no rebuild)

Each agent auto-loads `/etc/claude-box/<user>.env` if it exists. Drop a token in
and restart the unit:

```bash
sudo install -m600 /dev/stdin /etc/claude-box/alice.env <<'EOF'
GH_TOKEN=ghp_xxx
EOF
sudo systemctl restart claude-box-alice
```

The file is read by systemd as root and exported into the agent's environment,
so secrets stay out of the Nix store. For Nix-managed secret paths (agenix,
sops-nix, etc.) use `environmentFiles` instead.

## Options

All under `services.claude-box`:

| Option | Default | Description |
| --- | --- | --- |
| `enable` | `false` | Turn the module on. |
| `agent` | `"claude"` | Default agent CLI: `"claude"` or `"codex"`. |
| `package` | selected agent default | Override package to run for every agent user. |
| `users.<name>.agent` | `null` | Per-user override; null uses `services.claude-box.agent`. |
| `users.<name>.skipPermissions` | `true` | Pass the selected agent's autonomy flag. |
| `users.<name>.remoteControl` | `true` | Pass Claude's `--remote-control` when `agent = "claude"`; ignored for Codex. |
| `users.<name>.remoteControlName` | `<name>@<host>` | Claude Remote Control session name (null -> `<user>@<fqdnOrHostName>`, so you can tell boxes apart in the apps). Ignored for Codex. |
| `users.<name>.workingDirectory` | `/home/<name>` | Agent startup directory. |
| `users.<name>.extraGroups` | `[]` | Extra groups for the user. |
| `users.<name>.extraArgs` | `[]` | Extra args appended to the selected agent CLI. |
| `users.<name>.environmentFiles` | `[]` | Extra `EnvironmentFile` paths for this agent. |
| `users.<name>.environment` | `{}` | Extra (non-secret) env vars for this agent's service. |
| `sudoAllowlist` | `[]` | Passwordless sudo commands granted to every agent. |
| `extraPackages` | `[]` | Packages placed on each agent's PATH. |
| `environmentFiles` | `[]` | Extra `EnvironmentFile` paths applied to every agent. |
| `tokenDir` | `/etc/claude-box` | Where per-agent `<user>.env` token files live. |
| `manageTokenDir` | `true` | Create `tokenDir` (root-owned) via tmpfiles. |

## Security model

The module treats each agent as an untrusted process running inside its own
unprivileged user account, on a machine the operator already treats as a
sandbox host (VM, throwaway EC2 box, etc.). The OS layer is what contains a
compromised agent - the agent CLI's in-tool approval prompts are *deliberately*
off by default (`skipPermissions = true`), so nothing in the agent itself gates
arbitrary command execution as the agent user.

**What the module gives you:**

- **Unprivileged agent user.** Not root. Agent autonomy is intentionally scoped
  to that user.
- **Systemd hardening on every agent service:** `PrivateTmp`,
  `PrivateDevices` (keeps pty, blocks `/dev/mem` and friends),
  `ProtectSystem=strict` (root filesystem read-only, only `/home/<name>`
  writable via `ReadWritePaths`), `ProtectKernelTunables/Modules/`
  `ControlGroups/Clock`, `RestrictSUIDSGID`, `RestrictRealtime`,
  `LockPersonality`. `NoNewPrivileges=true` is applied automatically when
  `sudoAllowlist` is empty; a non-empty allowlist keeps NNP off (sudo is
  setuid and needs the euid transition) - a deliberate trade of a bit of
  containment for scoped elevation.
- **Tight sudo:** whatever's in `sudoAllowlist` is the entire root-capable
  surface. `NOPASSWD` only - no `SETENV`, no blanket sudo, no ALL.
- **Root-scoped secrets dir:** `/etc/claude-box` is `0700 root:root`.
  Systemd reads the per-agent `<user>.env` files as root before dropping
  into the agent's UID, so the agent process itself never traverses the
  directory. `Z … 0600 root root` tmpfiles rule enforces the mode of any
  file inside on every rebuild.

**Deliberate defaults that stay ON:**

- `skipPermissions = true` - a headless agent runner with per-tool
  approval prompts and no human to answer them is useless. Flip to
  `false` per-user if you actually have a human at the terminal.
- `remoteControl = true` - for Claude Code, this is the "drive it from your
  phone" feature. Flip to `false` per-user if you don't want the session
  reachable from the Claude apps. Codex ignores this option.

**Tradeoffs the module can't fully paper over:**

- **Persistent `/home/<name>` across sessions.** SSH keys, git creds,
  dotfiles, session state - anything the agent writes accumulates.
  Treat each agent home as untrusted; back up or wipe with intent.
- **Secrets as env vars.** Anything in `<user>.env` becomes an env
  var in the agent's process and its children. Env vars can leak via
  `/proc/<pid>/environ`, coredumps, or child-process inheritance.
  Systemd's `LoadCredential=` (files under `$CREDENTIALS_DIRECTORY`)
  is a possible future improvement if the tools running under the
  agent actually read from there.
- **Agent autonomy flags** grant full autonomy inside the agent CLI. Prefer the
  VM target for anything you'd not lose sleep over an attacker doing as the
  agent user - a KVM guest is a
  much stronger blast-radius boundary than a container.

## Notes

- `claude-code` is unfree; the module allows just the supported agent packages
  (overridable).
- The qcow2 image uses the native nixpkgs image API (`system.build.images`,
  upstreamed in NixOS 25.05) - no extra flake inputs.
- Future work: switching the agent on a running instance should likely be a
  small NixOS config change (`services.claude-box.agent = ...`) plus
  `nixos-rebuild switch` and a service restart, but the UX still needs a tidy
  operator command because credentials and live tmux state are agent-specific.

## Docs

Maintainer and continuity notes live in the
[project wiki](https://github.com/defangdevs/claude-box/wiki).

## License

MIT - see [LICENSE](./LICENSE). Note this license covers the flake/module only;
agent CLIs ship under their own terms.
