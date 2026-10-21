#!/usr/bin/env python3
"""Assemble the website: site/ + the referenced docs/media files -> _site/.

    python3 scripts/build-site.py [--out _site] [--check]

- copies site/ (without site/README.md) into the output directory;
- the pages are site/index.html and every site/**/index.html (the guides under
  site/guides/<slug>/); 404.html is not a page of the sitemap;
- copies ONLY the media files that those pages reference (src, href, poster,
  srcset, resolved against the page, landing in media/) from docs/media/ to
  <out>/media/ and fails when one is missing;
- substitutes the placeholders in the .html / .xml / .txt files, so the
  numbers cannot drift from the README: {{TESTS}} {{SPECS}} {{SKIPPED}}
  {{FAILED}} {{COMMIT}} {{DATE}};
- writes <out>/sitemap.xml from the pages, with lastmod from git (the last
  commit that touched the page's source; today's date without git history);
- writes <out>/.nojekyll;
- with --check, afterwards verifies every built page: every local
  href/src/poster/srcset target exists and every #anchor (also of another
  page) has its id.

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
BASE = "https://xynorash.github.io/xynovim/"


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


def is_external(ref):
    return bool(re.match(r"^(https?:|mailto:|data:|//)", ref))


def media_refs(html, page):
    """Names under docs/media that `page` (a path relative to site/) references."""
    p = Refs()
    p.feed(html)
    found = []
    pagedir = os.path.dirname(page)
    for ref in p.refs:
        ref = ref.split("#")[0].split("?")[0]
        if not ref or is_external(ref):
            continue
        parts = [x for x in ref.split("/") if x not in ("", ".", "..")]
        norm = os.path.normpath(os.path.join(pagedir, ref))
        if norm.startswith("media" + os.sep):
            found.append(norm[len("media" + os.sep):])
        elif parts and parts[0] == "media":
            sys.exit("build-site: media reference leaves docs/media: " + ref)
    return sorted(set(found))


class Ids(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids = set()

    def handle_starttag(self, tag, attrs):
        for name, value in attrs:
            if name == "id" and value:
                self.ids.add(value)


def resolve(out, page, ref):
    """The file a local reference of `page` points at (a directory means its index.html)."""
    path = ref.split("#")[0].split("?")[0]
    target = os.path.normpath(os.path.join(out, os.path.dirname(page), path)) if path else os.path.join(out, page)
    if os.path.isdir(target):
        target = os.path.join(target, "index.html")
    return target


def check(out, pages):
    """Fail on a dangling local reference or anchor in any built page."""
    ids = {}

    def ids_of(path):
        if path not in ids:
            i = Ids()
            with open(path, encoding="utf-8") as f:
                i.feed(f.read())
            ids[path] = i.ids
        return ids[path]

    bad = []
    total = 0
    for page in pages:
        with open(os.path.join(out, page), encoding="utf-8") as f:
            refs = Refs()
            refs.feed(f.read())
        for ref in refs.refs:
            total += 1
            if is_external(ref):
                continue
            target = resolve(out, page, ref)
            if not os.path.isfile(target):
                bad.append("%s -> %s" % (page, ref))
                continue
            frag = ref.split("#")[1] if "#" in ref else ""
            if frag and target.endswith(".html") and frag not in ids_of(target):
                bad.append("%s -> %s" % (page, ref))
    if bad:
        sys.exit("build-site: dangling references: " + ", ".join(sorted(set(bad))))
    print("build-site: %d references in %d pages checked, all resolve" % (total, len(pages)))


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


def site_pages(src):
    """Paths (relative to site/, '/' separated) of every page: index.html and */index.html."""
    pages = []
    for dirpath, _, files in os.walk(src):
        if "index.html" in files:
            rel = os.path.relpath(os.path.join(dirpath, "index.html"), src)
            pages.append(rel.replace(os.sep, "/"))
    return sorted(pages, key=lambda p: (p != "index.html", p))


def lastmod(paths, today):
    """Date of the last commit that touched any of `paths` (relative to the repo root)."""
    try:
        r = subprocess.run(["git", "-C", ROOT, "log", "-1", "--format=%cs", "--"] + paths, capture_output=True, text=True, check=True)
        return r.stdout.strip() or today
    except (OSError, subprocess.CalledProcessError):
        return today


def write_sitemap(out, pages, today):
    lines = ['<?xml version="1.0" encoding="UTF-8"?>', '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">']
    for page in pages:
        url = BASE + page[: -len("index.html")]
        sources = ["site/" + page] + (["README.md"] if page == "index.html" else [])
        lines += ["  <url>", "    <loc>%s</loc>" % url, "    <lastmod>%s</lastmod>" % lastmod(sources, today), "  </url>"]
    lines.append("</urlset>")
    with open(os.path.join(out, "sitemap.xml"), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", default=os.path.join(ROOT, "_site"))
    ap.add_argument("--check", action="store_true", help="verify local references and anchors of the built page")
    args = ap.parse_args()
    out = os.path.abspath(args.out)
    src = os.path.join(ROOT, "site")
    media_src = os.path.join(ROOT, "docs", "media")

    pages = site_pages(src)
    if "index.html" not in pages:
        sys.exit("build-site: site/index.html is missing")
    wanted = set()
    for page in pages:
        with open(os.path.join(src, page), encoding="utf-8") as f:
            wanted.update(media_refs(f.read(), page))
    wanted = sorted(wanted)
    missing = [n for n in wanted if not os.path.isfile(os.path.join(media_src, n))]
    if missing:
        sys.exit("build-site: missing in docs/media: " + ", ".join(missing))

    today = datetime.datetime.now(datetime.timezone.utc).date().isoformat()
    tests, skipped, failed = readme_numbers()
    subst = {
        "TESTS": tests,
        "SPECS": count_specs(),
        "SKIPPED": skipped,
        "FAILED": failed,
        "COMMIT": commit(),
        "DATE": today,
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
            with open(path, "w", encoding="utf-8", newline="\n") as f:
                f.write(text)

    write_sitemap(out, pages, today)
    with open(os.path.join(out, ".nojekyll"), "w", encoding="utf-8"):
        pass
    if args.check:
        check(out, pages)
    print("build-site: %s (%d pages, %d media files, tests %s, specs %s, commit %s)" % (out, len(pages), len(wanted), tests, subst["SPECS"], subst["COMMIT"]))


if __name__ == "__main__":
    main()
