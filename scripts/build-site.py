#!/usr/bin/env python3
"""Assemble the website: site/ + the referenced docs/media files -> _site/.

    python3 scripts/build-site.py [--out _site] [--check]

- copies site/ (without site/README.md) into the output directory;
- copies ONLY the media files that site/index.html references (src, href,
  poster, srcset under media/) from docs/media/ to <out>/media/ and fails when
  one is missing;
- substitutes the placeholders in the .html / .xml / .txt files, so the
  numbers cannot drift from the README: {{TESTS}} {{SPECS}} {{SKIPPED}}
  {{FAILED}} {{COMMIT}} {{DATE}};
- writes <out>/.nojekyll;
- with --check, afterwards verifies the built index.html: every local
  href/src/poster/srcset target exists and every #anchor has its id.

Standard library only.
"""
import argparse
import datetime
import os
import re
import shutil
import subprocess
import sys
from html.parser import HTMLParser

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEXT_EXT = (".html", ".xml", ".txt")


class Refs(HTMLParser):
    """Every local file reference of a page: src, href, poster, srcset."""

    def __init__(self):
        super().__init__()
        self.refs = []

    def handle_starttag(self, tag, attrs):
        for name, value in attrs:
            if not value:
                continue
            if name in ("src", "href", "poster"):
                self.refs.append(value)
            elif name == "srcset":
                self.refs.extend(part.split()[0] for part in value.split(",") if part.strip())


def media_refs(html):
    p = Refs()
    p.feed(html)
    found = []
    for ref in p.refs:
        ref = ref.split("#")[0].split("?")[0]
        if ref.startswith("media/"):
            name = ref[len("media/"):]
            norm = os.path.normpath(name)
            if os.path.isabs(norm) or norm == ".." or norm.startswith(".." + os.sep):
                sys.exit("build-site: media reference leaves docs/media: " + ref)
            found.append(name)
    return sorted(set(found))


class Ids(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids = set()

    def handle_starttag(self, tag, attrs):
        for name, value in attrs:
            if name == "id" and value:
                self.ids.add(value)


def check(out):
    """Fail on a dangling local reference or anchor in <out>/index.html."""
    with open(os.path.join(out, "index.html"), encoding="utf-8") as f:
        text = f.read()
    refs = Refs()
    refs.feed(text)
    ids = Ids()
    ids.feed(text)
    bad = []
    for ref in refs.refs:
        if re.match(r"^(https?:|mailto:|data:)", ref):
            continue
        if ref.startswith("#"):
            if ref[1:] not in ids.ids:
                bad.append(ref)
            continue
        path = ref.split("#")[0].split("?")[0]
        if path and not os.path.isfile(os.path.join(out, path)):
            bad.append(ref)
    if bad:
        sys.exit("build-site: dangling references: " + ", ".join(sorted(set(bad))))
    print("build-site: %d references checked, all resolve" % len(refs.refs))


def readme_numbers():
    with open(os.path.join(ROOT, "README.md"), encoding="utf-8") as f:
        readme = f.read()
    m = re.search(r"badge/tests-(\d+)%20passing", readme)
    if not m:
        sys.exit("build-site: the tests badge of README.md was not found")
    tests = m.group(1)
    skipped = failed = None
    m = re.search(r"(\d+) skipped with a stated reason, (\d+) failing", readme)
    if m:
        skipped, failed = m.group(1), m.group(2)
    return tests, skipped, failed


def count_specs():
    d = os.path.join(ROOT, "tests")
    return str(len([n for n in os.listdir(d) if n.endswith("_spec.lua")]))


def commit():
    sha = os.environ.get("GITHUB_SHA", "").strip()
    if not sha:
        try:
            sha = subprocess.run(["git", "-C", ROOT, "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
        except (OSError, subprocess.CalledProcessError):
            sha = "unknown"
    return sha[:7]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", default=os.path.join(ROOT, "_site"))
    ap.add_argument("--check", action="store_true", help="verify local references and anchors of the built page")
    args = ap.parse_args()
    out = os.path.abspath(args.out)
    src = os.path.join(ROOT, "site")
    media_src = os.path.join(ROOT, "docs", "media")

    with open(os.path.join(src, "index.html"), encoding="utf-8") as f:
        wanted = media_refs(f.read())
    missing = [n for n in wanted if not os.path.isfile(os.path.join(media_src, n))]
    if missing:
        sys.exit("build-site: missing in docs/media: " + ", ".join(missing))

    tests, skipped, failed = readme_numbers()
    subst = {
        "TESTS": tests,
        "SPECS": count_specs(),
        "SKIPPED": skipped,
        "FAILED": failed,
        "COMMIT": commit(),
        "DATE": datetime.datetime.now(datetime.timezone.utc).date().isoformat(),
    }

    if os.path.isdir(out):
        shutil.rmtree(out)
    shutil.copytree(src, out, ignore=shutil.ignore_patterns("README.md"))
    os.makedirs(os.path.join(out, "media"))
    for name in wanted:
        shutil.copyfile(os.path.join(media_src, name), os.path.join(out, "media", name))

    for dirpath, _, files in os.walk(out):
        for fn in files:
            if not fn.endswith(TEXT_EXT):
                continue
            path = os.path.join(dirpath, fn)
            with open(path, encoding="utf-8") as f:
                text = f.read()
            for key, value in subst.items():
                token = "{{%s}}" % key
                if token in text:
                    if value is None:
                        sys.exit("build-site: %s is used in %s but the README does not state it" % (token, fn))
                    text = text.replace(token, value)
            left = re.findall(r"\{\{[A-Z]+\}\}", text)
            if left:
                sys.exit("build-site: unknown placeholder %s in %s" % (left[0], fn))
            with open(path, "w", encoding="utf-8") as f:
                f.write(text)

    with open(os.path.join(out, ".nojekyll"), "w", encoding="utf-8"):
        pass
    if args.check:
        check(out)
    print("build-site: %s (%d media files, tests %s, specs %s, commit %s)" % (out, len(wanted), tests, subst["SPECS"], subst["COMMIT"]))


if __name__ == "__main__":
    main()
