#!/usr/bin/env python3
"""Rewrite the RegionMap block in aws/template.yaml with the latest NixOS AMIs.

Data source: https://nixos.github.io/amis/images.json (zero-auth).
The block between the BEGIN AMI MAP / END AMI MAP markers is regenerated in
place; anything outside those markers is untouched.
"""

from __future__ import annotations

import json
import re
import sys
import urllib.request
from pathlib import Path

REGIONS = ["us-east-1", "us-west-2", "eu-central-1", "eu-west-1"]
CHANNEL_PATTERN = re.compile(r"^nixos/25\.11\..*x86_64-linux$")
IMAGES_URL = "https://nixos.github.io/amis/images.json"
TEMPLATE = Path(__file__).parent.parent / "aws" / "template.yaml"

BEGIN_MARKER = "  # BEGIN AMI MAP"
END_MARKER = "  # END AMI MAP"


def latest_ami(images: list[dict]) -> str | None:
    matches = [i for i in images if CHANNEL_PATTERN.match(i["Name"])]
    if not matches:
        return None
    matches.sort(key=lambda i: i["CreationDate"], reverse=True)
    return matches[0]["ImageId"]


def build_block(region_to_ami: dict[str, str]) -> str:
    lines = [
        BEGIN_MARKER + " (refreshed by scripts/refresh_amis.py — do not edit by hand)",
        "  RegionMap:",
    ]
    for region in REGIONS:
        lines.append(f"    {region}:")
        lines.append(f"      AMI: {region_to_ami[region]}")
    lines.append(END_MARKER)
    return "\n".join(lines)


def main() -> int:
    with urllib.request.urlopen(IMAGES_URL) as resp:
        data = json.load(resp)

    region_to_ami = {}
    for region in REGIONS:
        images = data.get(region, {}).get("Images", [])
        ami = latest_ami(images)
        if ami is None:
            print(f"ERROR: no matching AMI for {region}", file=sys.stderr)
            return 1
        region_to_ami[region] = ami

    new_block = build_block(region_to_ami)
    text = TEMPLATE.read_text()

    pattern = re.compile(
        r"^  # BEGIN AMI MAP.*?^  # END AMI MAP$",
        re.DOTALL | re.MULTILINE,
    )
    if not pattern.search(text):
        print(
            f"ERROR: markers not found in {TEMPLATE} — expected BEGIN AMI MAP / END AMI MAP",
            file=sys.stderr,
        )
        return 1

    new_text = pattern.sub(new_block, text)

    if new_text == text:
        print("No changes.")
        return 0

    TEMPLATE.write_text(new_text)
    for region, ami in region_to_ami.items():
        print(f"{region}: {ami}")
    print("Updated.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
