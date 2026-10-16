# The xynovim website

Source of <https://xynorash.github.io/xynovim/>: one static page, no framework, no external requests (no CDN, no web fonts, no analytics), system fonts and inline SVG icons only. `assets/app.js` is progressive enhancement (copy buttons, active nav link, play videos while visible); the page is complete without it.

| Path | What |
| --- | --- |
| `index.html` | the page (placeholders `{{TESTS}} {{SPECS}} {{SKIPPED}} {{FAILED}} {{COMMIT}} {{DATE}}` are filled by the build) |
| `assets/style.css`, `assets/app.js`, `assets/favicon.svg` | style (dark Island Dark palette, a deliberate light palette, reduced motion respected), script, icon |
| `assets/og.png` | the 1200x630 social card (made with ImageMagick from `docs/media/01-hero.png`) |
| `assets/posters/` | video poster frames (JPEG, one per recording) |
| `404.html` | the only file with absolute `/xynovim/` paths (Pages serves it at the missing URL) |
| `robots.txt`, `sitemap.xml` | canonical `https://xynorash.github.io/xynovim/` URLs |

The screenshots and recordings are not duplicated here: the build copies exactly the files `index.html` references from `docs/media/` into `_site/media/`.

## Build and preview

```sh
python3 scripts/build-site.py            # writes _site/ (git-ignored)
mkdir -p /tmp/p && ln -sfn "$PWD/_site" /tmp/p/xynovim && python3 -m http.server -d /tmp/p 8000
# open http://localhost:8000/xynovim/   (the /xynovim/ prefix is how Pages serves it)
```

The numbers on the page come from the README (tests badge, test summary) and from `tests/*_spec.lua`, so they cannot drift; the spec `tests/site_spec.lua` checks the built site (links, assets, CSP, alt texts, budgets, the workflow).

## Publishing

`.github/workflows/pages.yml` builds the site on every push to `main` that touches the site, the media, the README or the build script, and force-pushes it as a single orphan commit to the branch `gh-pages` (only the built site, `.nojekyll` included). GitHub Pages serves that branch: Settings > Pages > Build and deployment > Deploy from a branch > `gh-pages` / `/ (root)`.
