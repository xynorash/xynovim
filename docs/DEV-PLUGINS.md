# Running xynovim against the local plugin clones

`lazy-lock.json` pins every `xyno-*.nvim` plugin to a published commit, so work that exists only on a plugin's `dev`
branch is not live in xynovim. To try all of it together (and to run the specs and benchmarks against it) point
xynovim at the clones:

```sh
export XYNOVIM_DEV_PLUGINS=~/projects/xyno-plugins   # the folder that holds xyno-rust.nvim, xyno-imports.nvim, ...
nvim                                                 # these clones are loaded, in place of ~/.local/share/nvim/lazy/xyno-*
```

or through the wrapper, which also prints what is checked out:

```sh
scripts/dev-plugins.sh status       # plugin, branch, last commit, "(uncommitted changes)"
scripts/dev-plugins.sh nvim         # nvim with the clones
scripts/dev-plugins.sh test         # scripts/test.sh with the clones (same arguments), e.g. test macros-deps clipboard
scripts/dev-plugins.sh bench        # scripts/bench/bench.sh with the clones
```

(`scripts/test.lua` works too: `XYNOVIM_DEV_PLUGINS=... nvim -l scripts/test.lua`.)

## What it does

`lua/config/lazy.lua` reads `XYNOVIM_DEV_PLUGINS`. If it names a directory, lazy.nvim's `dev` option is set to that
directory with the pattern `xynorash/xyno-`, so every `xynorash/xyno-*` plugin is loaded from `<dir>/<plugin name>`
(`<dir>/xyno-rust.nvim`, ...). A plugin without a clone there falls back to the normal checkout. If the variable is
unset (the default) nothing changes; if it names something that is not a directory you get one warning and the pinned
plugins.

- Nothing is fetched, installed, pushed or changed: lazy treats the clones as local plugins and never runs `update`,
  `restore` or `clean` on them. The real install under `~/.local/share/nvim/lazy` is not read for these plugins.
- The clones are used as they are (whatever branch and working tree they have). Check with
  `scripts/dev-plugins.sh status`; a plugin on a feature branch or with uncommitted edits is tested like that.
- `lazy-lock.json` is not rewritten by a dev run. The specs that compare the install with the lockfile
  (`startup-and-options`) skip the plugins that are local clones.

## Making the dev work the pinned version

When the plugin commits are pushed, move the lockfile with the commands below (run by you; they fetch from GitHub and
write `lazy-lock.json`, so they are not part of the dev mode). Commit the changed lock lines in this repository.

```sh
unset XYNOVIM_DEV_PLUGINS
nvim --headless "+Lazy! update xyno-rust.nvim xyno-imports.nvim xyno-macros.nvim xyno-crates.nvim xyno-history.nvim xyno-sandbox.nvim xyno-clipboard.nvim xyno-guard.nvim xyno-new.nvim" +qa
git diff lazy-lock.json
```

To put the install back on the lockfile (also fixes any drift the `lazy-lock.json` spec reports):

```sh
nvim --headless "+Lazy! restore" +qa
```

## Specs that need the dev versions

A few specs check behaviour that only exists on the plugins' `dev` branches (the OSC 52 fallback in
`clipboard-e2e`, the xyno-sandbox policy preview in `agent-99-guard`, ...). With the pinned plugins they skip with a
message that names `XYNOVIM_DEV_PLUGINS`; with the clones they run.

## Results of the integration run (2026-11-12)

Same machine, `scripts/test.sh` (pinned plugins) against `scripts/dev-plugins.sh test` (clones on `dev`):

| Mode | Passed | Failed | Skipped |
|---|---|---|---|
| pinned (`lazy-lock.json`) | 1104 | 1 | 46 |
| dev clones | 1131 | 1 | 32 |

The one failure is the same in both modes: `startup-and-options` (10 installed plugins off the lockfile: `nvim --headless "+Lazy! restore" +qa`, to be run by the owner of the install; the spec's message says so). A spec that failed once in dev mode under load, `keymaps-rust` "rv extracts into a variable", passed in the full run and in two reruns. Specs that skip against the pinned plugins with a message naming `XYNOVIM_DEV_PLUGINS`: `rust-ide-features` (run configurations, the code-action menu, organize on save), the real-popup checks of `ui-community`, the policy-preview and checkpoint specs of `agent-99-guard`, the OSC 52 fallback in `clipboard-e2e`. Each clone's own suite (`nvim -l tests/run.lua`): clipboard 33, crates 107, guard 63, history 158, imports 67, macros 283, new 220, rust 339, sandbox 799 passed, none failed.
