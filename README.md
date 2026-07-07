# claude-box

Reproducible, multi-user [Claude Code](https://claude.com/claude-code) agent
sandboxes — one click on AWS, on bare metal, or as a VM image, from one
declarative config. (Built on NixOS.)

Each agent is an **unprivileged user** running Claude Code inside a persistent
`tmux` session with `--dangerously-skip-permissions --remote-control`. The only
elevated power an agent gets is a tight, explicit passwordless-`sudo`
allowlist. Custom tokens (e.g. `GH_TOKEN`) are injected via drop-in
`EnvironmentFile`s that never enter the world-readable Nix store.

## 1-click AWS launch

Provisions one EC2 instance (NixOS 25.11) with the module + a browser terminal
(Caddy → ttyd) already wired up. First load takes ~2–3 minutes while the AMI
provisions, `nixos-rebuild switch` applies the config, and Caddy issues a
Let's Encrypt cert against `<eip>.sslip.io`.

| Region | Launch |
| --- | --- |
| us-east-1 (N. Virginia) | [Launch stack →](https://console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/quickcreate?stackName=claude-box&templateURL=https%3A%2F%2Fdefang-claude-box.s3.amazonaws.com%2Ftemplate.yaml) |
| us-west-2 (Oregon) | [Launch stack →](https://console.aws.amazon.com/cloudformation/home?region=us-west-2#/stacks/quickcreate?stackName=claude-box&templateURL=https%3A%2F%2Fdefang-claude-box.s3.amazonaws.com%2Ftemplate.yaml) |
| eu-central-1 (Frankfurt) | [Launch stack →](https://console.aws.amazon.com/cloudformation/home?region=eu-central-1#/stacks/quickcreate?stackName=claude-box&templateURL=https%3A%2F%2Fdefang-claude-box.s3.amazonaws.com%2Ftemplate.yaml) |
| eu-west-1 (Ireland) | [Launch stack →](https://console.aws.amazon.com/cloudformation/home?region=eu-west-1#/stacks/quickcreate?stackName=claude-box&templateURL=https%3A%2F%2Fdefang-claude-box.s3.amazonaws.com%2Ftemplate.yaml) |

Set a `WebPassword` (16+ URL-safe chars — the URL includes it as a path token
since browsers don't reliably attach Basic Auth to WebSocket upgrades), pick
an instance size, launch. The template creates its own IPv6-enabled VPC/subnet
so nothing on the account has to be pre-configured. The stack Outputs show
`https://<v6-or-v4>.sslip.io/<token>/` — open, complete the one-time Claude
sign-in, done.

**Cost note (Feb-2024 AWS IPv4 pricing).** The default is **IPv6-only** to
avoid the ~$3.60/mo public-IPv4 charge that AWS bills for *every* public IPv4,
elastic or not. Works if your client has IPv6 connectivity (most consumer ISPs
in NA/EU do; corporate/coffee-shop nets often don't). If IPv6 isn't reachable
for you, set `PublicIpv4: true` at launch — allocates an EIP, adds $3.60/mo,
works everywhere.

Costs: ~$0.02/hr for `t3.small` on-demand + $0/hr for the Elastic IP while
attached (~$3.60/mo if you keep it up). Terminate the stack to stop billing.

Template source: [`aws/template.yaml`](./aws/template.yaml).
See [`aws/README.md`](./aws/README.md) for the region → AMI refresh workflow
and the S3-hosting setup.

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

**Two quirks to know about first-time login in the browser terminal:**

- **Don't resize the browser window** between running `claude auth login` and
  clicking the OAuth URL. The URL is ~500 chars and visually wraps across
  terminal rows; pre-resize xterm.js tracks the wrap as one soft-wrapped
  line and the URL stays clickable, but on resize it re-lays-out the buffer
  and the URL becomes several hard-wrapped fragments — unclickable and
  broken if copied. If you resize by accident, reload the tab and re-run
  `claude auth login`. Tracked upstream in
  [anthropics/claude-code#72628](https://github.com/anthropics/claude-code/issues/72628).
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
| `package` | `pkgs.claude-code` | Claude Code package to run. |
| `users.<name>.skipPermissions` | `true` | Pass `--dangerously-skip-permissions`. |
| `users.<name>.remoteControl` | `true` | Pass `--remote-control`. |
| `users.<name>.remoteControlName` | `<name>@<host>` | Remote Control session name (null → `<user>@<fqdnOrHostName>`, so you can tell boxes apart in the apps). |
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

## Docs

Maintainer and continuity notes live in the
[project wiki](https://github.com/defangdevs/claude-box/wiki).

## License

MIT — see [LICENSE](./LICENSE). Note this license covers the flake/module only;
Claude Code itself ships under Anthropic's own terms.
