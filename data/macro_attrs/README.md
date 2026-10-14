# Attribute schemas

Data for the completion inside helper-attribute arguments (`#[serde(`, `#[arg(`, `#[tokio::main(`, ...), read by `lua/config/macro_attrs.lua`. One JSON file per crate. Shipped here; a project overrides them with `.xynovim/macro_attrs/*.json` in the workspace root (see the end).

## File

```json
{
  "crate": "serde",
  "versions": ">=1.0.0, <2.0.0",
  "docs_url": "https://serde.rs/attributes.html",
  "attributes": [ { "name": "serde", "...": "..." } ]
}
```

| field | meaning |
| --- | --- |
| `crate` | the dependency's package name (`-` and `_` are the same). The file is used only when the workspace member depends on it |
| `versions` | cargo-style requirement on the resolved version (`>=1.0.0, <2`, `^1`, `~1.2`, `*`); a file whose range the dependency does not satisfy is ignored. An unknown version (metadata not loaded yet) satisfies everything |
| `docs_url` | default documentation link shown in the item's preview |
| `attributes` | the attributes the crate defines |

## Attribute

| field | meaning |
| --- | --- |
| `name` | the attribute path as written: `serde`, `arg`, `error`, or `tokio::main`. A `crate::name` attribute macro matches when written in full, or by its last segment when imported (`use tokio::main;`) |
| `derives` | derive macros that bring this helper attribute into scope (`["Serialize", "Deserialize"]`). The helper is offered only when one of them is in a `#[derive(...)]` (also inside `cfg_attr`) of the item the attribute belongs to, and the derive resolves to this crate (a qualified path, or the `use` that imports it, so `Error` of thiserror and of derive_more are told apart). Leave it out for attribute macros |
| `applies_to` | where the attribute may be written: `container` (struct, enum, union), `container:struct`, `container:enum`, `field`, `variant`, `fn`, `param` (a function parameter). Also valid on each argument, where it narrows the attribute's |
| `needs_attr` | the item (the function, for `param`) must carry one of these attributes: `["bon::builder", "builder"]` |
| `docs_url` | link for this attribute (default: the file's) |
| `args` | the keys it takes |

## Argument

| field | meaning |
| --- | --- |
| `key` | the key as written (`rename_all`). A key that is only a label (`"..."` for a positional string) uses `positional` |
| `kind` | `flag` (bare key), `string` (`key = "..."`), `ident`, `path`, `int`, `bool` (bare key or `= true/false`), `enum`, `expr` |
| `values` | for `enum`: the choices, strings or `{ "value": ..., "doc": ... }` |
| `quoted` | for `enum`: the value is a string literal (`rename_all = "camelCase"`); otherwise it is bare (`action = ArgAction::SetTrue`). The menu inserts the quotes when they are not typed yet |
| `applies_to` | see above; default: the attribute's |
| `derives` | the argument only exists for these derives of the item (sqlx's `FromRow` keys vs `Type` keys) |
| `conflicts` | keys that cannot be combined with this one. A key is hidden when it, or any key already written, lists the other |
| `requires` | keys this one needs; still offered, but sorted last until they are present |
| `repeatable` | may appear several times (`alias`); every other key is offered once |
| `since` | first version of the crate that has it; hidden for older resolved versions |
| `nested` | keys accepted in a parenthesised form: `rename(serialize = "..", deserialize = "..")` |
| `positional` | an unkeyed entry that may only come first (`#[error("message")]`) |
| `doc` | one sentence, shown in the preview with the other facts |
| `doc_url` | link for this key |
| `snippet` | what to insert, in LSP snippet syntax (`rename = "${1:name}"`); the default follows `kind`. A snippet ending in a quote placeholder re-opens the menu inside it, for `enum` values |
| `alt` | extra menu entries for the same key: `[{ "label": "default = \"path\"", "snippet": "default = \"$1\"", "doc": "..." }]` |

## Project overrides

`.xynovim/macro_attrs/<anything>.json` in the workspace root uses the same format. For a crate that has a shipped file, an attribute with the same `name` replaces every shipped attribute of that name in that crate (the others stay); for another crate the file is added as it is. A broken file is skipped and the problem is listed by `:MacroAttrs`. Edit a file and the next completion picks it up.

## No schema

An attribute of a dependency without a schema is not left empty: the keys already written inside the same attribute in the workspace and in the dependency's own sources (examples, docs, tests) are offered, most frequent first (bounded scan, cached for two minutes).
