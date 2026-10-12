# Searchlight

**Keep your search open. Review every match. Replace on your terms.**

Searchlight is a persistent search-and-replace panel for Neovim, powered by ripgrep.
Search a project or your open buffers, narrow the results, and work through individual
occurrences without losing your query. Replacements stay in source buffers for you
to review, undo, and save.

![Searchlight panel with editable fields, grouped Lua results, a selected match, and an excluded occurrence](docs/images/panel.svg)

*Panel illustration generated from actual Neovim results. Open-file and ignored-file
icons are shown as labels for readability; colors depend on your colorscheme.*

[Install](#installation) · [Quick start](#quick-start) · [Features](#features) ·
[Keymaps](#keymaps) · [Configuration](#configuration) · [Benchmarks](#benchmarks)

## Features

| Feature | What you get |
| --- | --- |
| Persistent sessions | Independent panels with their own root, query, filters, options, selection, exclusions, and limits. Hide and reopen them during the same Neovim session. |
| Familiar editing | Edit fields with normal Vim motions, insert mode, and undo. Enter submits; Tab cycles fields. Typing never starts a search. |
| Flexible matching | Literal or ripgrep regex search, case sensitivity, whole words, and configurable surrounding context. |
| Project or buffer scope | Search disk files with modified and newly named unsaved buffers overlaid, or search only listed normal buffers. |
| Precise filters | Include/exclude globs, comma-separated or multiline, with ripgrep ignore rules and an option to include ignored files. Hidden files are included by default. |
| Readable results | Collapsible file groups, line numbers, merged context, occurrence counts, and every match highlighted—even several on one line. |
| Exact navigation | Move between individual occurrences with `n`/`N` or `[`/`]`; open the exact match in a source split with folds opened and the line centered. |
| Native source search | Opening a result sets Neovim's search register and `hlsearch`, so native `n`/`N` continue through that file. |
| Selective replacement | Exclude individual occurrences, replace one match or all enabled matches, and expand numbered or named regex captures. |
| Reviewable edits | Replacements remain unsaved, use a native undo block per source buffer, validate searched snapshots, and report skipped or failed edits. |
| Syntax highlighting | Use installed Tree-sitter parsers and your colorscheme for result code. Optional embedded-language highlighting; readable plain-text fallback. |
| Bounded asynchronous work | Cancellable searches, batched disk prefiltering, configurable resource limits, and a shared bounded syntax cache. Incomplete results block Replace all. |
| Neovim integration | Listed panel buffers, commands, buffer-local actions, existing mapping preservation, and normal split resizing and scroll margins. No required Lua plugin dependencies. |

## Installation

### Requirements

| Dependency | Required? | Details |
| --- | --- | --- |
| [Neovim](https://neovim.io/doc/install/) 0.12+ | Yes | Locally tested with 0.12.6. `setup()` checks the required Neovim APIs. |
| [ripgrep (`rg`)](https://github.com/BurntSushi/ripgrep#installation) on `$PATH` | Yes | Tested with 15.2.0. Replacement requires JSON capture-expansion support, which Searchlight probes automatically. Older builds can search but have replacement disabled if that capability is missing. |
| Tree-sitter parsers and highlight queries | Optional | Used for result syntax colors when installed. Searchlight does not install parsers or start LSP clients. |
| Nerd Font | Optional | Renders the two search-control icons. Their mappings and the `?` help remain usable without it. |

Check your executables with `nvim --version` and `rg --version`. There is no plugin
build step and no required Telescope, Plenary, or Tree-sitter plugin dependency.

### lazy.nvim

Add this specification to your [lazy.nvim](https://lazy.folke.io/spec) plugin list:

```lua
{
  'dmytr0x/searchlight',
  lazy = false,
  main = 'searchlight',
  opts = {},
}
```

This runs `require('searchlight').setup()` at startup and registers the commands and
default global mappings. For command-only lazy loading, replace `lazy = false` with
`cmd = { 'SearchlightNew', 'SearchlightFocus', 'SearchlightClose' }`; the default
global mappings are registered after the plugin loads.

### Other plugin managers or a local checkout

Install `dmytr0x/searchlight` with your plugin manager, then call this after it loads:

```lua
require('searchlight').setup()
```

To try a checkout directly:

```sh
git clone https://github.com/dmytr0x/searchlight.git ~/searchlight
```

```lua
vim.opt.runtimepath:prepend(vim.fn.expand('~/searchlight'))
require('searchlight').setup()
```

For a local lazy.nvim specification, replace `'dmytr0x/searchlight'` with
`dir = vim.fn.expand('~/searchlight')`. The repository root is the plugin runtime
directory.

## Quick start

1. Run `:SearchlightNew` in your project, or `:SearchlightNew /path/to/project`.
2. Enter your query on the line below **Search** and press Enter in normal or insert
   mode. The default search is case-insensitive and literal, with two context lines.
3. Use `n`/`N` to visit occurrences. Press Enter on a match to open its source; use
   `:SearchlightFocus` to return to the panel. Enter on a file header collapses it.
4. Narrow the search with **Include** (for example, `*.lua, *.md`) and **Exclude**
   (for example, `vendor/**`), then press Enter in a field to refresh.
5. To replace, enter a value below **Replace** and press Enter to refresh replacement
   values. Use Space on a match to exclude it, `<localleader>n` to replace the
   selected enabled occurrence, or `<localleader>A` to replace all enabled matches.
6. Review the changed source buffers. Use `u` or Ctrl-r there to undo or redo, then
   `:write` or `:wall` when ready to save.

`<localleader>` defaults to `\`, so Replace all is `\A` unless you configured a
different local leader. Set `vim.g.maplocalleader = ','` **before opening a panel**
if you prefer `,A`. Press `?` in the panel for help.

**Searches are explicit.** Editing fields or source files marks results stale;
press Enter in an input line or `<localleader>R` in normal mode to refresh.
Option-toggle mappings and Lua `set()` updates schedule a debounced search.
Enter in Replace refreshes values; replacement is a separate action.

### A regex replacement example

Enable Regex with `<localleader>x`, use Include `*.lua`, and enter these fields:

```text
[Search]
config\.(\w+)
[Replace]
settings.$1
```

After refreshing, the replacements are:

```diff
-config.timeout = 1000
-config.retries = 3
+settings.timeout = 1000
+settings.retries = 3
```

`$1` and `${name}` expand captures; `$$` inserts a literal dollar sign.
An empty replacement deletes the matched bytes. Capture expansion is available in
each occurrence's replacement value and through the [Lua preview API](#lua-api);
the panel has no additional before/after preview row.

## Panel and session behavior

Each source line appears once, even when it contains several matches. Matches are
highlighted individually; the selected occurrence has a distinct highlight, and
excluded occurrences are dimmed. Move onto a highlight to open, exclude, or replace
that occurrence. From the gutter, actions use the selected occurrence on that line,
or its first match.

```text
[Results]  3/7
▾ client.lua  lua/
  ○   1 | local config = require("config")
      2 |
      3 | local function connect()
> ●   4 |   return config.timeout
      5 | end

▾ config.lua  lua/
  ○   1 | local config = {}
      2 |
  ○   3 | config.timeout = 1000
  ○   4 | config.retries = 3
      5 |
  ○   6 | return config
```

The header counts **occurrences**, not lines. `○` marks a match line; `●` marks the
cursor's match line, including stale or excluded results. A `⋯` row separates distant
context blocks. Context rows do not count as matches or replacement targets.
File collapse state survives refreshes, and navigation expands the selected file.

Panels open at the top of the tab. An untouched empty startup window is reused;
existing editor windows and split layouts are preserved. Every source jump creates
a new horizontal split below the panels, opens the exact occurrence, unfolds it,
and centers it with `zz`. Source windows inherit the editor's pre-panel options and
normal filetype/autocommand behavior.

Sessions survive hiding or ordinary window closure within the running Neovim
instance. Their listed buffer names include the query (`searchlight://ID/term`) for
buffer pickers and `:ls`. `:SearchlightFocus` restores a panel at the top; selecting
its buffer also restores it. `:bdelete`, `:bwipeout`, or `:SearchlightClose` dispose
the session. Repeating `setup()` preserves surviving sessions.

Resize and scroll normally. Long lines do not wrap; horizontal scrolling,
`scrolloff`, and `sidescrolloff` work, including window-local overrides.
Hiding Replace or filters preserves their active values; the panel shows a reminder
when hidden fields affect the search.

## Commands

| Command | Default global mapping | Action |
| --- | --- | --- |
| `:SearchlightNew [root]` | `<leader>sp` | Create a new independent panel. |
| `:SearchlightFocus [id]` | `<leader>sP` | Focus a requested session or the most recently used surviving one. |
| `:SearchlightClose` | — | Delete the current panel and dispose its session. |

The root defaults to the invoking window's current directory and remains captured
after `:cd`. Escape spaces in command arguments. Existing conflicting global
mappings are preserved. For your own shortcut:

```lua
vim.keymap.set('n', '<leader>sf', function()
  require('searchlight').new()
end, { desc = 'Searchlight: new search' })
```

## Keymaps

Panel mappings are buffer-local. Unless noted, use normal mode; ordinary editing
keys such as `d`, `w`, `x`, `c`, `r`, `o`, and `O` remain available in fields.

| Key | Action |
| --- | --- |
| `<localleader>/`, `<localleader>r` | Focus Search / Replace. |
| `<localleader>I`, `<localleader>E` | Focus Include / Exclude. |
| Tab | Cycle fields (normal and insert mode). |
| Enter | Refresh in a field or on the controls (normal and insert mode); open a result or collapse/expand a file header (normal mode). |
| `n`, `N` | Next / previous occurrence; counts such as `3n` work, wrapping follows `wrapscan`. |
| `[`, `]` | Previous / next occurrence; stop at either end. |
| Space | Enable/exclude the occurrence under the cursor, otherwise the selected occurrence. |
| `<localleader>n`, `<localleader>A` | Replace the selected enabled occurrence / all enabled occurrences. |
| `<localleader>R` | Refresh using the current query, replacement, options, and filters. |
| `<localleader>c` | Toggle Match case (`Aa`). |
| `<localleader>w` | Toggle Whole words (`wd`). |
| `<localleader>x` | Toggle Regex (`.*`). |
| `<localleader>o` | Toggle Only open files (`󰥩`). |
| `<localleader>g` | Toggle Also ignored (``). |
| `<localleader>f`, `<localleader>v` | Hide/show filters / Replace; values remain active. |
| `<localleader>d`, `<localleader>L` | Change the session root / match limit and schedule or run a refresh. |
| `<localleader>q`, `<localleader>D` | Hide / delete the session. |
| `?` | Show/hide help. |

You can also edit the Search header's brackets directly. `[x]` enables a modifier;
`[]` or spaces-only brackets disable it. Any non-space character enables it;
malformed brackets disable it. Edit `↕[2]` to change context lines above and below
matches; `0` hides context. Invalid or unfinished context values keep the last valid
size. Direct edits and undo preserve your text and wait for explicit refresh.

## Matching and scope

- **Defaults:** case-insensitive, literal, whole words off, project scope, ignored
  files off, hidden files on. Empty queries remain idle; one-character queries work.
- **Patterns:** panel regexes use ripgrep's default engine and syntax, without
  implicit PCRE2 or Vim-pattern translation. Search and replacement accept one
  logical line each.
- **Filters:** use positive globs in both fields, without a leading `!`. Includes
  form a union; exclusions win. Separate globs with commas or newlines. Brace
  alternatives (`*.{lua,md}`), character classes (`file[,.]txt`), and escaped commas
  (`notes\,draft.md`) are preserved. Whitespace and blank declarations are ignored
  when interpreting filters; editable text is retained exactly.
- **Project scope:** disk search includes modified and newly named unsaved buffers
  without duplicate disk hits. A clean buffer that differs from disk is searched
  from disk; replacement is blocked until the buffer agrees with that snapshot.
- **Only open files:** search current contents of listed normal buffers within the
  root, loading listed unloaded buffers as needed. Special buffers (panels,
  terminals, help, and similar) are excluded.
- **Hidden and ignored files:** hidden paths such as `.config/nvim/` are searched by
  default, subject to filters and ignore rules. Also ignored bypasses normal ignores
  and ripgrep config with `--no-config --no-ignore --hidden`. `.git` metadata is
  always excluded.
- **File identity:** real paths must stay within the root. Symlink and hard-link
  identities are deduplicated; current buffers take precedence for shared sources.
  Symlink traversal follows ripgrep's configured `--follow` policy.
- **Unsaved file eligibility:** new filenames are evaluated with real ripgrep glob
  and ignore behavior in a disposable tree, including ancestor ignore files and
  Git excludes. Searchlight creates no placeholder files in your project.

With Also ignored off, `RIPGREP_CONFIG_PATH` is checked before discovery. Supported
configuration includes long `--glob=`, `--iglob=`, type-filter flags, absolute
`--ignore-file=`, hidden/ignore/follow controls, and max-column/preview/no-heading
settings. Searchlight controls the matching flags itself. Unsupported flags, short
forms, relative ignore-file paths, or incompatible engine/output settings produce
a visible error. See the [accepted flags](lua/searchlight/rg.lua).

Opening a result sets Vim's search register and enables `hlsearch`. In the source,
native `n`/`N` support counts, follow `wrapscan`, include excluded occurrences, and
can reach beyond the panel's result cap. `:nohlsearch` clears native highlights;
a new `/` or `?` search takes over without clearing the panel's highlights.
Source navigation uses Vim regex syntax and the buffer's `iskeyword`, so regex and
whole-word navigation can differ from ripgrep's panel matches.

## Replacement and limits

Searchlight validates the searched snapshot, full buffer contents, changedtick,
pathname, write options, and disk contents/identity before applying edits, including
after source-loading autocommands. Changed, deleted, renamed, or unsupported sources
are skipped with reasons. Reports show applied, excluded, stale, unsupported, and
failed counts, including partial failures. Editing displayed result rows never edits
source files.

Replace next edits one enabled occurrence and advances to its surviving successor,
skipping exclusions and avoiding immediate revisits to inserted text. Replace all
needs a settled, current, complete, uncapped search. A match, inventory, output,
source-size, or snapshot-memory limit is visible and blocks full-scope replacement;
settled displayed matches may still be used by Replace next. Raise the relevant
limit and refresh. `<localleader>L` changes the current session's match limit.

After replacement, the applying panel refreshes; other affected sessions become
stale until explicitly refreshed. Source edits, undo/redo, writes, listing changes,
and renames also invalidate relevant sessions without searching. Unchanged snapshots
retain exclusions; a changed snapshot resets its old exclusions.

**Edits stay unsaved.** Each operation creates one native undo block per source
buffer, separate from prior edits; undo is per file, without a cross-file atomic
undo. CRLF, UTF-8/UTF-16 BOM, Latin-1, and missing-final-newline handling are covered
by save-and-byte-comparison tests. Newly loaded sources without a final newline
receive `nofixendofline`; existing buffers retain their write options. Binary sources
are omitted, and unsafe encoding/newline mappings are visibly skipped.

## Configuration

All available settings and their defaults:

```lua
require('searchlight').setup({
  -- Search defaults for new sessions
  match_case_sensetivity = false, -- use this exact API spelling
  match_whole_words = false,
  use_regular_expressions = false,
  only_search_open_files = false,
  also_search_ignored_files = false,
  context_size = 2,

  -- Result syntax colors
  syntax_highlighting = true,
  syntax_injections = false,
  syntax_max_file_bytes = 128 * 1024,

  -- Scheduling and per-session limits
  debounce_ms = 150, -- Lua set() and toggle mappings; Enter is immediate
  max_results = 10000,
  concurrency = 4,
  max_files = 100000,
  max_output_bytes = 4 * 1024 * 1024,
  max_source_bytes = 8 * 1024 * 1024,
  max_snapshot_bytes = 64 * 1024 * 1024,
})
```

The case option is spelled **`match_case_sensetivity`** in the current API.
For case-sensitive regex searches by default, set it and
`use_regular_expressions` to `true`. Boolean settings require booleans;
`context_size` is a nonnegative integer. Other numbers are positive integers,
except `debounce_ms`, which can be zero. Unknown settings are rejected.
Existing sessions keep their captured configuration when `setup()` runs again.

### Syntax colors and highlight groups

Plain results appear first; visible code receives syntax colors after a short
debounce. Missing parsers/queries, errors, oversized files, or exhausted budgets
leave readable plain text. Search highlights and selected/excluded styling take
priority. Set `syntax_highlighting = false` to disable syntax for new sessions.

Files above `syntax_max_file_bytes` stay plain. Raising the default 128 KiB cap can
increase uninterrupted parse pauses; a shared hard cap of 512 KiB still applies.
The global cache bounds parsers, source text, spans, and visible-row work across
panels. Long source lines over 4 KiB are not enriched. Cooperative capture
extraction and bounded retries keep background work controlled; these bounds do
not guarantee a fixed process RSS.

Set `syntax_injections = true` to color visible embedded languages, such as Markdown
code fences. Injections are one level deep and share the syntax budgets.
Colorscheme, filetype, and runtimepath changes update colors without rerunning
searches. After replacing highlight queries explicitly, call
`require('searchlight.highlight').reload()` or
`:doautocmd User SearchlightHighlightReload`.

| Group | Default | Purpose |
| --- | --- | --- |
| `SearchlightMatch` | Follows `Search` | Result matches. |
| `SearchlightSelected` | Follows `IncSearch` | Selected occurrence. |
| `SearchlightFilename` | Yellow (`#ffff00`) | File header name and extension. |
| `SearchlightPath` | White (`#ffffff`) | File header's relative directory. |
| `SearchlightControl` | Links to `Title` | Search controls. |
| `SearchlightMarker` | Links to `DiagnosticOk` | Result circle markers. |

The last four groups use default definitions and respect your colorscheme/config
overrides. `SearchlightMatch` and `SearchlightSelected` always follow `Search` and
`IncSearch`.

## Lua API

Use a session object returned by `new()`, or its numeric ID. For example:

```lua
local searchlight = require('searchlight')
local session = searchlight.new(vim.fn.getcwd())

searchlight.set(session, {
  query = 'config',
  replacement = 'settings',
  include = { '*.lua', '*.md' },
  exclude = { 'vendor/**' },
  case = false,
  word = true,
  regex = false,
  open = false,
  ignored = false,
  context = 1,
})
searchlight.refresh(session) -- submit immediately instead of waiting for debounce
```

`set()` also accepts `root`. Filter values are lists of single-line strings, each
of which can contain comma-separated globs. `setup()` option names and per-session
`set()` option names differ, as shown above.

| Function | Purpose |
| --- | --- |
| `setup(options)` | Configure defaults and register commands, mappings, and events. |
| `new(root)` | Create, focus, and return a session. Root is optional. |
| `focus(id)` | Focus and return a session; no ID restores the last surviving panel. |
| `set(session, changes)` | Update fields, options, or root and debounce a search. |
| `refresh(session)` | Search immediately with the current inputs. |
| `navigate(session, delta)` | Move the selection by an occurrence offset. |
| `open(session)` | Open the selected source occurrence. |
| `action(session, name, arg)` | Invoke a panel action, such as `exclude`, `replace_next`, or `replace_all`. |
| `close(session)` | Dispose a session and delete its panel. |

For capture-aware previews after results settle:

```lua
local replace = require('searchlight.replace')
local occurrence = replace.selected(session)
local preview_line = replace.preview(occurrence)
```

`preview()` returns the source match line with that occurrence replaced, or `nil`
when the occurrence is missing, stale, or lacks replacement support.

## Benchmarks

Measurements from **2026-10-12**, on **macOS 26.6.2 / arm64**, with **Neovim 0.12.6**
and **ripgrep 15.2.0**. These are local synthetic, headless runs; timings depend on
hardware, filesystem, parsers, and workload, and do not measure terminal rendering.

### Search workloads

One `make benchmark` run, using the default 10,000-occurrence cap:

| Workload | Measured result |
| --- | --- |
| 200 files, 20,000 occurrences | First results **25.94 ms**; capped search settled in **300.60 ms**, displaying 10,000 occurrences. |
| Same workload, event-loop responsiveness | 26 heartbeat callbacks; longest observed gap **15.98 ms** with a 10 ms timer. |
| 2,000 files, no matches | Complete in **67.64 ms**, using **4 ripgrep processes**. |
| Single `rg --json` on the no-match fixture | **22.48 ms** for context; this command does not include Searchlight's inventory, snapshot, and panel work. |

The benchmark checks that the event loop keeps running, capped results reject
Replace all, and no-hit searches avoid launching a process per file.

### Syntax highlighting overhead

`make syntax-benchmark` alternates fresh enabled/disabled processes for three trials
each. The enabled workload includes **syntax injections**, which are off by default.
Fixtures exercise dense/sparse Lua and C, large and long-line files, embedded
languages, scrolling, replacement, and 100 panel lifecycle cycles.

| Metric | Syntax off | Syntax + injections on |
| --- | ---: | ---: |
| First results, median | 14.56 ms | 15.99 ms |
| Warm navigation, p95 | 0.058 ms | 0.107 ms |
| Cached drawing, p95 | 0.088 ms | 0.254 ms |
| Syntax-worker heartbeat gap, p95 | 0.036 ms | 1.475 ms |
| Longest syntax-worker heartbeat gap | 0.144 ms | 15.889 ms |
| Kernel peak process RSS, median | 139.44 MiB | 151.22 MiB |

All six gates passed: first-results overhead, warm-navigation overhead, baseline
navigation, cached-drawing overhead, heartbeat responsiveness, and RSS overhead.
RSS includes the whole Neovim process, parsers, and benchmark workload.
See the [search benchmark](tests/nvim/benchmark.lua) and
[syntax benchmark gates](tests/nvim/syntax_benchmark.py) for methodology and thresholds.

Reproduce from a checkout:

```sh
make benchmark
make syntax-benchmark # also needs Python 3 and /usr/bin/time (GNU time on Linux)
```

The syntax runner prints summary measurements and writes a full JSON report to
`/tmp/searchlight-syntax-benchmark.json` by default. Set `SEARCHLIGHT_BENCH_TRIALS`
or `SEARCHLIGHT_BENCH_REPORT` to change the trial count or output path.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| `:SearchlightNew` is unavailable | Ensure the plugin has loaded and `setup()` has run. With command lazy loading, use a command to load it first. |
| ripgrep is not installed | Check `:echo executable('rg')`; it must return `1` in Neovim's environment. |
| Replacement is disabled | Check the panel message and `rg --version`. Install a build with JSON replacement/capture support; 15.2.0 is tested. |
| Results did not change after editing | Refresh with Enter in a field or `<localleader>R`; typing does not launch a search. |
| Replace all is blocked | Wait for the search to settle, refresh stale results, or increase the reported limit and refresh. |
| A hidden file is missing | Check Include/Exclude and ignore rules. Hidden files are already enabled; Also ignored includes ignored paths. `.git` stays excluded. |
| ripgrep config is rejected | Use the supported long flags described above, or enable Also ignored to bypass config and ignore rules. |
| Missing result syntax colors | Check installed parsers/queries and file-size limits. Plain-text results remain usable. |
| Control icons appear as boxes | Use a Nerd Font or the toggle mappings; `?` explains every control. |

## Development

```sh
make test
make benchmark
make syntax-benchmark
make format-check # requires StyLua; CI uses 2.5.2
```

Tests isolate Neovim/XDG/log state and use real filesystem fixtures, real ripgrep,
and an injected process driver for deterministic asynchronous failures. They require
ripgrep's expanded JSON replacements. Files ending in `_spec.lua` are discovered
automatically. The local suite passed **239/239 tests** for the measurements above.

[CI](.github/workflows/test.yml) runs tests and search benchmarks on Neovim stable
and nightly on Linux and macOS, checks formatting, and runs the syntax benchmark
on Linux.

```text
lua/searchlight/  Plugin modules and public init.lua facade
tests/nvim/      Isolated test configuration, fixtures, assertions, and benchmarks
tests/prototype/ Backend evaluation adapter
```

The public facade coordinates sessions and actions; scope/source modules own
eligibility, snapshots, and edit validation. Results and view modules own occurrence
selection and panel layout, while the highlight module owns the shared syntax cache.
`process.start(argv, opts, done)` is the replaceable process boundary for tests.

For bugs or feature requests, [open an issue](https://github.com/dmytr0x/searchlight/issues)
with your Neovim/ripgrep versions, relevant configuration, and a minimal reproduction.
