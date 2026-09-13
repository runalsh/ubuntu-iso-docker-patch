#!/usr/bin/env python3
"""
Ubuntu ISO Release Auto-Discovery Script
Scans official Ubuntu release mirrors (releases.ubuntu.com and old-releases.ubuntu.com)
for live-server ISOs across Ubuntu 22.04, 24.04, and 26.04 series.
"""

import sys
import os
import re
import argparse
import urllib.request

TRACKS = [
    ("26.04", "resolute", [
        "https://releases.ubuntu.com/resolute/",
        "https://old-releases.ubuntu.com/releases/resolute/"
    ]),
    ("24.04", "noble", [
        "https://releases.ubuntu.com/noble/",
        "https://old-releases.ubuntu.com/releases/noble/"
    ]),
    ("22.04", "jammy", [
        "https://releases.ubuntu.com/jammy/",
        "https://old-releases.ubuntu.com/releases/jammy/"
    ]),
]

def load_existing_releases(filepath):
    existing = {}
    if not os.path.exists(filepath):
        return existing
    with open(filepath, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                parts = line.split()
                if len(parts) >= 2:
                    tag = parts[0]
                    if tag.count('.') == 1:
                        tag = f"{tag}.0"
                    existing[tag] = parts[1]
    return existing

def scan_track_isos(track_ver, codename, urls):
    discovered = {}
    pattern = re.compile(
        r'href="(ubuntu-(2[246]\.04(?:\.[0-9]+)?)-live-server-amd64\.iso)"',
        re.IGNORECASE
    )

    for base_url in urls:
        try:
            req = urllib.request.Request(base_url, headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(req, timeout=15) as resp:
                html = resp.read().decode('utf-8', errors='ignore')
                for match in pattern.finditer(html):
                    iso_name = match.group(1)
                    tag = match.group(2)
                    if tag.count('.') == 1:
                        tag = f"{tag}.0"
                    full_url = f"{base_url.rstrip('/')}/{iso_name}"
                    if tag not in discovered:
                        discovered[tag] = full_url
        except Exception:
            continue

    return discovered

def discover_all_releases():
    all_discovered = {}
    for track_ver, codename, urls in TRACKS:
        track_map = scan_track_isos(track_ver, codename, urls)
        for tag, url in track_map.items():
            all_discovered[tag] = url
    return all_discovered

def version_sort_key(ver):
    try:
        parts = [int(x) for x in ver.split('.')]
        return parts
    except ValueError:
        return [0]

def populate_releases_file(filepath):
    existing = load_existing_releases(filepath)
    discovered = discover_all_releases()

    merged = dict(existing)
    new_found = []
    for tag, url in discovered.items():
        if tag not in merged:
            merged[tag] = url
            new_found.append(tag)

    # Group by major track: 26, 24, 22
    tracks = {"26": {}, "24": {}, "22": {}}
    for tag, url in merged.items():
        major = tag.split('.')[0]
        if major in tracks:
            tracks[major][tag] = url
        else:
            tracks.setdefault(major, {})[tag] = url

    lines = [
        "# Ubuntu ISO Releases (26.04 LTS Resolute, 24.04 LTS Noble, 22.04 LTS Jammy)",
        "# Format: <tag> <iso_download_url>",
        ""
    ]

    for major in ["26", "24", "22"]:
        if major not in tracks or not tracks[major]:
            continue
        series_name = "Resolute" if major == "26" else ("Noble" if major == "24" else "Jammy")
        lines.append(f"# Ubuntu {major}.04 LTS ({series_name})")
        sorted_tags = sorted(tracks[major].keys(), key=version_sort_key, reverse=True)
        for tag in sorted_tags:
            lines.append(f"{tag} {tracks[major][tag]}")
        lines.append("")

    content = "\n".join(lines).strip() + "\n"

    with open(filepath, "w", encoding="utf-8") as f:
        f.write(content)

    return new_found

def main():
    parser = argparse.ArgumentParser(description="Auto-discover Ubuntu ISO releases")
    parser.add_argument("--list", action="store_true", help="List discovered releases to stdout")
    parser.add_argument("--populate-releases", metavar="FILE", help="Update specified releases file")
    parser.add_argument("--check-only", action="store_true", help="Exit 1 if new releases are available")

    args = parser.parse_args()

    if args.list:
        discovered = discover_all_releases()
        print(f"Discovered {len(discovered)} releases:")
        sorted_tags = sorted(discovered.keys(), key=version_sort_key, reverse=True)
        for tag in sorted_tags:
            print(f"{tag:10} {discovered[tag]}")
        sys.exit(0)

    if args.populate_releases:
        new_releases = populate_releases_file(args.populate_releases)
        if new_releases:
            print(f"[SUCCESS] Discovered and added {len(new_releases)} new release(s): {', '.join(new_releases)}")
        else:
            print("[INFO] No new releases discovered. releases.txt is up to date.")
        sys.exit(0)

    if args.check_only:
        filepath = "releases.txt"
        existing = load_existing_releases(filepath)
        discovered = discover_all_releases()
        diff = set(discovered.keys()) - set(existing.keys())
        if diff:
            print(f"New releases found: {', '.join(diff)}")
            sys.exit(1)
        else:
            print("No new releases found.")
            sys.exit(0)

    parser.print_help()

if __name__ == "__main__":
    main()
