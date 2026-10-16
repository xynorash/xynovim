-- config.macro_attrs: completion inside helper-attribute arguments and #[derive(...)]
-- (lua/config/macro_attrs.lua, data/macro_attrs/*.json, lua/plugins/macro-attrs.lua).
-- Hermetic: workspaces are temp copies of the deps-lab fixture, cargo metadata is
-- stubbed out (dependencies come from the Cargo.toml scan) except in the one test that
-- asks for the real thing. Derive discovery reads the registry sources of serde_derive,
-- clap_derive and thiserror-impl and skips without them. Only the derive `use` test
-- needs rust-analyzer.
local H = require("xynotest.helpers")
local ma = require("config.macro_attrs")
local cm = require("config.crate_meta")
local ca = require("config.code_actions")

local restores = {}
local function stub(t, k, v)
  local orig = t[k]
  t[k] = v
  restores[#restores + 1] = function()
    t[k] = orig
  end
end

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

local function no_metadata()
  stub(cm, "metadata_async", function(_, cb)
    vim.schedule(function()
      cb(nil, "stubbed in the spec")
    end)
  end)
end

before_each(function()
  no_metadata()
end)

after_each(function()
  for i = #restores, 1, -1 do
    pcall(restores[i])
  end
  restores = {}
  pcall(vim.cmd, "silent! %bwipeout!")
end)

local registry_ok = cm.registry_dir("serde_derive") and cm.registry_dir("clap_derive") and cm.registry_dir("thiserror-impl")

-- ----------------------------------------------------------------- helpers

--- A temp copy of deps-lab (serde, clap, thiserror, tokio, anyhow, serde_json).
local lab_dir
local function lab()
  lab_dir = lab_dir or H.fixture("deps-lab")
  return lab_dir
end

--- A workspace with extra dependencies named in Cargo.toml (no cargo run needed).
local wide_dir
local function wide()
  if not wide_dir then
    wide_dir = H.tmpdir() .. "/wide"
    write(
      wide_dir .. "/Cargo.toml",
      [[
[package]
name = "wide"
version = "0.1.0"
edition = "2024"

[dependencies]
serde = { version = "1", features = ["derive"] }
thiserror = "2"
derive_more = { version = "2", features = ["full"] }
sqlx = "0.9"
strum = { version = "0.27", features = ["derive"] }
bon = "3"
utoipa = "5"
schemars = "1"
]]
    )
    write(wide_dir .. "/src/main.rs", "fn main() {}\n")
  end
  return wide_dir
end

--- Items at the `|` of `src`, in a buffer named src/lib.rs of `dir` (default: the lab).
local function at(src, dir)
  dir = dir or lab()
  local lines = vim.split(src, "\n", { plain = true })
  local row, col
  for i, l in ipairs(lines) do
    local c = l:find("|", 1, true)
    if c then
      row, col = i, c - 1
      lines[i] = l:gsub("|", "", 1)
      break
    end
  end
  assert(row, "no | in the case")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, dir .. "/src/lib.rs")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local items, info = ma.items(buf, row, col)
  vim.api.nvim_buf_delete(buf, { force = true })
  local labels, by = {}, {}
  for _, it in ipairs(items) do
    labels[#labels + 1] = it.label
    by[it.label] = it
  end
  return labels, items, info, by
end

local function has_all(labels, want, ctx)
  for _, w in ipairs(want or {}) do
    if not vim.tbl_contains(labels, w) then
      error(("%s: %q missing from %s"):format(ctx, w, table.concat(labels, " ")), 0)
    end
  end
end

local function has_none(labels, unwanted, ctx)
  for _, w in ipairs(unwanted or {}) do
    if vim.tbl_contains(labels, w) then
      error(("%s: %q must not be offered (got %s)"):format(ctx, w, table.concat(labels, " ")), 0)
    end
  end
end

local function unique(labels, ctx)
  local seen = {}
  for _, l in ipairs(labels) do
    if seen[l] then
      error(("%s: %q offered twice"):format(ctx, l), 0)
    end
    seen[l] = true
  end
end

-- ------------------------------------------------------- the table of cases

local SERDE_CASES = { "lowercase", "UPPERCASE", "PascalCase", "camelCase", "snake_case", "SCREAMING_SNAKE_CASE", "kebab-case", "SCREAMING-KEBAB-CASE" }

-- { name, src, has, lacks, dir = "wide", exact = n, registry = true }
local cases = {
  -- serde
  {
    "serde container struct",
    "use serde::Serialize;\n#[derive(Serialize)]\n#[serde(|)]\nstruct A { x: u32 }",
    { "rename", "rename_all", "deny_unknown_fields", "default", "bound", "transparent", "from", "try_from", "into", "remote", "tag", "crate" },
    { "skip", "flatten", "alias", "skip_serializing_if", "content", "untagged", "getter" },
  },
  {
    "serde container enum",
    "#[derive(Deserialize)]\n#[serde(|)]\nenum E { A }",
    { "tag", "content", "untagged", "rename_all", "rename_all_fields", "deny_unknown_fields" },
    { "transparent", "flatten", "skip" },
  },
  {
    "serde field",
    "#[derive(Serialize, Deserialize)]\nstruct A {\n    #[serde(|)]\n    x: u32,\n}",
    { "rename", "alias", "default", "skip", "skip_serializing", "skip_deserializing", "skip_serializing_if", "flatten", "with", "serialize_with", "deserialize_with", "bound", "getter", "borrow" },
    { "deny_unknown_fields", "tag", "transparent", "rename_all", "from", "remote" },
  },
  {
    "serde field, unfinished attribute at the end of the struct",
    "#[derive(Serialize)]\nstruct A {\n    x: u32,\n    #[serde(|\n}",
    { "rename", "flatten", "skip" },
    { "rename_all", "deny_unknown_fields" },
  },
  {
    "serde field, key prefix typed",
    "#[derive(Serialize)]\nstruct A {\n    #[serde(ren|\n    x: u32,\n}",
    { "rename" },
    { "rename_all", "deny_unknown_fields" },
  },
  {
    "serde variant",
    "#[derive(Serialize)]\nenum E {\n    #[serde(|)]\n    A,\n}",
    { "rename", "alias", "skip", "untagged", "other", "rename_all", "with" },
    { "flatten", "skip_serializing_if", "deny_unknown_fields" },
  },
  {
    "serde tuple-struct field",
    "#[derive(Serialize)]\nstruct T(#[serde(|)] u32);",
    { "skip", "rename", "with" },
    { "deny_unknown_fields" },
  },
  {
    "serde field of a struct variant",
    "#[derive(Serialize)]\nenum E {\n    V { #[serde(|)] a: u32 },\n}",
    { "flatten", "skip_serializing_if", "rename" },
    { "untagged", "deny_unknown_fields" },
  },
  {
    "a key already written is not offered again",
    "#[derive(Serialize)]\nstruct A {\n    #[serde(rename = \"x\", |)]\n    a: u32,\n}",
    { "default", "skip_serializing_if" },
    { "rename" },
  },
  {
    "skip conflicts with the keys it makes pointless",
    "#[derive(Serialize)]\nstruct A {\n    #[serde(skip, |)]\n    a: u32,\n}",
    { "default" },
    { "skip", "skip_serializing", "skip_deserializing", "with", "flatten", "serialize_with", "rename" },
  },
  {
    "with conflicts with serialize_with and deserialize_with",
    "#[derive(Serialize)]\nstruct A {\n    #[serde(with = \"m\", |)]\n    a: u32,\n}",
    { "default", "alias" },
    { "with", "serialize_with", "deserialize_with", "skip" },
  },
  {
    "conflicts work in both directions (serialize_with hides with)",
    "#[derive(Serialize)]\nstruct A {\n    #[serde(serialize_with = \"f\", |)]\n    a: u32,\n}",
    { "deserialize_with", "default" },
    { "with", "skip", "skip_serializing", "serialize_with" },
  },
  {
    "untagged hides tag and content",
    "#[derive(Serialize)]\n#[serde(untagged, |)]\nenum E { A }",
    { "rename_all", "deny_unknown_fields" },
    { "tag", "content", "untagged" },
  },
  {
    "a repeatable key (alias) stays offered",
    "#[derive(Deserialize)]\nstruct A {\n    #[serde(alias = \"a\", |)]\n    a: u32,\n}",
    { "alias", "default" },
    { "rename_all" },
  },
  {
    "enum values, inside the quotes",
    '#[derive(Serialize)]\n#[serde(rename_all = "|")]\nstruct A { x: u32 }',
    SERDE_CASES,
    { "rename_all", "camel", "rename" },
    exact = 8,
  },
  {
    "enum values, quotes not typed yet",
    "#[derive(Serialize)]\n#[serde(rename_all = |)]\nstruct A { x: u32 }",
    { "camelCase", "snake_case" },
    { "rename_all" },
    exact = 8,
  },
  {
    "enum values, string left open",
    '#[derive(Serialize)]\n#[serde(rename_all = "ca|\nstruct A { x: u32 }',
    { "camelCase", "PascalCase" },
    {},
  },
  {
    "enum values of a field's attribute are not the container's",
    '#[derive(Serialize)]\nstruct A {\n    #[serde(rename = "|")]\n    a: u32,\n}',
    {},
    { "camelCase" },
    exact = 0,
  },
  {
    "nested keys: rename(...)",
    "#[derive(Serialize)]\nstruct A {\n    #[serde(rename(|))]\n    a: u32,\n}",
    { "serialize", "deserialize" },
    { "rename", "skip" },
  },
  {
    "nested keys skip the ones written",
    '#[derive(Serialize)]\nstruct A {\n    #[serde(rename(serialize = "s", |))]\n    a: u32,\n}',
    { "deserialize" },
    { "serialize" },
  },
  {
    "no derive, no serde keys",
    "#[serde(|)]\nstruct A { x: u32 }",
    {},
    { "rename", "skip" },
    exact = 0,
  },
  {
    "a derive that does not provide serde",
    "#[derive(Debug, Clone)]\n#[serde(|)]\nstruct A { x: u32 }",
    {},
    { "rename" },
    exact = 0,
  },
  {
    "path-qualified derive",
    "#[derive(serde::Serialize)]\n#[serde(|)]\nstruct A { x: u32 }",
    { "rename" },
    {},
  },
  {
    "derive inside cfg_attr",
    '#[cfg_attr(feature = "serde", derive(Serialize))]\n#[serde(|)]\nstruct A { x: u32 }',
    { "rename_all" },
    {},
  },
  {
    "serde inside cfg_attr",
    '#[derive(Serialize)]\nstruct A {\n    #[cfg_attr(feature = "x", serde(|))]\n    a: u32,\n}',
    { "rename", "skip" },
    { "deny_unknown_fields" },
  },
  {
    "multi-line attribute",
    '#[derive(Serialize)]\n#[serde(\n    rename_all = "camelCase",\n    |\n)]\nstruct A { x: u32 }',
    { "deny_unknown_fields", "default" },
    { "rename_all" },
  },
  -- clap
  {
    "clap arg on a field",
    "#[derive(Parser)]\nstruct C {\n    #[arg(|)]\n    n: u32,\n}",
    { "short", "long", "value_name", "default_value", "env", "num_args", "value_enum", "value_parser", "action", "global", "help", "long_help", "conflicts_with", "requires", "group", "required" },
    { "name", "about", "subcommand_required", "subcommand" },
  },
  {
    "clap arg: long written, short still offered",
    "#[derive(Parser)]\nstruct C {\n    #[arg(long, |)]\n    n: u32,\n}",
    { "short", "env" },
    { "long" },
  },
  {
    "clap arg: default_value hides default_value_t and required",
    '#[derive(Args)]\nstruct C {\n    #[arg(default_value = "1", |)]\n    n: u32,\n}',
    { "short", "long" },
    { "default_value", "default_value_t", "required" },
  },
  {
    "clap arg: value_enum hides value_parser",
    "#[derive(Parser)]\nstruct C {\n    #[arg(value_enum, |)]\n    n: u32,\n}",
    { "short" },
    { "value_parser" },
  },
  {
    "clap command on the container",
    "#[derive(Parser)]\n#[command(|)]\nstruct C {}",
    { "name", "version", "author", "about", "long_about", "subcommand_required", "arg_required_else_help", "propagate_version", "next_line_help", "disable_help_flag", "disable_help_subcommand", "rename_all" },
    { "short", "long", "subcommand", "flatten", "value_name" },
  },
  {
    "clap command on a field (subcommand / flatten)",
    "#[derive(Parser)]\nstruct C {\n    #[command(|)]\n    sub: Sub,\n}",
    { "subcommand", "flatten", "skip" },
    { "name", "about", "version" },
  },
  {
    "clap command on a Subcommand variant",
    "#[derive(Subcommand)]\nenum S {\n    #[command(|)]\n    Run,\n}",
    { "name", "about", "alias", "external_subcommand", "hide" },
    { "subcommand" },
  },
  {
    "clap arg action values (unquoted)",
    "#[derive(Parser)]\nstruct C {\n    #[arg(action = |)]\n    n: bool,\n}",
    { "ArgAction::SetTrue", "ArgAction::Count", "ArgAction::Append" },
    { "action" },
  },
  {
    "clap value on a ValueEnum variant",
    "#[derive(ValueEnum)]\nenum M {\n    #[value(|)]\n    A,\n}",
    { "name", "alias", "help", "skip" },
    { "short", "about" },
  },
  {
    "clap without a derive offers nothing",
    "struct C {\n    #[arg(|)]\n    n: u32,\n}",
    {},
    { "short" },
    exact = 0,
  },
  -- thiserror
  {
    "thiserror error on a variant",
    "#[derive(Error)]\nenum E {\n    #[error(|)]\n    A,\n}",
    { '"..."', "transparent", "fmt" },
    {},
    exact = 3,
  },
  {
    "thiserror error: the message is positional (only first)",
    '#[derive(Error)]\nenum E {\n    #[error("x {0}", |)]\n    A(u32),\n}',
    { "fmt" },
    { '"..."' },
  },
  {
    "thiserror error on the container",
    "#[derive(Error)]\n#[error(|)]\nstruct E;",
    { "transparent" },
    {},
  },
  -- tokio
  {
    "tokio::main keys",
    "#[tokio::main(|)]\nasync fn main() {}",
    { "flavor", "worker_threads", "crate" },
    { "start_paused" },
  },
  {
    "tokio::test keys",
    "#[tokio::test(|)]\nasync fn t() {}",
    { "flavor", "worker_threads", "start_paused", "crate" },
    {},
  },
  {
    "tokio::main flavor values",
    '#[tokio::main(flavor = "|")]\nasync fn main() {}',
    { "multi_thread", "current_thread" },
    { "flavor" },
    exact = 2,
  },
  {
    "tokio flavor written: not offered again",
    '#[tokio::main(flavor = "current_thread", |)]\nasync fn main() {}',
    { "worker_threads" },
    { "flavor" },
  },
  {
    "tokio attribute imported by name",
    "use tokio::main;\n#[main(|)]\nasync fn main() {}",
    { "flavor" },
    {},
  },
  {
    "tokio attribute not imported: `main` is something else",
    "#[main(|)]\nasync fn main() {}",
    {},
    { "flavor" },
    exact = 0,
  },
  -- derive names
  {
    "derive builtin names",
    "#[derive(|)]\nstruct A;",
    { "Debug", "Clone", "Copy", "PartialEq", "Eq", "PartialOrd", "Ord", "Hash", "Default" },
    {},
  },
  {
    "derive names of the dependencies",
    "#[derive(|)]\nstruct A;",
    { "Serialize", "Deserialize", "Parser", "Args", "Subcommand", "ValueEnum", "Error" },
    {},
    registry = true,
  },
  {
    "derive: written names are not offered again",
    "#[derive(Debug, Serialize, |)]\nstruct A;",
    { "Clone", "Deserialize" },
    { "Debug", "Serialize" },
    registry = true,
  },
  {
    "derive: prefix typed, attribute not closed",
    "#[derive(Debug, Se|\nstruct A;",
    { "Serialize", "Clone" },
    { "Debug" },
    registry = true,
  },
  {
    "derive: a qualifier narrows to that crate",
    "#[derive(serde::|)]\nstruct A;",
    { "Serialize", "Deserialize" },
    { "Debug", "Parser", "Error" },
    registry = true,
  },
  {
    "derive in cfg_attr",
    '#[cfg_attr(feature = "x", derive(|))]\nstruct A;',
    { "Debug", "Clone" },
    {},
  },
  -- other crates (the wide workspace)
  {
    "sqlx FromRow field keys",
    "#[derive(sqlx::FromRow)]\nstruct R {\n    #[sqlx(|)]\n    a: u32,\n}",
    { "rename", "default", "flatten", "skip", "try_from", "json" },
    { "type_name", "transparent", "rename_all" },
    dir = "wide",
  },
  {
    "sqlx Type container keys (not the FromRow ones)",
    "#[derive(sqlx::Type)]\n#[sqlx(|)]\nenum E { A }",
    { "rename_all", "type_name", "transparent" },
    { "flatten", "skip", "json", "default" },
    dir = "wide",
  },
  {
    "sqlx rename_all values",
    '#[derive(sqlx::FromRow)]\n#[sqlx(rename_all = "|")]\nstruct R { a: u32 }',
    { "snake_case", "camelCase", "PascalCase" },
    {},
    dir = "wide",
  },
  {
    "strum container keys",
    "#[derive(EnumString)]\n#[strum(|)]\nenum E { A }",
    { "serialize_all", "ascii_case_insensitive", "use_phf", "prefix" },
    { "serialize", "to_string", "disabled" },
    dir = "wide",
  },
  {
    "strum variant keys",
    "#[derive(strum::Display)]\nenum E {\n    #[strum(|)]\n    A,\n}",
    { "serialize", "to_string", "disabled", "default", "message", "ascii_case_insensitive" },
    { "serialize_all", "use_phf" },
    dir = "wide",
  },
  {
    "strum serialize_all values",
    '#[derive(EnumString)]\n#[strum(serialize_all = "|")]\nenum E { A }',
    { "snake_case", "title_case", "Train-Case", "SCREAMING-KEBAB-CASE" },
    {},
    dir = "wide",
  },
  {
    "bon builder field keys",
    "#[derive(bon::Builder)]\nstruct S {\n    #[builder(|)]\n    x: u32,\n}",
    { "default", "into", "skip", "start_fn", "finish_fn", "required", "name" },
    { "builder_type", "derive" },
    dir = "wide",
  },
  {
    "bon builder container keys",
    "#[derive(bon::Builder)]\n#[builder(|)]\nstruct S { x: u32 }",
    { "builder_type", "derive", "finish_fn", "on" },
    { "default", "into", "skip" },
    dir = "wide",
  },
  {
    "bon builder on a fn parameter",
    "#[bon::builder]\nfn f(#[builder(|)] a: u32) {}",
    { "default", "into", "name" },
    { "builder_type" },
    dir = "wide",
  },
  {
    "bon: a parameter of a function without #[builder] gets nothing",
    "fn f(#[builder(|)] a: u32) {}",
    {},
    { "default" },
    dir = "wide",
    exact = 0,
  },
  {
    "derive_more's Error, not thiserror's, when it is what is imported",
    "use derive_more::Error;\n#[derive(Error)]\nstruct S {\n    #[error(|)]\n    src: u32,\n}",
    { "source", "ignore" },
    { "transparent", "fmt" },
    dir = "wide",
  },
  {
    "thiserror's Error when it is what is imported",
    "use thiserror::Error;\n#[derive(Error)]\nenum S {\n    #[error(|)]\n    A,\n}",
    { "transparent", "fmt" },
    { "source", "ignore" },
    dir = "wide",
  },
  {
    "utoipa schema",
    "#[derive(ToSchema)]\nstruct S {\n    #[schema(|)]\n    a: u32,\n}",
    { "description", "example", "format", "value_type", "inline", "nullable", "minimum", "maximum" },
    { "as" },
    dir = "wide",
  },
  {
    "schemars",
    "#[derive(JsonSchema)]\n#[schemars(|)]\nstruct S { a: u32 }",
    { "rename", "deny_unknown_fields", "title", "description", "crate" },
    { "flatten", "range" },
    dir = "wide",
  },
  -- not a completion context
  {
    "outside an attribute",
    "fn f() {\n    let x = |;\n}",
    {},
    {},
    exact = 0,
  },
  {
    "after the attribute is closed",
    "#[derive(Serialize)]\nstruct A { a: u32 }\nfn f() { let v = vec![1]; | }",
    {},
    {},
    exact = 0,
  },
  {
    "inside a format string of the attribute",
    '#[derive(Error)]\nenum E {\n    #[error("bad |")]\n    A,\n}',
    {},
    {},
    exact = 0,
  },
  {
    "a crate that is not a dependency (serde_json's derive-less lab has no sqlx)",
    "#[derive(sqlx::FromRow)]\nstruct R {\n    #[sqlx(|)]\n    a: u32,\n}",
    {},
    { "rename", "json" },
    exact = 0,
  },
}

describe("attribute argument and derive completion (table)", function()
  for _, c in ipairs(cases) do
    local name, src, has, lacks = c[1], c[2], c[3], c[4]
    it(name, function()
      if c.registry and not registry_ok then
        skip("serde_derive / clap_derive / thiserror-impl are not in the local cargo registry")
      end
      local labels = at(src, c.dir == "wide" and wide() or nil)
      unique(labels, name)
      has_all(labels, has, name)
      has_none(labels, lacks, name)
      if c.exact then
        H.eq(c.exact, #labels, name .. ": number of items, got " .. table.concat(labels, " "))
      end
    end)
  end
end)

-- ------------------------------------------------------------- item details

describe("item content", function()
  it("a key's item carries a snippet, the crate in detail and a doc preview with its facts", function()
    local _, _, _, by = at("#[derive(Serialize)]\n#[serde(|)]\nstruct A { x: u32 }")
    local it = by.rename_all
    H.ok(it, "rename_all offered")
    H.eq(vim.lsp.protocol.InsertTextFormat.Snippet, it.insertTextFormat)
    H.eq('rename_all = "$1"', it.insertText, "quoted enum: cursor inside the quotes")
    H.match(it.detail, "serde", true)
    H.match(it.documentation.value, "case convention", true)
    H.match(it.documentation.value, "applies to: container", true)
    H.match(it.documentation.value, "camelCase", true)
    H.match(it.documentation.value, "serde.rs", true)
    H.eq('default = "path"', by['default = "path"'].label, "an alternative form is its own entry")
    H.eq('default = "${1:path::to::fn}"', by['default = "path"'].insertText)
    H.eq("default", by.default.insertText, "flag: the bare key")
  end)

  it("enum values keep the quotes only when they are not typed, and show the key in detail", function()
    local _, _, _, quoted = at('#[derive(Serialize)]\n#[serde(rename_all = "|")]\nstruct A;')
    H.eq("camelCase", quoted.camelCase.insertText)
    local _, _, _, bare = at("#[derive(Serialize)]\n#[serde(rename_all = |)]\nstruct A;")
    H.eq('"camelCase"', bare.camelCase.insertText)
    H.match(bare.camelCase.detail, "rename_all", true)
  end)

  it("a key that needs another sorts after the ones that are ready", function()
    local _, _, _, without = at("#[derive(Serialize)]\n#[serde(|)]\nenum E { A }")
    local _, _, _, withtag = at('#[derive(Serialize)]\n#[serde(tag = "t", |)]\nenum E { A }')
    H.eq("9", without.content.sortText:sub(1, 1), "content before tag")
    H.eq("5", withtag.content.sortText:sub(1, 1), "content after tag")
    H.eq("5", without.tag.sortText:sub(1, 1))
  end)

  it("the positional message of #[error(...)] sorts first and carries a placeholder", function()
    local _, _, _, by = at("#[derive(Error)]\nenum E {\n    #[error(|)]\n    A,\n}")
    H.eq('"${1:message}"', by['"..."'].insertText)
    H.eq("0", by['"..."'].sortText:sub(1, 1))
  end)

  it("derive items show where the derive comes from", function()
    local _, _, _, by = at("#[derive(|)]\nstruct A;")
    H.eq("std", by.Debug.detail)
    if registry_ok then
      H.eq("serde", by.Serialize.detail)
      H.eq("clap", by.Parser.detail)
      H.eq("thiserror", by.Error.detail)
      H.match(by.Parser.documentation.value, "#[arg]", true)
    end
  end)

  it("every shipped schema is valid and every key is unique per attribute and target", function()
    local shipped = ma.shipped()
    H.ok(next(shipped), "schemas loaded")
    H.eq(0, #ma.load_errors, "load errors: " .. vim.inspect(ma.load_errors))
    for _, crate in ipairs({ "serde", "clap", "thiserror", "tokio", "strum", "derive_more", "sqlx", "utoipa", "schemars", "bon" }) do
      H.ok(shipped[crate], "schema for " .. crate)
      H.ok(shipped[crate].docs_url, crate .. " has docs_url")
      H.ok(shipped[crate].versions, crate .. " has versions")
    end
    for crate, file in pairs(shipped) do
      for _, attr in ipairs(file.attributes) do
        local keys = {}
        for _, arg in ipairs(attr.args) do
          H.ok(arg.doc and arg.doc ~= "", ("%s.%s.%s has a doc"):format(crate, attr.name, arg.key))
          if arg.kind == "enum" then
            H.ok(arg.values and #arg.values > 0, ("%s.%s.%s enum without values"):format(crate, attr.name, arg.key))
          end
          local id = arg.key .. "|" .. table.concat(arg.applies_to or {}, ",") .. "|" .. table.concat(arg.derives or {}, ",")
          H.not_ok(keys[id], ("%s.%s: %s defined twice for the same targets"):format(crate, attr.name, arg.key))
          keys[id] = true
          for _, c in ipairs(arg.conflicts or {}) do
            H.ok(type(c) == "string")
          end
        end
      end
    end
  end)

  it("serde schema has every key the task lists", function()
    local want = { "rename", "rename_all", "deny_unknown_fields", "tag", "content", "untagged", "default", "skip", "skip_serializing", "skip_deserializing", "skip_serializing_if", "flatten", "with", "serialize_with", "deserialize_with", "alias", "bound", "transparent", "from", "try_from", "into", "getter", "remote", "borrow" }
    local have = {}
    for _, a in ipairs(ma.shipped().serde.attributes[1].args) do
      have[a.key] = true
    end
    for _, k in ipairs(want) do
      H.ok(have[k], "serde." .. k)
    end
  end)

  it("derive helper attributes in the schemas are declared by the real proc-macro crates (where in the registry)", function()
    if not registry_ok then
      skip("registry sources of serde_derive / clap_derive / thiserror-impl missing")
    end
    local checks = {
      { "serde_derive", "serde", "Serialize" },
      { "clap_derive", "arg", "Parser" },
      { "clap_derive", "command", "Parser" },
      { "clap_derive", "value", "ValueEnum" },
      { "clap_derive", "group", "Args" },
      { "thiserror-impl", "error", "Error" },
      { "thiserror-impl", "from", "Error" },
    }
    for _, c in ipairs(checks) do
      local dir = cm.registry_dir(c[1])
      local found = false
      for _, d in ipairs(dir and vim.fn.glob(dir .. "/src/*.rs", true, true) or {}) do
        local text = assert(io.open(d)):read("*a")
        local s = text:find("proc_macro_derive%s*%(%s*" .. c[3])
        if s then
          local inside = text:sub(s, s + 300)
          found = found or inside:find("%f[%w_]" .. c[2] .. "%f[^%w_]") ~= nil
        end
      end
      H.ok(found, ("%s declares helper %s on %s"):format(c[1], c[2], c[3]))
    end
  end)
end)

-- ------------------------------------------------------------- long files

describe("long files", function()
  it("are read around the cursor only (fast), imports at the top still count", function()
    local lines = { "use thiserror::Error;", "" }
    for i = 1, 2500 do
      vim.list_extend(lines, { "#[derive(Debug)]", ("pub struct S%d {"):format(i), "    pub a: u32,", "}", "" })
    end
    vim.list_extend(lines, { "#[derive(Error)]", "enum E {", "    #[error(", "    A,", "}" })
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, wide() .. "/src/lib.rs")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local t = vim.uv.hrtime()
    local items, info = ma.items(buf, #lines - 2, #"    #[error(")
    local ms = (vim.uv.hrtime() - t) / 1e6
    local labels = vim.tbl_map(function(i)
      return i.label
    end, items)
    has_all(labels, { "transparent", "fmt" }, "thiserror's keys: Error is imported from thiserror in the head of the file")
    has_none(labels, { "source", "ignore" }, "derive_more's keys")
    H.eq("variant", info.target.kind)
    H.ok(ms < 300, ("took %.0f ms for %d lines"):format(ms, #lines))
  end)
end)

-- --------------------------------------------------------------------- semver

describe("version requirements", function()
  local s = ma.satisfies
  it("understands ranges, carets, tildes and partial versions", function()
    H.eq(true, s("1.0.229", ">=1.0.0, <2.0.0"))
    H.eq(false, s("2.0.0", ">=1.0.0, <2.0.0"))
    H.eq(false, s("0.9.9", ">=1.0.0"))
    H.eq(true, s("1.4.2", "^1"))
    H.eq(false, s("2.0.0", "^1"))
    H.eq(true, s("0.3.5", "^0.3"))
    H.eq(false, s("0.4.0", "^0.3"))
    H.eq(true, s("1.2.9", "~1.2"))
    H.eq(false, s("1.3.0", "~1.2"))
    H.eq(true, s("1.2.3", "=1.2"))
    H.eq(false, s("1.3.0", "=1.2"))
    H.eq(true, s("0.27.2", ">0.26.0, <=0.27.2"))
    H.eq(true, s("9.9.9", "*"))
  end)
  it("never hides data because of what it cannot read", function()
    H.eq(true, s(nil, ">=1.0.0"))
    H.eq(true, s("1.0.0", nil))
    H.eq(true, s("not-a-version", ">=1.0.0"))
    H.eq(true, s("1.0.0", ">=banana"))
  end)

  it("keys newer than the resolved version are hidden, the file's range is honoured", function()
    local real = ma.dependencies
    stub(ma, "dependencies", function(path, root)
      local d = real(path, root)
      d.by_name.serde.version = "1.0.100"
      d.by_name.thiserror.version = "2.0.0"
      return d
    end)
    local labels = at("#[derive(Serialize)]\n#[serde(|)]\nenum E { A }")
    has_all(labels, { "tag", "rename_all" }, "old serde")
    has_none(labels, { "rename_all_fields" }, "old serde (rename_all_fields is since 1.0.195)")
    stub(ma, "dependencies", function(path, root)
      local d = real(path, root)
      d.by_name.serde.version = "1.0.200"
      return d
    end)
    has_all(at("#[derive(Serialize)]\n#[serde(|)]\nenum E { A }"), { "rename_all_fields" }, "new serde")
    stub(ma, "dependencies", function(path, root)
      local d = real(path, root)
      d.by_name.serde.version = "2.0.0"
      return d
    end)
    local _, items = at("#[derive(Serialize)]\n#[serde(|)]\nenum E { A }")
    for _, it in ipairs(items) do
      H.not_ok(it.data.macro_attrs == "key", "serde 2.x is outside the schema's range, offered " .. it.label)
    end
  end)
end)

-- ------------------------------------------------------------- dependencies

describe("dependencies", function()
  it("the Cargo.toml scan finds every table form, renames and path dependencies", function()
    local list = ma._manifest_deps([[
[package]
name = "x"

[dependencies]
serde = { version = "1", features = [
  "derive",
] }
my_tokio = { package = "tokio", version = "1" }
local = { path = "../local" }
dotted.workspace = true

[dev-dependencies]
pretty_assertions = "1"

[dependencies.clap]
version = "4"
features = ["derive"]

[target.'cfg(unix)'.dependencies]
libc = "0.2"

[features]
default = []
]])
    local by = {}
    for _, d in ipairs(list) do
      by[d.alias] = d
    end
    H.ok(by.serde and by.my_tokio and by["local"] and by.dotted and by.clap and by.libc and by.pretty_assertions, vim.inspect(list))
    H.eq("tokio", by.my_tokio.name)
    H.eq("../local", by["local"].path)
    H.not_ok(by.features or by.version, "continuation lines are not dependencies")
    H.not_ok(by.default, "[features] is not a dependency table")
    local skip_dev = ma._manifest_deps("[dev-dependencies]\nfoo = \"1\"\n[dependencies]\nbar = \"1\"\n", true)
    H.eq(1, #skip_dev)
    H.eq("bar", skip_dev[1].alias)
  end)

  it("answers at once from the scan when cargo metadata is not cached", function()
    local deps = ma.dependencies(lab() .. "/src/main.rs")
    H.eq("scan", deps.from)
    H.ok(deps.by_name.serde and deps.by_name.clap and deps.by_name.tokio and deps.by_name.thiserror)
    H.not_ok(deps.by_name.sqlx)
  end)

  it("uses real cargo metadata once it is cached (resolved versions)", function()
    for i = #restores, 1, -1 do
      pcall(restores[i])
    end
    restores = {}
    local dir = H.fixture("deps-lab")
    local meta = cm.metadata(dir)
    if not meta then
      skip("cargo metadata of the deps-lab fixture is not available offline")
    end
    local done
    ma.refresh_dependencies(dir, function(ok)
      done = ok
    end)
    H.wait_for(function()
      return done ~= nil
    end, 60000, "metadata refresh")
    local deps = ma.dependencies(dir .. "/src/main.rs")
    H.eq("metadata", deps.from)
    H.match(deps.by_name.serde.version, "^1%.0%.%d+")
    local labels = at("#[derive(Serialize)]\n#[serde(|)]\nenum E { A }", dir)
    has_all(labels, { "tag", "rename_all_fields" }, "with metadata")
    if registry_ok then
      has_all(at("#[derive(|)]\nstruct A;", dir), { "Serialize", "Parser", "Error" }, "derives with metadata")
    end
  end)
end)

-- ------------------------------------------------------ project schemas

describe("project schemas (.xynovim/macro_attrs)", function()
  local function ws(extra_toml)
    local dir = H.tmpdir() .. "/proj"
    write(
      dir .. "/Cargo.toml",
      '[package]\nname = "proj"\nversion = "0.1.0"\nedition = "2024"\n\n[dependencies]\nserde = "1"\n' .. (extra_toml or "")
    )
    write(dir .. "/src/main.rs", "fn main() {}\n")
    return dir
  end

  it("an attribute of the project file replaces the shipped one of the same name, the rest stays", function()
    local dir = ws()
    write(
      dir .. "/.xynovim/macro_attrs/serde.json",
      vim.json.encode({
        crate = "serde",
        attributes = { { name = "serde", derives = { "Serialize" }, applies_to = { "container" }, args = { { key = "my_key", kind = "flag", doc = "mine" } } } },
      })
    )
    local labels = at("#[derive(Serialize)]\n#[serde(|)]\nstruct A;", dir)
    H.eq({ "my_key" }, labels)
    -- another workspace is not affected
    has_all(at("#[derive(Serialize)]\n#[serde(|)]\nstruct A;"), { "rename" }, "lab")
  end)

  it("a project file for another crate is added, with its own derive scope", function()
    local dir = ws('mylib = { path = "../mylib" }\n')
    write(
      dir .. "/.xynovim/macro_attrs/mylib.json",
      vim.json.encode({
        crate = "mylib",
        versions = ">=0.1.0",
        attributes = {
          {
            name = "mine",
            derives = { "Mine" },
            applies_to = { "container", "field" },
            args = {
              { key = "level", kind = "enum", values = { "low", "high" }, quoted = true, doc = "how much" },
              { key = "only_fields", kind = "flag", applies_to = { "field" }, doc = "fields" },
            },
          },
        },
      })
    )
    local labels = at("#[derive(Mine)]\n#[mine(|)]\nstruct A { a: u32 }", dir)
    H.eq({ "level" }, labels)
    has_all(at("#[derive(Mine)]\nstruct A {\n    #[mine(|)]\n    a: u32,\n}", dir), { "level", "only_fields" }, "field")
    H.eq({ "low", "high" }, (at('#[derive(Mine)]\n#[mine(level = "|")]\nstruct A;', dir)))
    H.eq(0, #at("#[mine(|)]\nstruct A;", dir), "derive not present")
  end)

  it("a broken project file is skipped and reported, the shipped schemas keep working", function()
    local dir = ws()
    write(dir .. "/.xynovim/macro_attrs/bad.json", "{ not json")
    write(dir .. "/.xynovim/macro_attrs/worse.json", vim.json.encode({ crate = "x y", attributes = {} }))
    local before = #ma.load_errors
    has_all(at("#[derive(Serialize)]\n#[serde(|)]\nstruct A;", dir), { "rename" }, "shipped")
    H.ok(#ma.load_errors >= before + 2, "problems listed: " .. vim.inspect(ma.load_errors))
    H.match(table.concat(ma.load_errors, "\n"), "bad.json", true)
  end)

  it("a hand-written file may give a string where a list is expected, and a wrong shape is reported, not raised", function()
    local dir = ws()
    write(
      dir .. "/.xynovim/macro_attrs/serde.json",
      [[{"crate": "serde", "attributes": [
        {"name": "serde", "derives": "Serialize", "applies_to": "field", "args": [{"key": "a", "conflicts": "b", "applies_to": "field"}, {"key": "b"}]},
        {"name": "other", "args": "nope"}
      ]}]]
    )
    local labels = at("#[derive(Serialize)]\nstruct A {\n    #[serde(|)]\n    x: u32,\n}", dir)
    H.eq({ "a", "b" }, labels)
    H.eq({}, (at("#[derive(Serialize)]\nstruct A {\n    #[serde(a, |)]\n    x: u32,\n}", dir)), "a conflicts with b (given as a string): both gone")
    write(dir .. "/.xynovim/macro_attrs/serde.json", '{"crate": "serde", "attributes": "oops"}')
    local before = #ma.load_errors
    at("#[derive(Serialize)]\n#[serde(|)]\nstruct A;", dir)
    H.ok(#ma.load_errors > before)
  end)

  it("editing a project file is picked up by the next request", function()
    local dir = ws()
    local path = dir .. "/.xynovim/macro_attrs/serde.json"
    local function put(key)
      write(path, vim.json.encode({ crate = "serde", attributes = { { name = "serde", derives = { "Serialize" }, args = { { key = key, kind = "flag", doc = "d" } } } } }))
    end
    put("first")
    H.eq({ "first" }, (at("#[derive(Serialize)]\n#[serde(|)]\nstruct A;", dir)))
    vim.uv.sleep(1100) -- mtime has a resolution
    put("second")
    H.eq({ "second" }, (at("#[derive(Serialize)]\n#[serde(|)]\nstruct A;", dir)))
  end)
end)

-- ------------------------------------------------------ learn from usage

describe("learn from usage (attributes without a schema)", function()
  --- A workspace using `fancy` (a path proc-macro dependency declaring #[fancy(...)])
  --- and writing the attribute in its own code and in the dependency's examples.
  local function fancy_ws()
    local base = H.tmpdir()
    write(base .. "/fancy/Cargo.toml", '[package]\nname = "fancy"\nversion = "0.1.0"\nedition = "2021"\n\n[lib]\nproc-macro = true\n')
    write(base .. "/fancy/src/lib.rs", '#[proc_macro_derive(Fancy, attributes(fancy))]\npub fn fancy(i: TokenStream) -> TokenStream { i }\n')
    write(base .. "/fancy/examples/e.rs", '#[derive(Fancy)]\n#[fancy(gamma, alpha = 1)]\nstruct E;\n/// #[fancy(gamma)]\n/// #[fancy(gamma)]\n')
    write(base .. "/ws/Cargo.toml", '[package]\nname = "ws"\nversion = "0.1.0"\nedition = "2021"\n\n[dependencies]\nfancy = { path = "../fancy" }\n')
    write(
      base .. "/ws/src/a.rs",
      table.concat({
        '#[derive(Fancy)]\n#[fancy(alpha = 1, beta(x, y))]\nstruct A;',
        '#[derive(Fancy)]\n#[fancy(alpha = "two")]\nstruct B;',
        '#[derive(Fancy)]\n#[fancy(alpha, delta = f(1, 2))]\nstruct C;',
        "",
      }, "\n")
    )
    write(base .. "/ws/src/main.rs", "fn main() {}\n")
    return base .. "/ws"
  end

  it("offers the keys the workspace and the dependency already write, most frequent first", function()
    local dir = fancy_ws()
    local labels, items, info = at("#[derive(Fancy)]\n#[fancy(|)]\nstruct Z;", dir)
    H.eq({ "alpha", "gamma", "beta", "delta" }, labels, "ranking by frequency (workspace counts double)")
    H.eq(false, info.matched, "no schema matched")
    H.match(items[1].detail, "fancy", true)
    H.match(items[1].documentation.value, "3× in this workspace", true)
    H.match(items[1].documentation.value, "learned from usage", true)
    H.eq("learned", items[1].data.macro_attrs)
  end)

  it("keys already written are not offered, and only the helper of a derive in scope is learned", function()
    local dir = fancy_ws()
    local labels = at("#[derive(Fancy)]\n#[fancy(alpha, |)]\nstruct Z;", dir)
    has_none(labels, { "alpha" }, "alpha written")
    has_all(labels, { "gamma", "beta" }, "others")
    H.eq(0, #at("#[fancy(|)]\nstruct Z;", dir), "no derive Fancy on the item")
    H.eq(0, #at("#[derive(Debug)]\n#[fancy(|)]\nstruct Z;", dir), "another derive")
  end)

  it("a typed key does not teach itself (the unsaved attribute is not on disk, but a lone use is ignored)", function()
    local dir = fancy_ws()
    write(dir .. "/src/b.rs", "#[fancy(zzz)]\nstruct Q;\n")
    package.loaded["config.macro_attrs"].learn(dir, "fancy", {}, {}) -- warm path unaffected
    local labels = at("#[derive(Fancy)]\n#[fancy(zzz|)]\nstruct Z;", dir)
    has_none(labels, { "zzz" }, "a key seen once equals the prefix: dropped")
  end)

  it("values are not learned (only keys)", function()
    local dir = fancy_ws()
    H.eq(0, #at('#[derive(Fancy)]\n#[fancy(alpha = "|")]\nstruct Z;', dir))
  end)
end)

-- --------------------------------------------------------- blink source

describe("the blink.cmp source", function()
  it("answers get_completions with the same items, marked incomplete (the answer depends on the text)", function()
    local src = "#[derive(Serialize)]\n#[serde(|)]\nstruct A;"
    local lines = vim.split(src, "\n", { plain = true })
    lines[2] = "#[serde()]"
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, lab() .. "/src/lib.rs")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "#[derive(Serialize)]", "#[serde()]", "struct A;" })
    local source = ma.new({})
    local got
    source:get_completions({ bufnr = buf, cursor = { 2, 8 }, line = "#[serde()]" }, function(r)
      got = r
    end)
    H.ok(got, "callback called")
    H.ok(#got.items > 10)
    H.eq(true, got.is_incomplete_forward)
    local labels = vim.tbl_map(function(i)
      return i.label
    end, got.items)
    has_all(labels, { "rename", "rename_all" }, "source")
    got = nil
    source:get_completions({ bufnr = buf, cursor = { 3, 3 }, line = "struct A;" }, function(r)
      got = r
    end)
    H.eq(0, #got.items, "outside an attribute")
  end)

  it("only claims trigger characters inside an attribute it knows", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    local source = ma.new({})
    --- trigger characters with the cursor at the end of `line`, in insert mode
    local function chars_after(line)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
      local got
      _G.__macro_attrs_trig = function()
        got = source:get_trigger_characters()
      end
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      H.feed("A<Cmd>lua _G.__macro_attrs_trig()<CR><Esc>")
      _G.__macro_attrs_trig = nil
      return got
    end
    H.has(chars_after("#[serde("), "(")
    H.has(chars_after("#[serde("), '"')
    H.eq({}, chars_after("#[cfg("), "rust-analyzer keeps #[cfg(")
    H.eq({}, chars_after("let x = foo("))
    H.has(chars_after("#[derive("), "(")
    H.has(chars_after("#[tokio::main("), "=")
  end)

  it("is registered for Rust buffers next to the default sources, above rust-analyzer's items", function()
    require("lazy").load({ plugins = { "blink.cmp" } })
    local cfg = require("blink.cmp.config")
    local provider = cfg.sources.providers.macro_attrs
    H.ok(provider, "provider macro_attrs")
    H.eq("config.macro_attrs", provider.module)
    H.ok((provider.score_offset or 0) > 50, "score_offset above the lsp source")
    local rust = cfg.sources.per_filetype.rust
    H.has(rust, "macro_attrs")
    H.eq(true, rust.inherit_defaults, "the default sources stay")
  end)

  it("opens the menu while typing inside #[serde( and accepting a key expands its snippet, re-opening the values", function()
    local dir = H.fixture("deps-lab")
    vim.cmd.cd(vim.fn.fnameescape(dir))
    local path = dir .. "/src/lib.rs"
    vim.fn.writefile({ "use serde::Serialize;", "", "#[derive(Serialize)]", "", "struct A {", "    x: u32,", "}" }, path)
    local saved = vim.o.eventignore
    vim.o.eventignore = "FileType" -- no rust-analyzer for this test
    local buf = H.open(path)
    vim.bo[buf].filetype = "rust"
    vim.o.eventignore = saved
    H.feed("A<Esc>") -- loads what hangs off InsertEnter before the typed text
    vim.wait(500)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "use serde::Serialize;", "", "#[derive(Serialize)]", "", "struct A {", "    x: u32,", "}" })
    local list = require("blink.cmp.completion.list")
    local result, err
    _G.__macro_attrs_spec = function()
      local ok, e = pcall(function()
        require("blink.cmp").show()
        H.wait_for(function()
          if not require("blink.cmp").is_visible() then
            return false
          end
          for _, i in ipairs(list.items) do
            if i.label == "rename_all" and i.source_id == "macro_attrs" then
              return true
            end
          end
        end, 8000, "the blink menu with macro_attrs' rename_all")
        local idx
        for i, item in ipairs(list.items) do
          if item.label == "rename_all" and item.source_id == "macro_attrs" then
            idx = i
          end
        end
        require("blink.cmp").accept({ index = idx })
        H.wait_for(function()
          return vim.api.nvim_buf_get_lines(0, 3, 4, false)[1]:find('rename_all = ""', 1, true)
        end, 5000, "the snippet text")
        result = { line = vim.api.nvim_buf_get_lines(0, 3, 4, false)[1], active = vim.snippet.active() }
        -- the menu comes back with the values, inside the quotes
        H.wait_for(function()
          if not require("blink.cmp").is_visible() then
            return false
          end
          for _, i in ipairs(list.items) do
            if i.label == "camelCase" and i.source_id == "macro_attrs" then
              return true
            end
          end
        end, 8000, "the values menu")
        result.values = true
      end)
      if not ok then
        err = e
      end
    end
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    H.feed("i#[serde(<Cmd>lua _G.__macro_attrs_spec()<CR><Esc>")
    _G.__macro_attrs_spec = nil
    pcall(vim.snippet.stop)
    vim.wait(300)
    if err then
      error(err, 0)
    end
    H.eq('#[serde(rename_all = ""', result.line:gsub("%)%]$", ""):gsub("%)$", ""), "inserted text (closers from auto pairs may follow)")
    H.eq(true, result.active, "snippet session")
    H.eq(true, result.values, "values menu")
  end)
end)

-- ------------------------------------------------------- derive accepted

describe("accepting a derive that is not in scope", function()
  local function run_execute(buf_lines, label, data, calls)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, buf_lines)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    stub(ma, "on_derive_accepted", function(name, info)
      calls[#calls + 1] = { name = name, info = info }
    end)
    local source = ma.new({})
    local finished
    local inserted = false
    source:execute({ bufnr = buf }, { label = label, data = data }, function()
      finished = true
    end, function()
      inserted = true
    end)
    H.ok(inserted, "the default insertion ran first")
    vim.wait(300, function()
      return #calls > 0
    end, 10)
    return finished
  end

  local data = { macro_attrs = "derive", crate = "serde", path = "serde::Serialize" }

  it("calls the hook with the name, the expected path and where it was inserted", function()
    local calls = {}
    H.eq(true, run_execute({ "#[derive(Serialize)]", "struct A;" }, "Serialize", data, calls))
    H.eq(1, #calls)
    H.eq("Serialize", calls[1].name)
    H.eq("serde::Serialize", calls[1].info.path)
    H.eq("serde", calls[1].info.crate)
    H.ok(calls[1].info.bufnr and calls[1].info.row and calls[1].info.col)
  end)

  it("does not call it when the name is imported, glob-imported, builtin or qualified", function()
    for _, lines in ipairs({
      { "use serde::Serialize;", "#[derive(Serialize)]", "struct A;" },
      { "use serde::{Deserialize, Serialize};", "#[derive(Serialize)]", "struct A;" },
      { "use serde::*;", "#[derive(Serialize)]", "struct A;" },
    }) do
      local calls = {}
      run_execute(lines, "Serialize", data, calls)
      H.eq(0, #calls, table.concat(lines, " "))
    end
    local calls = {}
    run_execute({ "#[derive(Debug)]" }, "Debug", { macro_attrs = "derive", crate = "std", path = "Debug", builtin = true }, calls)
    H.eq(0, #calls, "builtin")
    run_execute({ "#[derive(serde::Serialize)]" }, "Serialize", { macro_attrs = "derive", crate = "serde", path = "serde::Serialize", qualified = true }, calls)
    H.eq(0, #calls, "qualified")
  end)

  it("a key accepted does not call the hook, an enum key re-opens the menu", function()
    local calls = {}
    run_execute({ "#[serde(" }, "rename", { macro_attrs = "key" }, calls)
    H.eq(0, #calls)
  end)

  describe("the default hook", function()
    local function fake_actions(actions)
      local applied = {}
      stub(ca, "request", function(_, _, _, cb)
        vim.schedule(function()
          cb(actions, nil)
        end)
      end)
      stub(ca, "apply_async", function(a, cb)
        applied[#applied + 1] = a.title
        vim.schedule(function()
          cb(true)
        end)
      end)
      return applied
    end
    local info = { bufnr = 0, row = 1, col = 17, path = "serde::Serialize", crate = "serde" }
    local function action(title)
      return { title = title, kind = "quickfix" }
    end

    it("applies the single import that offers the expected path", function()
      local applied = fake_actions({ action("Import `serde::Serialize`"), action("Import `other::Serialize`"), action("Qualify as `serde::Serialize`") })
      ma.on_derive_accepted("Serialize", info)
      H.wait_for(function()
        return #applied > 0
      end, 2000, "an import applied")
      H.eq({ "Import `serde::Serialize`" }, applied)
    end)

    it("applies the only import when none names the expected path", function()
      local applied = fake_actions({ action("Import `serde::ser::Serialize`") })
      ma.on_derive_accepted("Serialize", info)
      H.wait_for(function()
        return #applied > 0
      end, 2000, "an import applied")
    end)

    it("applies nothing when it is ambiguous", function()
      -- (the import engine counts candidates by path: an `as` alias of the same path is not a second one)
      local applied = fake_actions({ action("Import `a::Serialize`"), action("Import `b::Serialize`") })
      local notes = H.capture_notify()
      ma.on_derive_accepted("Serialize", info)
      vim.wait(500)
      H.eq({}, applied)
      notes.restore()
    end)

    it("asks again while rust-analyzer does not know the name yet", function()
      local calls = 0
      local applied = {}
      stub(ma.config, "import_interval", 20)
      stub(ca, "request", function(_, _, _, cb)
        calls = calls + 1
        vim.schedule(function()
          cb(calls < 3 and {} or { action("Import `serde::Serialize`") }, nil)
        end)
      end)
      stub(ca, "apply_async", function(a, cb)
        applied[#applied + 1] = a.title
        cb(true)
      end)
      ma.on_derive_accepted("Serialize", info)
      H.wait_for(function()
        return #applied > 0
      end, 3000, "the retry to find the action")
      H.eq(3, calls)
    end)
  end)

  it("adds the use line through rust-analyzer's own import action (real rust-analyzer)", function()
    H.need_rust()
    for i = #restores, 1, -1 do
      pcall(restores[i])
    end
    restores = {}
    local dir, buf = H.open_fixture("deps-lab", "src/main.rs")
    local main = vim.fn.readfile(dir .. "/src/main.rs")
    -- a file that derives Serialize without importing it
    local lines = { "#[derive(Serialize)]", "struct Probe { a: u32 }", "", "fn main() {}" }
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.cmd("silent write")
    H.wait_lsp("rust-analyzer", buf, 120000)
    local row, col = 1, #"#[derive(Serialize"
    local done
    ma.on_derive_accepted("Serialize", { bufnr = buf, row = row, col = col, path = "serde::Serialize", crate = "serde" })
    local ok = vim.wait(90000, function()
      for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        if l:match("^use serde::Serialize;") then
          return true
        end
      end
    end, 200)
    H.ok(ok, "a `use serde::Serialize;` line was added: " .. vim.inspect(vim.api.nvim_buf_get_lines(buf, 0, -1, false)))
    done = main -- keep luacheck quiet about the unused read
    H.ok(done)
  end)
end)

-- ------------------------------------------------------------ :MacroAttrs

describe(":MacroAttrs", function()
  it("is registered and reports the attribute, the target and where the dependencies came from", function()
    ma.setup()
    H.eq(2, vim.fn.exists(":MacroAttrs"))
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_name(buf, lab() .. "/src/lib.rs")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "#[derive(Serialize)]", "#[serde()]", "struct A;" })
    vim.api.nvim_win_set_cursor(0, { 2, 8 })
    local notes = H.capture_notify()
    vim.cmd("MacroAttrs")
    local text = vim.inspect(notes.list or notes)
    notes.restore()
    H.match(text, "attribute: serde", true)
    H.match(text, "target: container", true)
    H.match(text, "dependencies: scan", true)
  end)
end)

describe("macro_attrs bounded reads", function()
  it("skips a project schema file over 1 MB and reports it", function()
    local dir = H.tmpdir() .. "/big"
    write(dir .. "/Cargo.toml", '[package]\nname = "big"\nversion = "0.1.0"\nedition = "2024"\n')
    write(dir .. "/src/main.rs", "fn main() {}\n")
    write(dir .. "/.xynovim/macro_attrs/big.json", '{"crate":"big","attributes":[]}' .. string.rep(" ", 1100 * 1024))
    local before = #ma.load_errors
    ma.schemas(dir)
    H.ok(#ma.load_errors >= before + 1, vim.inspect(ma.load_errors))
    H.match(table.concat(ma.load_errors, "\n"), "big.json", true)
  end)
end)
