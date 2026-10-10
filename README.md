# Searchlight

A persistent, editable Neovim search panel with independent sessions, ripgrep controls,
unsaved-buffer search, per-occurrence exclusions, capture previews, and undoable replacement.
Edits stay in source buffers until you save them.

## Installation

The repository root is the plugin runtime directory. Lua modules live in
`lua/searchlight/`; install this repository with your plugin manager and configure it
from your Neovim configuration:

```lua
require('searchlight').setup()
```

For a local checkout with lazy.nvim, add this plugin specification (adjust `dir` to
your checkout):

```lua
{
  dir = vim.fn.expand('~/path/to/nvim-search'),
  main = 'searchlight',
  opts = {},
}
```

Alternatively, load a local checkout directly before calling `setup()`:

```lua
vim.opt.runtimepath:prepend(vim.fn.expand('~/path/to/nvim-search'))
require('searchlight').setup()
```

`setup()` registers the commands, mappings, and event handlers. Repeating it preserves
existing sessions. Neovim capabilities and ripgrep JSON replacement support are
probed; tested versions are Neovim 0.12.6 and ripgrep 15.2.0. Older ripgrep can search,
but replacement stays disabled if capture expansion is unavailable.

The project layout is:

```text
lua/searchlight/  Plugin modules and public init.lua
tests/nvim/       Isolated test configuration, assertions, and benchmarks
tests/prototype/  Backend evaluation adapter
docs/             Design and validation reports
```

## Commands and workflow

| Command / mapping | Action |
| --- | --- |
| `:SearchlightNew [root]` / `<leader>sp` | Create a uniquely named, listed panel in a horizontal split at the top |
| `:SearchlightFocus [id]` / `<leader>sP` | Restore the requested or most recently used surviving panel |
| `:SearchlightClose` | Delete the current panel and dispose its session |

The root defaults to the invoking window's current directory and stays captured even
after `:cd`. Escaped spaces work in command arguments. Ordinary window closure hides
the panel; `:buffer searchlight://ID` also restores it. `:bdelete` and `:bwipeout`
end its session. Existing global mappings with conflicting keys are preserved.

If the tab has only an untouched, empty unnamed editor window, search uses that
window directly. Opening a result then leaves just the search panel and source file.
Existing files, unsaved buffers, and split layouts keep their windows.

Type in the lines below Search, Replace, Include, and Exclude using normal Vim editing.
Typing in the panel or a source file never launches a search. Press Enter in an input
line (normal or insert mode) to search with the current fields, options, and filters.
Enter in Replace refreshes capture/replacement previews; use Replace next or Replace
all to apply them. Source edits mark affected results stale until you explicitly refresh.
Tab cycles fields in normal and insert mode. Filter lines accept comma-separated ripgrep
globs, such as `*.md, *.py, *project*/**/*.lua`, and can span multiple lines.
Use normal-mode `o`/`O` to add filter lines; Enter submits the input.
Include and Exclude preserve your text exactly, including leading/trailing spaces,
tabs, blank lines, and unfinished patterns, through refreshes and hiding/showing filters.
Whitespace trimming and empty-declaration handling apply only when interpreting globs
for a search; they never rewrite the editable lines.
The results header shows the current occurrence and total count, such as
`[Results]  1/27` (`0/0` for no matches). `?` opens visible help. Resize the split
normally; long rows can be inspected with normal horizontal scrolling.
The panel respects `vim.opt.scrolloff` and `vim.opt.sidescrolloff`, including
window-local overrides; no separate plugin settings are needed.
As in normal Neovim buffers, vertical margins shrink near the first and last
buffer lines, and the left margin shrinks near the start of a line.

Results are grouped by file, with the filename and its directory shown once in a
highlighted header. Matches and context appear as numbered code lines beneath it:

```text
▾ actions.lua  lua/searchlight/
      132 |   close(s)
> ●   133 |   default = s.root
      134 |   update(s)
      ⋯
  ○   141 |   default = tostring(limit)

▾ init.lua  lua/searchlight/
  ○   118 |   local default = config[key]
```

