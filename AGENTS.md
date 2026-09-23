# AGENTS.md

Guidance for working in this repository. This project builds a pipeline of
Emacs Lisp scripts that use **gptel** + a **local Ollama model** to
auto-tag org-roam notes.

## Project layout

- `org/` — the test directory of org-roam notes (36 files). This is a
  development copy, not the live roam directory.
- `auto-tag-core.el` — shared helpers (file discovery, note parsing, gptel
  request wrapper, JSON I/O, tag normalization). No file mutation.
- `auto-tag-suggest.el` — Phase 1: per-note tag suggestions.
- `auto-tag-consolidate.el` — Phase 2: build a controlled vocabulary (~20% of
  file count) and assign tags per note.
- `auto-tag-apply.el` — Phase 3: write tags via `org-roam-tag-add` only.
- `auto-tag.el` — convenience `auto-tag-run` entry point chaining all phases.
- `smoke-test.el` — minimal gptel+Ollama connectivity check (kept for reference).
- `test/` — ERT tests: `run-tests.el` (fast, faked AI) and
  `run-ollama-test.el` (one real Ollama request on a single fixture).
- `README.org` — user-facing documentation.
- `AGENTS.md` — this file.

The pipeline is three phases:

1. `auto-tag-suggest DIR` → `auto-tag-suggestions.json`.
2. `auto-tag-consolidate DIR` → `auto-tag-final.json`.
3. `auto-tag-apply DIR` (or `DIR` + prefix arg for dry-run) → writes tags.

Intermediate JSON data files live in `auto-tag-data-directory` (a
subdirectory of `temporary-file-directory` by default); `auto-tag--data-file`
includes an md5 hash of the scanned directory in the filename so different
directories do not collide.

Each phase also has a `-project` variant (e.g. `auto-tag-run-project`) that
operates on the current project root (`project-current`, falling back to
`default-directory`) instead of prompting for a directory.

## Environment facts

- Emacs: **GNU Emacs 31.1**.
- Package manager: **straight.el**, build dir
  `~/.config/emacs/.local/straight/build-31.1/` (one subdir per package).
- `gptel` is installed. Registered backends:
  - `"Ollama"` — model `qwen2.5:latest`, host `localhost:11434`.
  - `"GeminiSearch"` — Gemini (not used here; we want the local model).
- `ollama` binary: `/usr/local/bin/ollama`; only model is `qwen2.5:latest`.
- `org-roam` is installed. Live `org-roam-directory` is
  `/Users/andrewpatrick/Documents/org/roam/` (DIFFERENT from this repo's
  `org/`). The repo `org/` is the test target.

## How to run the scripts

Run via `emacs --batch` (the MCP `eval-elisp` tool is sandboxed and blocks
`with-current-buffer`/`find-file-noselect`; batch is not sandboxed).

```sh
emacs --batch -Q --eval '(progn
  (let ((build (expand-file-name "~/.config/emacs/.local/straight/build-31.1/")))
    (dolist (d (directory-files build t "\\`[^.]"))
      (when (file-directory-p d) (add-to-list (quote load-path) d))))
  (add-to-list (quote load-path) "/Users/andrewpatrick/LocalDocuments/VSCode/emacs-explore/auto-tag")
  (require (quote auto-tag))
  (auto-tag-suggest "/Users/andrewpatrick/LocalDocuments/VSCode/emacs-explore/auto-tag/org"))'
