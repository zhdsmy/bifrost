#!/usr/bin/env python3
"""Generate the core's module inventory and accompanying redistribution notices."""

import argparse
import gzip
import json
import re
import shutil
import subprocess
import tarfile
import tempfile
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


def read_metadata(binary):
    build = json.loads(go("version", "-m", "-json", str(binary)))
    if build["Path"] != "tailscale.com/cmd/tailscaled" or not build.get("Deps"):
        raise ValueError("expected a Bifrost tailscaled binary with embedded module metadata")
    return build


def dependencies(build):
    for dep in sorted(build["Deps"], key=lambda dep: dep["Path"]):
        module = dep.get("Replace", dep)
        path = module["Path"]
        name = dep["Path"] if module is dep else f"{dep['Path']} => {path}"
        yield name, module["Version"], path


def check_package(package):
    # Inspect the final artifact. No module downloads or execution of the ELF.
    with tarfile.open(package, "r:gz") as archive, tempfile.TemporaryDirectory() as tmp:
        binary = Path(tmp) / "bifrostd"
        with gzip.open(archive.extractfile("bifrost/bin/bifrostd.gz")) as src, binary.open("wb") as dst:
            shutil.copyfileobj(src, dst)
        build = read_metadata(binary)
        notice = archive.extractfile("bifrost/THIRD_PARTY_NOTICES.core.md").read().decode()
    header = notice.split("## Notice ", 1)[0]
    actual = re.findall(r"^\| `([^`]+)` \| `([^`]+)` \|", header, re.M)
    expected = [("Go standard library", build["GoVersion"])]
    expected.extend((name, version) for name, version, _ in dependencies(build))
    main = build["Main"]
    if (actual != expected or
            re.findall(r"^Main module `([^`]+)`", header, re.M) != [f"{main['Path']} {main['Version']}"]):
        raise ValueError(f"{package.name}: core module inventory differs from the packaged notice")


def generate(binary):
    build = read_metadata(binary)
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
    for name, version, path in dependencies(build):
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
    parser.add_argument("--check-package", action="store_true",
                        help="verify the inventory inside a packaged tarball")
    parser.add_argument("input", type=Path)
    parser.add_argument("output", nargs="?", type=Path,
                        default=Path(__file__).with_name("THIRD_PARTY_NOTICES.core.md"))
    args = parser.parse_args()
    if args.check_package:
        try:
            check_package(args.input)
        except ValueError as exc:
            parser.exit(1, f"{exc}\n")
    else:
        args.output.write_text(generate(args.input), encoding="utf-8")
