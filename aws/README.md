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

### One-time maintainer setup

1. **Create the S3 bucket** (any account with the CI role):
   ```bash
   aws s3api create-bucket --bucket defang-claude-box --region us-east-1
   ```

2. **Relax block-public-access so the CFN quickcreate console can fetch the
   template** — `s3:GetObject` needs to be publicly allowed for the one
   `template.yaml` key:
   ```bash
   aws s3api put-public-access-block \
     --bucket defang-claude-box \
     --public-access-block-configuration \
       "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=false,RestrictPublicBuckets=false"

   aws s3api put-bucket-policy --bucket defang-claude-box --policy '{
     "Version": "2012-10-17",
     "Statement": [{
       "Sid": "PublicReadTemplate",
       "Effect": "Allow",
       "Principal": "*",
       "Action": "s3:GetObject",
       "Resource": "arn:aws:s3:::defang-claude-box/template.yaml"
     }]
   }'
   ```

3. **Create the `defang-claude-box` GitHub environment** in the repo settings
   — its name must start with `defang-` to satisfy the trust policy on
   `arn:aws:iam::180162796851:role/defang-cd-CIRole`. No environment secrets
   needed; the workflow assumes the role via OIDC.

4. **Verify** by triggering the workflow manually (`workflow_dispatch`) and
   confirming the object landed:
   ```bash
   curl -I https://defang-claude-box.s3.amazonaws.com/template.yaml
   ```
