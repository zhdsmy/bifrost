#!/usr/bin/env python3
"""Generate the core's module inventory and accompanying redistribution notices."""

import argparse
import json
import re
import subprocess
from pathlib import Path


def go(*args):
    return subprocess.check_output(["go", *args], text=True).strip()


def cache_name(name):
    # The Go module cache uses !lower for each uppercase letter.
    return re.sub("[A-Z]", lambda m: "!" + m[0].lower(), name)


def license_label(file, body):
    if not file.name.upper().startswith(("LICEN", "COPYING")):
        return file.name
    text = " ".join(body.lower().split())
    labels = []
    if "apache license" in text and "version 2.0" in text:
        labels.append("Apache-2.0")
    if "redistribution and use in source and binary forms" in text:
        labels.append("BSD-3-Clause" if "endorse or promote" in text else "BSD-2-Clause")
    if "permission is hereby granted, free of charge" in text:
        labels.append("MIT")
    return ", ".join(labels) or file.name


def generate(binary):
    build = json.loads(go("version", "-m", "-json", str(binary)))
    if build["Path"] != "tailscale.com/cmd/tailscaled" or not build.get("Deps"):
        raise ValueError("expected a Bifrost tailscaled binary with embedded module metadata")
    env = json.loads(go("env", "-json", "GOROOT", "GOVERSION", "GOMODCACHE"))
    if build["GoVersion"] != env["GOVERSION"]:
        raise ValueError(f"use {build['GoVersion']} to collect the matching Go license")
    cache = Path(env["GOMODCACHE"])
    documents = {}
    rows = []

    def add(name, version, directory):
        files = sorted(p for p in directory.iterdir() if p.is_file() and
                       re.fullmatch(r"(LICEN[CS]E|COPYING|NOTICE|PATENTS)([.-].*)?", p.name, re.I))
        # Homebrew splits the Go distribution between libexec/ and its parent.
        if directory == Path(env["GOROOT"]) and directory.name == "libexec" and not (directory / "LICENSE").exists():
            files.insert(0, directory.parent / "LICENSE")
        if not any(p.name.upper().startswith(("LICEN", "COPYING")) for p in files):
            raise ValueError(f"missing license for {name} {version}")
        links = []
        for file in files:
            body = "\n".join(line.rstrip() for line in file.read_text().strip().splitlines())
            index = documents.setdefault(body, len(documents) + 1)
            links.append(f"[{license_label(file, body)}](#notice-{index})")
        rows.append(f"| `{name}` | `{version}` | {', '.join(links)} |")

    add("Go standard library", build["GoVersion"], Path(env["GOROOT"]))
    for dep in sorted(build["Deps"], key=lambda dep: dep["Path"]):
        module = dep.get("Replace", dep)
        path, version = module["Path"], module["Version"]
        name = dep["Path"] if module is dep else f"{dep['Path']} => {path}"
        add(name, version, cache / f"{cache_name(path)}@{cache_name(version)}")

    main = build["Main"]
    lines = ["# Bifrost core third-party notices", "",
             f"Main module `{main['Path']} {main['Version']}` is distributed under `LICENSE.tailscale`.",
             f"The binary links the Go standard library and {len(build['Deps'])} dependency modules.",
             "Identical license and notice texts appear once below.", "",
             "| Component | Version | License and notices |", "|---|---|---|", *rows, ""]
    for body, index in documents.items():
        lines.extend([f"## Notice {index}", "", "~~~~text", body, "~~~~", ""])
    return "\n".join(lines)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("output", nargs="?", type=Path,
                        default=Path(__file__).with_name("THIRD_PARTY_NOTICES.core.md"))
    args = parser.parse_args()
    args.output.write_text(generate(args.binary), encoding="utf-8")
