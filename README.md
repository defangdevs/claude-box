# claude-box

Reproducible, multi-user [Claude Code](https://claude.com/claude-code) agent
sandboxes for NixOS — on bare metal or as a VM image, from one declarative
config.

Each agent is an **unprivileged user** running Claude Code inside a persistent
`tmux` session with `--dangerously-skip-permissions --remote-control`. The only
elevated power an agent gets is a tight, explicit passwordless-`sudo`
allowlist. Custom tokens (e.g. `GH_TOKEN`) are injected via drop-in
`EnvironmentFile`s that never enter the world-readable Nix store.

## Why

Turns a hand-tuned, single-user, bare-metal Claude setup into something others
can stand up identically — either as per-person accounts on a shared host or as
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
    users = {
      alice = { };
      bob   = { remoteControlName = "bob-box"; };
      ci    = { skipPermissions = false; };   # keep approval prompts on
    };
    # The ONLY elevated powers the agents get — keep it tight.
    sudoAllowlist = [ "/run/current-system/sw/bin/systemctl reload caddy.service" ];
    extraPackages = with pkgs; [ git ripgrep jq ];
  };
}
```

Then `sudo nixos-rebuild switch`. Each user gets a `claude-box-<name>.service`.

**First login (per user):** attach to the session and complete the one-time
Claude sign-in:

```bash
sudo -u alice tmux -L claude-box attach -t main
```

Credentials live in that user's `~/.claude` — per-user runtime state, never
baked into the config.

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
| `package` | `pkgs.claude-code` | Claude Code package to run. |
| `users.<name>.skipPermissions` | `true` | Pass `--dangerously-skip-permissions`. |
| `users.<name>.remoteControl` | `true` | Pass `--remote-control`. |
| `users.<name>.remoteControlName` | `<name>` | Remote Control session name. |
| `users.<name>.workingDirectory` | `/home/<name>` | Agent startup directory. |
| `users.<name>.extraGroups` | `[]` | Extra groups for the user. |
| `users.<name>.extraArgs` | `[]` | Extra args appended to `claude`. |
| `users.<name>.environmentFiles` | `[]` | Extra `EnvironmentFile` paths for this agent. |
| `users.<name>.environment` | `{}` | Extra (non-secret) env vars for this agent's service. |
| `sudoAllowlist` | `[]` | Passwordless sudo commands granted to every agent. |
| `extraPackages` | `[]` | Packages placed on each agent's PATH. |
| `environmentFiles` | `[]` | Extra `EnvironmentFile` paths applied to every agent. |
| `tokenDir` | `/etc/claude-box` | Where per-agent `<user>.env` token files live. |
| `manageTokenDir` | `true` | Create `tokenDir` (root-owned) via tmpfiles. |

## Security model

- **Unprivileged by default.** Agents run as normal users, not root — this is
  the OS-level sandbox boundary, and it's separate from Claude's own approval
  prompts. (`skipPermissions` defaults to `true`, i.e. *no* in-tool prompts;
  that's autonomy inside Claude Code, not OS privilege — see the heads-up
  below.) Running non-root also matters because Claude Code refuses
  `--dangerously-skip-permissions` as root.
- **Scoped elevation.** `sudoAllowlist` is the entire set of root-capable
  actions; there is no blanket sudo.
- **Isolation.** For a skip-permissions agent, prefer the VM target — a KVM
  guest is a far stronger blast-radius boundary than a container.
- **Heads-up.** `--dangerously-skip-permissions` grants full autonomy with no
  approval prompts. Claude Code's own guidance recommends it only for sandboxes;
  scope `sudoAllowlist` accordingly and treat each agent host as such.

## Notes

- `claude-code` is unfree; the module allows just that package (overridable).
- The qcow2 image uses the native nixpkgs image API (`system.build.images`,
  upstreamed in NixOS 25.05) — no extra flake inputs.

## License

MIT — see [LICENSE](./LICENSE). Note this license covers the flake/module only;
Claude Code itself ships under Anthropic's own terms.
