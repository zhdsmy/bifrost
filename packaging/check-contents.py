#!/usr/bin/env python3
"""Verify router integration files in the extracted offline package."""

import re
import sys
from html.parser import HTMLParser
from pathlib import Path


class Page(HTMLParser):
    def handle_starttag(self, tag, attrs):
        if tag == "body":
            if self.body is not None:
                sys.exit("self-check failed: duplicate <body>")
            self.body = dict(attrs)
            if len(self.get_starttag_text().splitlines()) != 1:
                sys.exit("self-check failed: <body> attributes must be on one line")

    body = None


def check(root, keys, key_count):
    for name in ("daemon.sh", "update.sh"):
        path = root / "lib" / name
        if not path.is_file() or path.stat().st_size == 0:
            sys.exit(f"self-check failed: missing or empty lib/{name}")
    published = sorted((root / "keys").glob("*.pub.pem"))
    if len(published) != key_count:
        sys.exit("self-check failed: package public key count differs from input")
    for key in published:
        original = keys / key.name
        if not original.is_file() or not key.stat().st_size or original.read_bytes() != key.read_bytes():
            sys.exit(f"self-check failed: package public key differs: {key.name}")

    page = Page()
    # Firmware evaluates ASP expressions (which can contain quotes) before HTML parsing.
    source = (root / "webs/Module_bifrost.asp").read_text()
    page.feed(re.sub(r"<%[^\n]*?%>", "firmware-value", source))
    attrs = page.body or {}
    for attr in ("id", "onload", "skin"):
        if not attrs.get(attr) or (attr == "id" and attrs[attr] != "app"):
            token = "app" if attr == "id" else attr
            sys.exit(f"self-check failed: Module_bifrost.asp <body> line missing '{token}'")


if __name__ == "__main__":
    check(Path(sys.argv[1]), Path(sys.argv[2]), int(sys.argv[3]))
