# AWS deployment (`aws/`)

CloudFormation template that provisions a single-agent claude-box host on
EC2 with a browser terminal (Caddy + ttyd). The deployment form lets the user
choose Claude Code or Codex.

- `template.yaml` - the template. Source of truth; anything else is derived.

## What the template does

- Provisions its own VPC (10.42.0.0/16) with an Amazon-provided IPv6 CIDR,
  a single public subnet with a /64 IPv6 range, IGW + routes for v4 and
  v6. First-boot dependencies are fetched from dual-stack hosts, so the
  IPv6-only default does not require NAT64/DNS64.
- Launches one EC2 instance from the latest NixOS 25.11 AMI for the region.
- Uses EC2 user-data as a NixOS configuration: imports the pinned
  `claude-box` module, sets `services.claude-box.agent` from the `Agent`
  parameter, adds Caddy (TLS-ALPN-01 only), and adds a `ttyd` systemd service
  that binds to `127.0.0.1:7681` and attaches to `agent`'s tmux session
  (`TMUX_TMPDIR=/run/agent-box-agent tmux -L agent-box -t main` - the socket
  lives under `/run` because the agent runs with `PrivateTmp`).
- **URL path-token auth** (not HTTP Basic Auth). ttyd runs `-b /<token>/`,
  Caddy 404s anything without the prefix. See "Design decisions" below.
- The hostname `<addr>.sslip.io` is derived at CFN time via `Fn::Split ':'
  + Fn::Join '-'` on the NetworkInterface's PrimaryIpv6Address (IPv6 mode)
  or the EIP address (IPv4 mode). Consecutive `::` becomes an empty split
  element that re-joins as `--` - matches sslip.io's encoding exactly.
- Requires IMDSv2 (`HttpTokens: required`); the plaintext `WebPassword` in
  user-data is only readable from the instance itself.
- Disables `amazon-init` after the first successful apply so local edits to
  `/etc/nixos/configuration.nix` survive reboots.

## Design decisions & gotchas

### Why URL path-token instead of HTTP Basic Auth

The obvious "username + password prompt" model (ttyd `-c user:pass`, or
Caddy `basic_auth`) breaks the terminal in every browser: **Chrome,
Firefox, and Safari all refuse to attach cached Basic Auth credentials
to the WebSocket `Upgrade` request**. The HTML loads fine; the WS
handshake gets rejected with 401; the terminal shows "disconnected."
Confirmed via [Bugzilla 1229443](https://bugzilla.mozilla.org/show_bug.cgi?id=1229443),
[Chromium 40193544](https://issues.chromium.org/issues/40193544), and
[ttyd #1437](https://github.com/tsl0922/ttyd/issues/1437).

Fix: **the `WebPassword` parameter is the URL path** - `https://<host>/<token>/`.
Same shared-secret model, works uniformly in every browser because
there's no HTTP auth on the WS at all. The trade-off is that the token
travels in the URL (visible in browser history, `Referer` headers, CFN
Outputs); treat it like a pre-shared key.

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
at `s3://defang-claude-box/template.yaml`. `.github/workflows/publish-template.yml`
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
| `AWS_ROLE_ARN` | yes | IAM role assumed via OIDC. Trust policy must allow the GitHub environment named in `CLAUDE_BOX_ENVIRONMENT`. |
| `CLAUDE_BOX_BUCKET` | yes | S3 bucket name to publish `template.yaml` into. Global namespace. |
| `CLAUDE_BOX_ENVIRONMENT` | no | GitHub Actions environment name. Defaults to `defang-claude-box` (must be repo-scoped since env-scoped is a chicken-and-egg). Set to any name your role's trust policy accepts. |
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

The GitHub environment listed in `CLAUDE_BOX_ENVIRONMENT` must exist - create it
via `gh api --method PUT repos/<owner>/<repo>/environments/<name>` or the
repo settings UI. No secrets attached; it's just the deployment gate.

Verify with a `workflow_dispatch` run of `Publish CFN template to S3`, then:

```bash
curl -I "https://${CLAUDE_BOX_BUCKET}.s3.amazonaws.com/template.yaml"
```

## End-to-end deploy test

`.github/workflows/deploy-test.yml` (on push to the template + manual trigger)
creates real CloudFormation stacks and deletes them at the end. It runs two
legs in parallel:

- **ipv4-full** - forces `PublicIpv4=true` (+ Spot); GitHub runners are
  IPv4-only, so this is the only leg that can actually reach the box. It runs
  the full connectivity smoke tests (token URL serves ttyd over HTTPS, a
  wrong-token path returns 404, the WebSocket upgrade returns 101).
- **ipv6-outputs** - exercises the DEFAULT IPv6-only path. The runner can't
  connect over IPv6, so it asserts the stack reaches `CREATE_COMPLETE` and its
  outputs are populated (catches blank `PrimaryIpv6Address` bugs).

Both legs then assert, from the **serial console** (`ec2:GetConsoleOutput`),
that `amazon-init` finished - i.e. the box actually provisioned from user-data.
`CREATE_COMPLETE` fires before amazon-init runs, so this is the only signal
that the IPv6-only module fetch + `nixos-rebuild` succeeded. Toggle
`destroy: false` on the dispatch inputs to keep a stack up for debugging.
