# AWS deployment (`aws/`)

CloudFormation template that provisions a single-agent agent-box host on
EC2 with a browser terminal (Caddy + ttyd). The deployment form lets the user
choose Claude Code or Codex.

- `template.yaml` - the EC2 template. Source of truth; anything else is derived.
- `lightsail-template.yaml` - an alternative that runs the same agent-box on
  **AWS Lightsail** for one flat monthly bundle price. See
  ["Lightsail variant"](#lightsail-variant-lightsail-templateyaml) below.

## What the template does

- Provisions its own VPC (10.42.0.0/16) with an Amazon-provided IPv6 CIDR,
  a single public subnet with a /64 IPv6 range, IGW + routes for v4 and
  v6. First-boot dependencies are fetched from dual-stack hosts, so the
  IPv6-only default does not require NAT64/DNS64.
- Launches one EC2 instance from the latest NixOS 25.11 AMI for the region.
- Uses EC2 user-data as a NixOS configuration: imports the pinned
  `agent-box` module, sets `services.agent-box.agent` from the `Agent`
  parameter, and enables the module's web terminal (Caddy, TLS-ALPN-01 only,
  plus a per-user `ttyd` on `127.0.0.1:7681` that attaches to `agent`'s tmux
  session; `TMUX_TMPDIR=/run/agent-box-agent tmux -L agent-box -t main` - the
  socket lives under `/run` because the agent runs with `PrivateTmp`).
- **Basic-auth-to-cookie web auth**. The terminal lives at `/<UserName>/`
  (default `/agent/`); Caddy prompts for the `UserName` (the linux user name
  selects the terminal) and the `WebPassword`, sets an
  `HttpOnly; Secure; SameSite=Strict` cookie, then lets browser WebSocket
  upgrades authenticate with that cookie. ttyd still binds only to localhost.
  The site root serves an unauthenticated index page listing the configured
  terminals (just the one `UserName` on this template).
- The stack output URL is `https://<host>.sslip.io/<UserName>/`; sign in as
  the `UserName` with the `WebPassword`. The URL deliberately carries no
  `user@` userinfo: Chrome answers the auth challenge with URL userinfo plus
  an empty password, and credentials typed into the prompt cannot override
  the URL-embedded identity (issue 56).
- `<UserName>@<stack name>` becomes the Claude Remote Control session name
  (default user: `agent`). Rename the stack before launch if you want a
  friendlier label in the Claude apps; post-deploy, this can still be changed
  in the NixOS config.
- The hostname `<addr>.sslip.io` is derived at CFN time via `Fn::Split ':'
  + Fn::Join '-'` on the NetworkInterface's PrimaryIpv6Address (IPv6 mode)
  or the EIP address (IPv4 mode). Consecutive `::` becomes an empty split
  element that re-joins as `--` - matches sslip.io's encoding exactly.
- Requires IMDSv2 (`HttpTokens: required`).
- Disables `amazon-init` after the first successful apply so local edits to
  `/etc/nixos/configuration.nix` survive reboots.