Each source line appears once, including lines with several matches. All occurrences
are highlighted; the selected occurrence uses a distinct highlight. `n` and `N` move
forward and backward between individual occurrences, support counts such as `3n`,
and wrap when `wrapscan` is enabled. `[` and `]` also move between occurrences and
stop at either end. These keys place the cursor on the exact match. Move onto a
highlight to open, exclude, or replace that occurrence. From the line-number gutter,
actions use the selected occurrence on that line, or its first match.
Match lines always use green `○`; the cursor line uses green `●`, including excluded
and stale results. Excluded occurrences are dimmed. A `⋯` row separates distant
context blocks inside the same file group.

Press Enter on a file header to collapse or expand its code. Collapse state survives
refresh and does not change exclusions or replacement scope. Navigating to an
occurrence automatically expands its file.

Opening an occurrence creates a new horizontal split below the search panels each
time, keeping earlier source views open. Search stays at the top; focusing a hidden
panel restores it at the top. Each jump stays in the search panel's tab.
After placing the cursor on the exact occurrence and opening any enclosing folds,
each jump runs `zz` to center the matched line vertically in the source window.
Source windows inherit the editor settings from before the panel was opened,
including line numbers, wrapping, signs, and folds. Files open through `:edit`,
so normal filetype settings and autocommands apply.

Opening an occurrence also highlights that session's matches in the source
file. Native `n` / `N` (Shift+n) move forward / backward within that file, including
excluded occurrences, with counts and `wrapscan` support. This sets Vim's search
register and enables `hlsearch`; `:nohlsearch` clears the highlighting, and a new
`/` or `?` search takes over normally. Every jump rebuilds a compact
pattern such as `\c\VAction` (or `\C\VAction` with Match Case), keeping the search
display readable and following source edits naturally. Whole Words adds Vim word
boundaries (`\<` / `\>`), and Regex uses Vim's very-magic mode (`\v`). Source
navigation therefore uses Vim's regex syntax and the buffer's `iskeyword` word
boundaries, which can differ from ripgrep's panel results. The pattern always uses
the current search term and controls, even when results are stale or capped; `n`
and `N` can reach matches beyond the panel's result cap.

Searching with `/` in a source buffer or clearing native search highlighting leaves
the panel's last searched term highlighted. Stale results retain their match colors
and selected highlight and circle markers. Refresh stale results before replacement.

The input block groups controls with Search. Empty fields start with one editable
line; add more lines with normal Vim editing:

```text
[Search]    Aa[ ]  wd[ ]  .*[ ]  󰥩[ ]  [ ]  ↕[2]
search terms
[Replace]
replacement terms
[Include]
*.md, *.py, *project*/**/*.lua
[Exclude]
generated/**, vendor/**
```

`Aa` toggles case sensitivity, `wd` whole words, `.*` regular expressions,
`󰥩` only open files, and `` ignored files. `↕[2]` sets the number of context lines
above and below each matched line. Edit its number with normal Vim editing; `0` shows
only matches. Each search passes the value to ripgrep as `--context=N`, including searches
of unsaved buffers. Overlapping context is shown once per file; context rows have line
numbers and do not count as matches or replacement targets. Empty, incomplete, negative,
or otherwise invalid context values preserve the last valid size and your typed text.
Changing the effective size marks only that session stale; press Enter in an input line
or on the controls to refresh. Native undo also restores the size. Context stays available
when Replace or filters are hidden.
Hidden files are searched by default.
`[x]` means enabled;
`[]` and `[ ]` both mean disabled. With `Aa[x]`, `search` matches lowercase `search`
but excludes `Search` and `SEARCH`. Case applies to the matched text; a line such as
`# Persistent search panel` still matches. Edit any modifier's brackets with normal
Vim editing: a modifier is enabled only when its brackets contain at least one character
other than an ASCII space. Empty brackets (`[]`) and spaces-only values (`[ ]`, `[   ]`)
disable it. Missing or malformed brackets disable that modifier. The panel
preserves exactly what you type, including incomplete brackets. Changing any option's
enabled state by editing or undo marks only that session stale. Press Enter in an input
line or on the controls to refresh. Toggle mappings explicitly change the option and
schedule a refresh. Pending searches are cancelled and their late output is ignored.
Empty queries stay idle.
Every search reads the current brackets. All five
modifiers stay available when Replace or filters are hidden. The two icons use a Nerd
Font. You can also toggle with the local-leader mappings below; `?` shows the legend
and shortcuts inside the panel.
Hide Replace with `<localleader>v` for the Search / Include / Exclude layout.
The compact results header follows the input block; active hidden values, search
messages, and replacement reports are shown there when needed.