```

The load-path bootstrap (add every straight build subdir) is required in
batch; it makes `(require 'gptel)`, `(require 'gptel-ollama)`, and
`(require 'org-roam)` work without loading the user's init file.

## Running tests

```sh
# Fast unit tests (faked AI responses, no network)
emacs --batch -Q -l test/run-tests.el

# Optional: one real Ollama request on a single fixture (skips if unreachable)
emacs --batch -Q -l test/run-ollama-test.el
```

The unit tests fake the model by `cl-letf`-overriding
`auto-tag--gptel-json`. The Ollama test config (backend/model) is in
`test/auto-tag-ollama-test.el` via `auto-tag-ollama-test-backend` and
`auto-tag-ollama-test-model`.

## gptel API notes (learned by reading source + testing)

- `gptel-request` is **async**. Signature (from its docstring):
  `(gptel-request &optional PROMPT &key CALLBACK BUFFER POSITION CONTEXT DRY-RUN STREAM IN-PLACE SYSTEM SCHEMA TRANSFORMS FSM)`.
- Select backend/model by **let-binding** `gptel-backend` and `gptel-model`
  (there are NO `:backend`/`:model` keyword args).
- `(gptel-get-backend "Ollama")` returns a backend struct; model is
  `(car (gptel-backend-models backend))`.
- `gptel-make-ollama` registers/creates the Ollama backend; `:models` accepts
  strings or symbols.
- The `:schema` keyword forces JSON output; for Ollama gptel maps it to the
  `format` request field. `:stream nil` makes the callback fire once with the
  full response string.
- Synchronous wrapper pattern (works in batch):
  ```elisp
  (gptel-request prompt
    :system sys :schema schema :stream nil
    :callback (lambda (resp info)
                (setq status (plist-get info :status))
                (when (stringp resp) (setq result (string-trim resp)))
                (setq done t)))
  (while (not done) (accept-process-output nil 0.1))
  ```
  Use `accept-process-output` (not `sit-for`/`sleep-for`) for the wait loop.

## org-roam tag API notes (learned by reading `org-roam-node.el`)

- `org-roam-tag-add` takes a **list of tag strings** (e.g. `("emacs" "gptel")`),
  NOT a `:a:b:` string. It unions with existing tags (merge is built in).
- It operates on "the node at point". For file-level tags, visit the file,
  go to `(point-min)`, and call it:
  ```elisp
  (with-current-buffer (find-file-noselect file t)
    (goto-char (point-min))
    (org-roam-tag-add tags)
    (save-buffer))
  ```
- `org-roam-tag-remove` is the symmetric inverse (uses `seq-difference`).
- `org-roam-node-at-point` works even when the node is NOT yet in the db
  (returns a node with only `:id`/`:point` populated), so no `org-roam-db-sync`
  is required before tagging.
- Mutation must go through these org-roam functions (project requirement), not
  raw `#+filetags:` string editing.

## JSON serialization gotcha (IMPORTANT)

`json-serialize` DWIMs over Lisp lists and gets confused by a **list of
plists**: `((:file "a" :tags ("x")) (:file "b" ...))` looks like an alist, so
it mis-serializes and signals `wrong-type-argument symbolp`. Also, alist keys
must be **symbols** (string keys signal `wrong-type-argument symbolp`), and
keyword keys serialize with a leading colon (`":file"`), which then reads
back (as a plist) as `::file`.

The working convention in `auto-tag-core.el`:
- Keep internal data as **plists** (keyword keys) and **lists** for arrays
  (so `plist-get` works throughout).
- `auto-tag--json-normalize` converts plists to alists (keys become
  **non-keyword symbols** via `(intern (substring (symbol-name key) 1))`) and
  lists to **vectors**, then hands off to `json-serialize`. This yields clean
  JSON keys (`"file"`, `"tags"`, …) and unambiguous arrays.
- Parse with `:object-type 'plist` and `:array-type 'list` so objects come
  back as keyword-keyed plists and arrays as lists — matching the internal
  representation. Round-trip is clean.
- Note: `json-parse-string`/`json-parse-buffer` with `:object-type 'plist`
  prepends `:` to keys, so a JSON key `"tags"` becomes `:tags`.

## Decisions made with the user

- Operate on the test directory first (this repo's `org/`). The directory is
  a parameter to the directory-based functions; the `-project` variants
  operate on the current project root instead.
- Tag count target = **20%** of file count (36 files → 8 tags).
- Existing tags are **merged** (via `org-roam-tag-add`), not replaced.
- Assume **no multi-note files** for now (do not skip/filter; process all
  files). Note: naive `#+title:` counting is unreliable because example
  source blocks also contain `#+title:` lines.
- Use Emacs Lisp functions only to modify files (org-roam API).
- Added **list-of-files** entry points (`auto-tag-suggest-files`,
  `auto-tag-apply-files`, `auto-tag-run-files`). List-of-files functions
  require all files in one directory, which is used to derive the data-file
  hash and resolve basenames during consolidation.
- Default behavior is **only-untagged**: suggest/apply/run skip files that
  already have a `#+filetags:` keyword unless `include-tagged` is non-nil.
