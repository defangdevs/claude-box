# AWS deployment (`aws/`)

CloudFormation template that provisions a single-agent claude-box host on
EC2 with a browser terminal (Caddy + ttyd).

- `template.yaml` — the template. Source of truth; anything else is derived.

## What the template does

- Allocates an Elastic IP and derives an `<eip>.sslip.io` hostname (no DNS
  edits required — `sslip.io` returns whatever IP you encode in the label).
- Launches one EC2 instance from the latest NixOS 25.11 AMI for the region.
- Uses EC2 user-data as a NixOS configuration: imports the pinned
  `claude-box` module + adds Caddy (TLS-ALPN-01 only) + a `ttyd` systemd
  service that binds to `127.0.0.1:7681` and attaches to `agent`'s tmux
  session (`tmux -L claude-box -t main`).
- Requires IMDSv2 (`HttpTokens: required`); the plaintext `WebPassword` in
  user-data is only readable from the instance itself.
- Disables `amazon-init` after the first successful apply so local edits to
  `/etc/nixos/configuration.nix` survive reboots.

## Refreshing the AMI map

NixOS publishes AMI ids at <https://nixos.github.io/amis/images.json> (no
auth). AMIs are garbage-collected ~90d after publication, so the template's
`Mappings.RegionMap` block needs to be refreshed periodically.

`scripts/refresh_amis.py` regenerates the block between the `BEGIN AMI MAP`
/ `END AMI MAP` markers in `template.yaml`. It targets the NixOS 25.11
channel, x86_64, and only the 4 regions we support today (us-east-1,
us-west-2, eu-central-1, eu-west-1).

CI runs it weekly via `.github/workflows/refresh-amis.yml` and pushes a
commit if anything changed.

## Publishing to S3

CloudFormation's `templateURL` accepts only S3 URLs, so the template lives
at `s3://defang-claude-box/template.yaml`. `.github/workflows/publish-template.yml`
handles the upload on every push to `master` via GitHub OIDC (no static AWS
keys).

### Prerequisites (forking this repo)

The workflow is self-bootstrapping — it upserts the bucket, its
public-access configuration, and the `s3:GetObject` policy on
`template.yaml` every run. It reads all deploy config from **repo-level
Actions variables** (Settings > Secrets and variables > Actions >
Variables). None are secrets; they're just fork-specific.

| Variable | Required | Purpose |
| --- | --- | --- |
| `AWS_ROLE_ARN` | yes | IAM role assumed via OIDC. Trust policy must allow the GitHub environment named in `AWS_ENVIRONMENT`. |
| `AWS_BUCKET` | yes | S3 bucket name to publish `template.yaml` into. Global namespace. |
| `AWS_ENVIRONMENT` | no | GitHub Actions environment name. Defaults to `defang-claude-box` (must be repo-scoped since env-scoped is a chicken-and-egg). Set to any name your role's trust policy accepts. |
| `AWS_REGION` | no | Region for the bucket + AWS API calls. Defaults to `us-east-1`. |

Role permissions needed: `s3:CreateBucket`, `s3:PutPublicAccessBlock`,
`s3:PutBucketPolicy`, `s3:PutObject`, and `cloudformation:ValidateTemplate`.
The E2E deploy-test workflow additionally needs `cloudformation:CreateStack`,
`cloudformation:DeleteStack`, `cloudformation:DescribeStacks`, and the EC2
create/delete permissions used by the template.

The GitHub environment listed in `AWS_ENVIRONMENT` must exist — create it
via `gh api --method PUT repos/<owner>/<repo>/environments/<name>` or the
repo settings UI. No secrets attached; it's just the deployment gate.

Verify with a `workflow_dispatch` run of `Publish CFN template to S3`, then:

```bash
curl -I "https://${AWS_BUCKET}.s3.amazonaws.com/template.yaml"
```

## End-to-end deploy test

`.github/workflows/deploy-test.yml` (manual trigger) creates a real
CloudFormation stack, waits for the browser URL to return the expected
`401` Basic-Auth challenge, then deletes the stack. Use it as smoke test
after changing the template. Toggle `destroy: false` on the dispatch
inputs to keep the stack up for hands-on debugging.