- Attaches an IAM instance profile with `AmazonSSMManagedInstanceCore` so the
  deployer has a root path onto the box via SSM Session Manager. See
  ["Root access via SSM Session Manager"](#root-access-via-ssm-session-manager)
  below. Opt out with `EnableSsm=false` to skip the IAM resources and the
  launch console's CAPABILITY_IAM acknowledgment.
- Sizes the root volume via `RootVolumeSize` (default 30 GiB gp3) and keeps
  it from filling up. See ["Disk headroom"](#disk-headroom) below.

### Disk headroom

The NixOS AMI's own snapshot is only a few GiB, and the nix store grows with
every `nixos-rebuild` — including agent-triggered self-updates — so an
unsized root volume eventually wedges the whole box: a full root means no
journal, no rebuilds, and usually a stuck agent, on a box where nobody is
around to run garbage collection by hand.

Three layers keep that from happening:

- **`RootVolumeSize` parameter** (default 30 GiB, gp3, ~$0.08/GiB-month).
  The `BlockDeviceMappings` device name must match the AMI's
  `RootDeviceName` (`/dev/xvda` on official NixOS AMIs); a mismatch would
  silently attach a second volume instead of sizing the root.
- **Automatic nix GC**: `nix.gc.automatic` prunes generations older than 7
  days on a timer, and `nix.settings.min-free`/`max-free` trigger GC
  mid-build whenever free space dips below 1 GiB (freeing up to 5 GiB) —
  the case that matters, since rebuilds are what eat the disk. The journal
  is capped at 200M (`SystemMaxUse`), as it otherwise claims 10% of the fs.
- **Grow-on-boot**: NixOS's amazon image expands the partition and
  filesystem to fill the volume on every boot, not just the first. So a
  running box that still fills up needs no in-instance tooling: enlarge the
  volume in the EC2 console (Volumes -> Modify), then reboot the instance.
  EBS cannot shrink volumes, only grow them.

### Root access via SSM Session Manager

The template ships no SSH `KeyName`, so on default settings SSM is the only
privileged path onto the box. This matters most when first boot fails:
`amazon-init` writes to the systemd journal only, and `ec2:GetConsoleOutput`
does not capture it — without SSM there is nothing to look at.

The `amazon-ssm-agent` NixOS service is enabled unconditionally by
`virtualisation/amazon-image.nix` on the AMIs we use, so the only piece the
template adds is an IAM instance profile carrying the
`AmazonSSMManagedInstanceCore` managed policy (attached when `EnableSsm=true`,
the default). Once the instance registers with SSM (usually within a minute
of `nixos-rebuild switch` completing), open a root shell either from the AWS
console (Systems Manager -> Session Manager -> Start session -> pick the
instance -> Start session) or from the CLI:

```bash
aws ssm start-session --target <InstanceId> --region <region>
```

`<InstanceId>` is in the stack Outputs. The session lands as the `ssm-user`
account with passwordless sudo; `sudo -i` gets you a root shell for
`journalctl -u amazon-init`, `nixos-rebuild switch`, etc. No SSH key, no
inbound port opened - Session Manager tunnels via the ssm-agent's outbound
connection to the SSM service.

To skip the IAM resources entirely - and avoid the launch console's
CAPABILITY_IAM acknowledgment checkbox - set `EnableSsm=false` at launch.
The box then has no privileged access path; only choose this if you are
comfortable tearing the stack down and redeploying to recover from a broken
first boot.

### Updating a deployed box (user- or agent-triggered)

The launch-time `AgentBoxRev`/`AgentBoxSha256` parameters pin the module for
the FIRST boot only. The generated `/etc/nixos/configuration.nix` prefers
`/etc/nixos/agent-box-pin.nix` when that file exists, and
`agent-box-update.service` — a root oneshot enabled via the module's
`selfUpdate` option — owns that file: it resolves upstream master's HEAD,
verifies it is strictly ahead of the running revision (history rewrites and
downgrade replays are refused), hash-pins the fetched module, rewrites the pin
file atomically, and runs `nixos-rebuild switch`. On rebuild failure the pins
roll back and the running system is unchanged.

The same run also advances `/etc/nixos/agent-box-agent-pin.nix` — a second
pin, holding the latest nixos-unstable channel-release tarball — from which
only the agent CLI packages (`claude-code`, `codex`) are resolved. The box
itself stays on its release channel; the fast-moving agent CLIs track
nixos-unstable, closing most of the version gap to upstream releases without
giving up reproducibility (the pin is URL + hash, and Hydra has the binaries).

Two triggers, both privilege-checked the same way: the "Update box" button on
each user's settings page, and the agent running
`sudo systemctl start agent-box-update.service` in its terminal — the
sudoers entries match those literal commands, so no arguments, environment
or paths cross the privilege boundary; the caller can only say "go". Save
any working context first: the rebuild restarts changed agent services,
killing their sessions mid-update.

The updater trusts the pinned GitHub repo as published (TLS + hash-pinning of
what it fetched). Signature verification against an offline key is tracked in
[issue 46](https://github.com/defangdevs/agent-box/issues/46).

### WebPassword storage

`WebPassword` is required (16-64 chars). Even Claude Code stacks that intend to
drive the box from the Claude apps via Remote Control need it: the first
`claude login` still runs in the browser terminal, and Remote Control only
takes over after that credential lands on disk. AWS masks the field once
entered and it isn't emitted in stack outputs, so callers must save it out of
band — the launch page copy leads with this.

`WebPassword` is marked `NoEcho` and is not emitted in stack Outputs. It still
exists as plaintext in the substituted EC2 user-data, and the current
implementation interpolates a reversible base64 projection into first-boot
Nix/systemd material, then decodes it in the activation script so Caddy can
derive its Basic Auth hash. Treat principals that can read instance user-data
or the instance's local system configuration as inside the web terminal trust
boundary.

Caddy does not compare the plaintext password at request time. On first boot an
activation script runs `caddy hash-password --algorithm argon2id` and stores
only the Argon2id hash at
`/var/lib/agent-box-web/password-hash` (the file the module's
`users.agent.web.passwordHashFile` points at). On every boot
`agent-web-auth-secrets.service` writes that hash and its detected algorithm
(`WEB_PASSWORD_HASH_AGENT` / `WEB_PASSWORD_ALGORITHM_AGENT`) plus a random
cookie secret (`WEB_COOKIE_SECRET_AGENT`) to
`/run/agent-box-web/env` (`0600`), and Caddy reads that environment file. The
cookie secret is generated on the instance and stored separately at
`/var/lib/agent-box-web/cookie-secret-agent` (`0700` parent directory).

## Design decisions & gotchas

### Why Basic Auth mints a cookie

The obvious "username + password prompt" model (ttyd `-c user:pass`, or
Caddy `basic_auth`) breaks the terminal in every browser: **Chrome,
Firefox, and Safari all refuse to attach cached Basic Auth credentials
to the WebSocket `Upgrade` request**. The HTML loads fine; the WS
handshake gets rejected with 401; the terminal shows "disconnected."
Confirmed via [Bugzilla 1229443](https://bugzilla.mozilla.org/show_bug.cgi?id=1229443),
[Chromium 40193544](https://issues.chromium.org/issues/40193544), and
[ttyd #1437](https://github.com/tsl0922/ttyd/issues/1437).

Fix: Caddy uses Basic Auth only for the initial page load, then sets a
host-scoped `__Host-agent_box_auth_agent` cookie. Later ttyd WebSocket requests
carry
that cookie, not an `Authorization` header, so the terminal works without
putting the secret in browser history, `Referer` headers, or CloudFormation
Outputs. The password is still a shared secret: anyone with enough AWS access to
read EC2 user-data should be treated as inside the deployment's trust boundary.

### Why `sslip.io` and not the EC2 public DNS

Every EC2 instance gets an `ec2-<ip>.compute-1.amazonaws.com` hostname
for free, but **Let's Encrypt hard-refuses to issue certs under
`*.compute.amazonaws.com`** by policy - see [LE community post #12692](https://community.letsencrypt.org/t/policy-forbids-issuing-for-name-on-amazon-ec2-domain/12692).
So we need any other name that resolves to our public IP.

`sslip.io` returns whatever IP is encoded in the label - no DNS setup,
no signup, no dep. Third-party service risk: if they disappear, existing
certs keep serving but new stacks can't ACME. Threat model: they only
provide DNS, so they can't MITM active sessions (TLS cert is ours);
worst case is DoS of new issuance or user redirection to a decoy site
that immediately fails cert validation.

### CloudFormation quick-create requires an S3 template URL

`templateURL` in the `/stacks/quickcreate` URL **must be an S3 URL** -
GitHub Pages or `raw.githubusercontent.com` are rejected with
"TemplateURL must be a supported URL." That's why the publish-template
workflow syncs to S3, and the README's Launch Stack links point at
`https://<bucket>.s3.amazonaws.com/template.yaml`.

### Why the template creates its own VPC

Older AWS accounts' default VPCs never had IPv6 CIDR blocks
retroactively added. Making the template self-provisioning (VPC + IPv6
CIDR + IGW + IPv6 subnet) means:
- No "please select a subnet from the dropdown" step at launch (truer
  1-click).
- Works in any account regardless of default-VPC state.
- IPv6 default is reachable outbound to the dual-stack hosts required for
  first boot, without paying for NAT Gateway infrastructure.

All the extra resources are free (VPC, subnet, route table, IGW, EIP-
while-attached historical wisdom no longer applies - see the IPv4 note
below).

### IPv6-first by cost, IPv4 opt-in by connectivity

Since **Feb 2024, AWS charges $0.005/hr for every public IPv4 address**
regardless of attach state (EIP or ephemeral, running or stopped
instance) - ~$3.60/mo per address. IPv6 is free. So the template
defaults to `PublicIpv4: false` (IPv6-only, ~$0/mo for the address).
Users whose clients don't have IPv6 (corporate nets, coffee-shop WiFi)
set `PublicIpv4: true` at launch to allocate an EIP.

### Spot by default (persistent + stop)

`UseSpot` defaults to `true` because cost is the whole point. The spot
options can't sit on `AWS::EC2::Instance` (it has no `InstanceMarketOptions`),
so they ride on a conditional `AWS::EC2::LaunchTemplate` that the instance
references only when `UseSpot=true`. We use a **persistent** request with
`InstanceInterruptionBehavior: stop`: on interruption AWS stops (not
terminates) the instance and restarts the *same* instance in the *same AZ*
when capacity returns, so the root EBS, the ENI's IPv6, and the on-disk TLS
cert all survive. What does not survive is the live tmux session (RAM is
lost on any stop). Risk: if that one AZ+type pool stays capacity-starved,
the box stays stopped until it frees up - pick a deep pool. No `MaxPrice` is
set, so the cap is the on-demand rate. The E2E deploy-test forces
`UseSpot=false` so CI doesn't depend on spot capacity.

### Race condition: EIP association vs boot

In our custom subnet, `MapPublicIpOnLaunch` is false, so the instance
has **no public IPv4 until `EIPAssoc` completes**. Without that,
amazon-init's `fetchTarball` from github.com (IPv4-only host) fails on
first boot and Caddy never comes up. Fix: `DependsOn: EIPAssoc` on the
Instance. CFN handles this correctly even when the referenced resource
has a Condition that's false (skips the wait); cfn-lint's E3005 is
over-eager here and is suppressed on that resource.

### CFN can't `GetAtt` an Instance's IPv6

Long-standing gap ([issue #916](https://github.com/aws-cloudformation/cloudformation-coverage-roadmap/issues/916)):
`AWS::EC2::Instance` exposes `PublicIp`, `PublicDnsName`, etc. but no
IPv6 attribute. Work-around used here: create an explicit
`AWS::EC2::NetworkInterface` (which does return `PrimaryIpv6Address`)
and attach it to the instance via `NetworkInterfaces:
[NetworkInterfaceId: !Ref NetworkInterface]`.

### cfn-lint gap: SG per-rule descriptions

`SecurityGroupIngress` rule descriptions have a stricter regex than
`GroupDescription` - Unicode punctuation like `-` (U+002D hyphen) is safe, but
Unicode punctuation like an em dash is
rejected by EC2's API but cfn-lint only checks the group description.
The template avoids em-dashes anywhere that becomes a rule description
to sidestep this.

## Lightsail variant (`lightsail-template.yaml`)

A separate template (not a toggle on the EC2 one) that runs the same
`services.agent-box` on **AWS Lightsail** instead of EC2. The draw is billing
shape: Lightsail is one flat monthly bundle that folds compute, the SSD, the
attached static IPv4, and a multi-TB transfer allowance into a single price,
with **no separate EBS or public-IPv4 line items**. At the small tier the two
come out within a few percent of each other:

| | EC2 `t4g.small` (this repo's default region set) | Lightsail `small_3_0` |
| --- | --- | --- |
| vCPU / RAM | 2 / 2 GiB | 2 / 2 GiB |
| Disk | 30 GiB gp3 (billed separately) | 60 GiB SSD (in bundle) |
| Public IPv4 | ~$3.60/mo (billed separately) | included |
| Transfer | 100 GB free, then $0.09/GB | multi-TB included |
| Price | ~$13.4/mo on-demand-equivalent (~$12.6 measured on Spot) | **$12.0/mo flat** |

So Lightsail slightly undercuts the EC2 on-demand-equivalent and roughly ties
Spot, while bundling 2x the disk and a large transfer allowance and removing
Spot's interruption risk. EC2 keeps the edge on flexibility (arbitrary instance
types, deep Spot discounts, IaC-native networking).

### How it works (nixos-infect)

Lightsail has **no NixOS blueprint** and CloudFormation's `AWS::Lightsail::Instance`
cannot boot a custom image — it only takes a public `BlueprintId`. So the box
launches the stock **Ubuntu 24.04** blueprint and converts itself to NixOS
in-place on first boot with [`nixos-infect`](https://github.com/elitak/nixos-infect)
(pinned by commit in the `NixosInfectRev` parameter):

- The `UserData` script pre-writes `/etc/nixos/configuration.nix` **before**
  invoking `nixos-infect`. The script's `makeConf()` early-returns when that
  file already exists, so it never clobbers our config.
- `PROVIDER=lightsail` is first-class in `nixos-infect`: it relabels the root
  filesystem to `nixos` and its generated config imports
  `virtualisation/amazon-image.nix` — **the same module the EC2 template uses**.
  Our pre-written config imports that module too, so the platform layer is the
  proven one; only the delivery (infect over Ubuntu) is new.
- That baked config is essentially the EC2 template's config minus Spot and
  NAT64, plus the Lightsail platform bits (`amazon-image.nix` import,
  `boot.loader.grub.device = "/dev/nvme0n1"`). `services.agent-box`,
  `selfUpdate`, the web-password-hash activation script, the first-boot
  WaitCondition signal, disk-GC watchdog, and the `amazon-init` disable all
  carry over unchanged.

### Differences from the EC2 template

- **No VPC/subnet/IGW/SG/EIP/IAM** resources — Lightsail manages networking;
  the per-instance firewall is the `Networking.Ports` block (443 always, 22
  when `DebugSsh=true`).
- **IPv4-native**, so no `PublicIpv4`/`Nat64` parameters and no NAT64 plumbing.
- **No Spot** (`UseSpot` is gone; `spotInterruption` is disabled in the config).
- **No `RootVolumeSize`** — the SSD is fixed by the bundle; grow by
  snapshot-and-restore onto a larger bundle.
- **A static IP is always attached** (free on Lightsail while attached, and
  stable across a stop/start), so the `sslip.io` URL keeps working. Because the
  attach happens after instance creation, `UserData` can't reference the static
  IP without a dependency cycle, so the box discovers its own settled public
  IPv4 at runtime (a `sleep` past the attach window + a stability poll) and
  bakes `<ip>.sslip.io`. The stack `Outputs` report the same address via
  `GetAtt StaticIp.IpAddress`.
- **Debug access is root SSH with the Lightsail default key** (`DebugSsh=true`
  opens 22), not SSM — Lightsail has no Session Manager, and after infection the
  console's browser-SSH (which logs in as `ubuntu`) stops working. Infect logs
  land in `/var/log/agent-box-infect.log`.

### Deploying (CLI)

The 1-click S3 publish path is not wired up for this template yet (see
below), so deploy it directly. `AgentBoxRev`/`AgentBoxSha256` are a pinned
pair, exactly as for the EC2 template:

```bash
REV=$(git rev-parse HEAD)   # or any pushed agent-box commit
SHA=$(nix store prefetch-file --json \
  "https://raw.githubusercontent.com/defangdevs/agent-box/${REV}/modules/agent-box.nix" \
  | jq -r .hash)

aws cloudformation deploy \
  --region eu-central-1 \
  --stack-name agent-box-lightsail \
  --template-file aws/lightsail-template.yaml \
  --parameter-overrides \
      WebPassword='<16-64 chars>' \
      AgentBoxRev="$REV" \
      AgentBoxSha256="$SHA"
```

The stack blocks on the first-boot `WaitCondition` (timeout 45 min — a small
bundle's initial closure build is slow) and then emits `WebURL`,
`PublicAddress`, `RemoteControlSession`, and an `SshCommand` hint.

### Validation status

`cfn-lint` passes and the generated `configuration.nix` parses as valid Nix
(both checked in PR CI via `aws-ci.yml`). The end-to-end `nixos-infect`
bootstrap has **not** yet been exercised by an automated live deploy — treat a
first real launch as the acceptance test. Follow-ups before this is
first-class:

- A Lightsail leg in `deploy-test.yml` (create stack, assert `WebURL` reachable
  over IPv4, tear down). GitHub runners are IPv4-only and Lightsail is
  IPv4-native, so unlike the EC2 IPv6-only leg this can smoke-test the live URL.
- S3 publish + a Launch button. `publish-template.yml` currently publishes only
  `template.yaml` and scopes the bucket policy to that one object; publishing a
  second template means covering both objects in one policy (the two must not
  fight over `PutBucketPolicy`). Deferred to keep this PR's diff focused.

## Refreshing the AMI map

NixOS publishes AMI ids at <https://nixos.github.io/amis/images.json> (no
auth). AMIs are garbage-collected ~90d after publication, so the template's
`Mappings.RegionMap` block needs to be refreshed periodically.

`scripts/refresh_amis.py` regenerates the block between the `BEGIN AMI MAP`
/ `END AMI MAP` markers in `template.yaml`. It targets the NixOS 25.11
channel, `aarch64-linux` (Graviton), and only the 4 regions we support
today (us-east-1, us-west-2, eu-central-1, eu-west-1).

CI runs it weekly via `.github/workflows/refresh-amis.yml` and pushes a
commit if anything changed.

## Publishing to S3

CloudFormation's `templateURL` accepts only S3 URLs, so the template lives
at `s3://defang-agent-box/template.yaml`. `.github/workflows/publish-template.yml`
handles the upload on every push to `master` via GitHub OIDC (no static AWS
keys).

### Prerequisites (forking this repo)

The workflow is self-bootstrapping - it upserts the bucket, its
public-access configuration, and an `s3:GetObject` policy scoped to
`template.yaml` (the only object in the bucket) every run. The module itself
is fetched by the box direct from `raw.githubusercontent.com` at first boot;
that host is dual-stack, so an IPv6-only box needs no NAT64. It reads all
deploy config from **repo-level Actions variables** (Settings > Secrets and
variables > Actions > Variables). None are secrets; they're just fork-specific.

| Variable | Required | Purpose |
| --- | --- | --- |
| `AWS_ROLE_ARN` | yes | IAM role assumed via OIDC. Trust policy must allow the GitHub environment named in `AGENT_BOX_ENVIRONMENT`. |
| `AGENT_BOX_BUCKET` | yes | S3 bucket name to publish `template.yaml` into. Global namespace. |
| `AGENT_BOX_ENVIRONMENT` | no | GitHub Actions environment name. Defaults to `defang-agent-box` (must be repo-scoped since env-scoped is a chicken-and-egg). Set to any name your role's trust policy accepts. |
| `AWS_REGION` | no | Region for the bucket + AWS API calls. Defaults to `us-east-1`. |

Role permissions needed: `s3:CreateBucket`, `s3:PutPublicAccessBlock`,
`s3:PutBucketPolicy`, `s3:PutObject`, and `cloudformation:ValidateTemplate`.
The E2E deploy-test workflow uses the same role but doesn't touch S3; it
needs `cloudformation:CreateStack`, `cloudformation:DeleteStack`,
`cloudformation:DescribeStacks`, `ec2:GetConsoleOutput` (to assert amazon-init
provisioned the box - this is how the IPv6-only leg verifies success without
connecting), and the EC2 create/delete permissions used by the template -
including `ec2:CreateLaunchTemplate` / `ec2:DeleteLaunchTemplate` (Spot options)
and `ec2:DescribeSpotInstanceRequests` / `ec2:CancelSpotInstanceRequests` (so
teardown can cancel the persistent Spot request before deleting the stack).

The GitHub environment listed in `AGENT_BOX_ENVIRONMENT` must exist - create it
via `gh api --method PUT repos/<owner>/<repo>/environments/<name>` or the
repo settings UI. No secrets attached; it's just the deployment gate.

Verify with a `workflow_dispatch` run of `Publish CFN template to S3`, then:

```bash
curl -I "https://${AGENT_BOX_BUCKET}.s3.amazonaws.com/template.yaml"
```

## Pull request validation

`.github/workflows/aws-ci.yml` runs on pull requests that touch the AWS
template, launch page, browser-terminal smoke helper, or related workflows. It
does not create AWS resources; it runs `cfn-lint aws/template.yaml` and compiles
`scripts/ws_smoke.py` so template/auth-helper changes get fast PR feedback.

## End-to-end deploy test

`.github/workflows/deploy-test.yml` (on push to the template or WebSocket smoke
helper + manual trigger) creates real CloudFormation stacks and deletes them at
the end. It runs two legs in parallel:

- **ipv4-full** - forces `PublicIpv4=true` (+ Spot); GitHub runners are
  IPv4-only, so this is the only leg that can actually reach the box. It runs
  the full connectivity smoke tests (`/agent/` serves ttyd over HTTPS after
  Basic auth, unauthenticated requests get 401, the site root serves the
  session manager behind the same auth, the WebSocket upgrade returns 101
  with the auth cookie).
- **ipv6-outputs** - exercises the DEFAULT IPv6-only path. The runner can't
  connect over IPv6, so it asserts the stack reaches `CREATE_COMPLETE` and its
  outputs are populated (catches blank `PrimaryIpv6Address` bugs).

Both legs then assert, from the **serial console** (`ec2:GetConsoleOutput`),
that `amazon-init` finished - i.e. the box actually provisioned from user-data.
`CREATE_COMPLETE` fires before amazon-init runs, so this is the only signal
that the IPv6-only module fetch + `nixos-rebuild` succeeded. Toggle
`destroy: false` on the dispatch inputs to keep a stack up for debugging.