For example, enable `.*`, enter `a(b)c` in Search and `$1!` in Replace, enter `*.lua, *.txt`
in Include, and enter `generated/**` in Exclude. Review the individual
matches with `[` and `]`, open one with Enter, return with Focus Search, use Space to
exclude a result, then apply enabled matches with `<localleader>A`.

## Panel mappings

`<localleader>` is your existing local leader (Neovim defaults to `\`; the test/demo
configuration uses `,`). Actions are buffer-local. Vim's `d`, `w`, `x`, `c`, `r`, and
other native editing keys remain available in fields.

| Key | Action |
| --- | --- |
| `<localleader>/`, `<localleader>r`, `<localleader>I`, `<localleader>E` | Focus Search, Replace, Include, Exclude respectively |
| `<localleader>c` | Toggle Match case |
| `<localleader>w` | Toggle Whole word |
| `<localleader>x` | Toggle Regex / literal |
| `<localleader>o` | Toggle Only open files |
| `<localleader>g` | Toggle Also ignored |
| `<localleader>f`, `<localleader>v` | Hide/show filters or replacement; values remain active |
| `<localleader>d` | Edit the session root |
| `<localleader>L` | Change the match limit and refresh |
| `[`, `]` | Previous / next individual occurrence; stop at either end |
| `n`, `N` | Next / previous individual occurrence; counts supported, wrapping follows `wrapscan` |
| Enter | In an input line or on the controls, refresh search/previews; on results, open the occurrence; on a file header, collapse/expand |
| Space | Enable/exclude the occurrence under the cursor, otherwise the selected one |
| `<localleader>n`, `<localleader>A` | Replace next / Replace all |
| `<localleader>R` | Rerun the current search term with the current options and filters |
| `<localleader>q`, `<localleader>D` | Hide / delete the session |
| `?`, Tab | Help / next field |

To refresh results after files change, focus the panel and press `<localleader>R`
in normal mode (`\R` with Neovim's default local leader, or `,R` in the test/demo
configuration). This immediately reruns that session's search, reading the current
fields and modifier brackets without requiring you to edit the search term.
Enter in an input line does the same.

## Matching and scope

All five modifiers default to OFF: case insensitive, literal matching, whole word off,
project scope, and ignored files off. Explicit input submission starts immediately;
Programmatic `set()` updates and toggle mappings use a 150 ms default debounce.
Empty queries remain idle; one-character queries work.
Regex uses ripgrep's default syntax, with no implicit PCRE2 or Vim-pattern translation.
Search and replacement each accept one logical line. `$1` and `${name}` expand captures;
`$$` is a literal dollar. An empty replacement deletes the selected bytes.

Includes form a union. Exclusions win over includes. Supply positive patterns in each
field, without a leading `!`; the Exclude field adds negation itself. Separate declarations
with commas or newlines; surrounding whitespace and empty declarations are ignored.
Commas inside brace alternatives (`*.{md,py}`), character classes (`file[,.]txt`),
or escaped with a backslash (`notes\,draft.md`) remain part of the glob.
Disk discovery
uses ripgrep's glob and ignore policy. Listed normal buffers are eligible sources;
panel, terminal, help, and other special buffers are excluded. Only-open scope searches
current memory, including listed unloaded buffers after loading them. Project scope
overlays modified and newly named unsaved buffers on disk sources without duplicate hits.
For a clean buffer that diverges from disk, project scope searches disk and blocks edits
until its buffer agrees with that snapshot.

Hidden files and directories are searched in both modes, including sources under
`.config`. Discovery explicitly uses `--hidden`, overriding configured `--no-hidden`.
With Also ignored **off**, the panel respects `RIPGREP_CONFIG_PATH` globs and normal
ignore files. With it **on**,
`--no-config --no-ignore --hidden` includes configuration-ignored, normally ignored,
and hidden files such as `.venv`, followed by the UI filters. `.git` metadata is always
excluded. Real paths must remain within the root; symlink and hard-link identities are
deduplicated. Current buffers take precedence for a shared physical source.

For example, searching `if` with Include `*.lua,*.sh` also searches Lua files below
`.config/nvim/` without enabling Also ignored. Explicit exclusions
such as `.config/**` and ignore rules still apply. These rules also govern unsaved
buffers and Only open files.

New unsaved names are checked by running ripgrep in a disposable tree that mirrors
candidate names and relevant ancestor ignore files/Git excludes. No placeholder files
are created in your project and no separate Lua glob engine approximates ripgrep.

Configuration is checked before discovery. Supported forms include long `--glob=`,
`--iglob=`, type filters, absolute `--ignore-file=`, hidden/ignore/follow controls, and
the planned `--max-columns`/preview/no-heading settings. The panel normalizes match
controls itself. Unknown flags, short flags, relative `--ignore-file`, and incompatible
output/engine settings produce a visible error; Also ignored bypasses that config.

## Replacement, refresh, and limits

Each match carries the exact immutable decoded snapshot searched by ripgrep and a
separate disk fingerprint/file identity. Capture expansion comes from the same JSON
submatch used by preview and application. Before editing, the planner validates full
buffer contents, changedtick, pathname, write options, and disk contents/identity,
including after source-loading autocmds. Changed, deleted, renamed, or unsupported
sources are skipped with reasons. Partial edit failures report actual applied counts.

Replace next edits exactly one enabled occurrence. Selection advances to its surviving
successor from the original matches, skipping excluded results and avoiding immediate
revisits to newly inserted text, including zero-width matches. Replace all requires a
complete, uncapped generation and applies enabled matches across valid sources. Both
wait for child processes to settle. Edits use byte ranges in descending order; arbitrary
changes to displayed result rows never become source edits.

Changes immediately invalidate affected sessions, including sessions with no previous
hits and aliases in another root. Source edits, undo/redo, writes, listing changes, and
renames mark relevant sessions stale without launching searches. After replacement,
the applying panel refreshes; other affected panels show stale state until refreshed. A changed snapshot visibly
resets its old exclusions; unchanged snapshots retain exclusions.

Review source buffers and save with `:write`/`:wall` yourself. A replacement operation
has one native undo block per source buffer, separate from prior edits; there is no
cross-file atomic undo. CRLF, UTF-8/UTF-16 BOM, Latin-1, and final-newline handling are
covered by save-and-byte-comparison tests. Newly loaded sources without a final newline
also get `nofixendofline` so a later explicit write preserves that absence. Existing
buffers keep their write options. Binary sources are omitted; unsafe encoding/newline
mapping is visibly skipped rather than guessed.

Configure defaults before creating sessions:

```lua
require('searchlight').setup({
  match_case_sensetivity = false,
  match_whole_words = false,
  use_regular_expressions = false,
  only_search_open_files = false,
  also_search_ignored_files = false,
  context_size = 2,
  syntax_highlighting = true,
  debounce_ms = 150,
  max_results = 10000,
  concurrency = 4,
  max_files = 100000,
  max_output_bytes = 4 * 1024 * 1024,
  max_source_bytes = 8 * 1024 * 1024,
  max_snapshot_bytes = 64 * 1024 * 1024,
})
```

For case-sensitive regex searches by default, use
`setup({ match_case_sensetivity = true, use_regular_expressions = true })`.
The five modifier settings accept booleans; `context_size` accepts a nonnegative whole
number and defaults to `2`. These defaults apply to new sessions; existing sessions
retain their editable options through configuration reloads. The session API accepts
`require('searchlight').set(session, { context = 3 })` to change its context size.

Each session captures its own limits. A match, inventory, output, source, or snapshot
limit is visible and blocks full-scope replacement. Raise the relevant limit and
refresh; capped results are useful for inspection, never proof that Replace all covers
the scope. Only settled displayed matches can be used by Replace next.

Match and context code can use the source language's installed Tree-sitter parser and
highlight query, with colors from your current colorscheme. Plain results appear first;
syntax enrichment follows visible rows after a short debounce. No parsers are installed
and no source buffers or LSP clients are opened for highlighting. Missing support,
errors, oversized files and exhausted budgets leave readable plain text. Search,
selected/excluded/stale styling and zero-width markers retain priority over syntax.

Disable colors for new sessions with `setup({ syntax_highlighting = false })`.
All panels share one conservative cache: two parsers, 128 KiB per file, 256 KiB retained
source text, 2 MiB estimated bookkeeping, 8,192 spans, and 256 visible rows across at most
eight windows. Extraction skips source lines over 4 KiB and processes at most 40 lines
and 1,024 captures per chunk. In-flight work counts against these limits. Parser trees
and query libraries also consume native memory; these logical limits are not an RSS
guarantee. At most eight new languages are admitted; unsupported lookup and failure
records are separately bounded. Embedded language injections are currently disabled
pending measurements; parent-language colors still work (including Markdown).

Colorscheme changes redraw existing colors. Source filetype changes update colors
without rerunning searches. After explicitly replacing highlight queries, call
`require('searchlight.highlight').reload()` or
`:doautocmd User SearchlightHighlightReload`; this discards query spans while retaining
reusable snapshot parses. Runtimepath changes also invalidate query spans.

## Validation and design

```sh
make test
make benchmark
make syntax-benchmark
make format-check  # optional development tool: StyLua 2.5.2
```

`make test` isolates Neovim/XDG/log state and runs built-in Lua assertions, real
filesystem fixtures, real ripgrep, and an injected process driver for deterministic
asynchronous failures. Tests require ripgrep's expanded JSON replacements. Test files
ending in `_spec.lua` are discovered automatically. The direct invocation also works:
`nvim --headless -u tests/nvim/minimal_init.lua -l tests/nvim/run.lua`.

`input.lua` defines controls and pure input rules; `init.lua` coordinates input
origins and decides whether to invalidate, debounce, or submit. `view.lua` reads
editable regions and renders synchronized state, using one panel edit attachment
and preserving cursor, scroll, and undo behavior. Rendering does not launch searches.
`sessions.lua` owns session lifetime and panel window options; `actions.lua` owns
navigation and opening, and `observe.lua` invalidates affected source snapshots.

`search.lua` freezes each generation's request and runs named inventory, snapshot,
matching, and completion phases. Its private job group distinguishes cancellation
from handle settlement. `process.start(argv, opts, done)` remains the replaceable
test boundary; `scope.lua`, `sources.lua`, and `rg.lua` own eligibility, immutable
snapshots/edit validation, and ripgrep arguments/decoding. `results.lua` owns
occurrence order and selection and shares compact file/block geometry between
rendering and syntax mappings. `replace.lua` freezes targets, prepares and revalidates
source plans, applies unsaved edits, and reports actual outcomes. `highlight.lua`
owns one global bounded cache, viewport demands, and cooperative workers; decoration
callbacks only draw cached spans and request work. Repeating `setup()` preserves sessions.

The Lua facade retains `setup`, `new`, `focus`, `close`, `set`, `refresh`, `navigate`,
`open`, and `action`. Existing module helpers, including `replace.selected()`,
`replace.preview()`, and `highlight.reload()`, remain callable. Selection itself has
one implementation in `results.lua`.

The syntax benchmark compares fresh enabled/disabled processes with syntax-bearing
fixtures, kernel peak RSS, heartbeat gaps, warm navigation, drawing, and 100 lifecycle
cycles. See [syntax acceptance measurements](docs/colorful-search-results-validation.md)
for the measured release gates and global cache high-water counts.

The [backend evaluation](docs/vim-search-prototype-evaluation.md),
[original syntax report](docs/colorful-search-results-validation.md), and
[step 1–9 validation](docs/ref-v1-validation.md) are historical evidence. Earlier
automatic-search-on-typing and dedicated `Preview:` row descriptions are superseded:
native edits invalidate without searching, Enter/refresh submit immediately, and
`set()`/toggle mappings debounce. Results use the compact layout shown above;
capture expansion remains available in occurrence replacement values and
`replace.preview()`, without an extra preview row.

See [final simplification validation — 2026-10-10](docs/ref-v1-final-validation-2026-10-10.md)
for the complete feature review, interactive walkthrough, and fresh comparison with
the step 1 measurements.
