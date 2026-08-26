# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`alftp` is a single Bash script (no build step, no package manager) that wraps `lftp` to automate profile-based mass downloads over FTP/SFTP. The whole implementation lives in the `alftp` file itself; there is no separate source tree.

- `alftp` — the executable script (must stay executable: `chmod +x alftp`)
- `alftp.conf.template` — documents every recognized config key (copy to `~/.config/alftp/alftp.conf` to use)
- `README.md` — user-facing install/config/usage docs, including the profile file format

## Running / testing

The test suite covers argument/config parsing only. Verify changes by running the script directly and by static analysis:

```bash
shellcheck --severity=warning alftp   # lint — run before committing any change (see .shellcheckrc)
bats tests                            # parsing tests (ARGSB/ARGSC + config eval), no server needed
./alftp -h                # sanity-check help output after touching ARGSA/help text
./alftp -jl -s <server> -u <user> -p <pass> -P <port> -ld . -rd .   # login only, no download, quick way to test connection/arg-parsing without transferring files
./alftp -a <profile> --dry-run   # print what would be transferred, download nothing
./alftp -a <profile> --editor    # use $editor instead of the terminal UI
```

`tests/alftp.bats` covers only the pure-parsing stages; it sources the script with `ALFTP_LIB=1`, which defines the functions without running `MAIN`. Anything that talks to a server still has to be exercised against a scratch server/profile — in particular the lftp command generation (`DOWNLD`, `CREATE_LIST`, `DLDR`, `DLFL`), where a typo fails silently or produces confusing lftp errors. Each session's lftp commands are generated into a temp script; `ALFTP_DEBUG=1` keeps it and prints its path (as does any non-zero lftp exit), which is the fastest way to see exactly what was sent.

## Runtime configuration (not in this repo)

The script reads two files that live outside the repo, under `~/.config/alftp/`:

- `alftp.conf` — global defaults (keys documented in `alftp.conf.template`)
- `alftp.src.conf` — per-profile blocks in `[profile_name]` bash-snippet format (see README.md for the exact syntax); each block is `eval`'d, so it's arbitrary bash, not a plain key=value format

`INIT()` creates `alftp.conf` interactively on first run if it's missing. Neither config file exists in this checkout, so config-loading code paths (`eval_local_config`, `eval_remote_config`) can only be tested against a real `~/.config/alftp/` setup.

## Architecture: the MAIN pipeline

Execution is a strict linear pipeline driven by `MAIN()` at the bottom of the script; almost every function is a stage in this pipeline and relies on globals set by earlier stages (there are no local variables/params passed between functions — everything is communicated through unprefixed global shell variables):

1. **`INIT`** — ensures `$config` exists (offers to create it), then `source`s it and sets `USER`.
2. **`ARGSA`** — first pass over `argv`, handles flags that short-circuit everything else (`-h`, `--showc`, `--showw`) and exits immediately if matched.
3. **`eval_local_config` / `eval_remote_config`** — parse `alftp.src.conf` with `awk`, splitting it into per-`[profile]` records (`RS="\n\n\\["`), filtering out fields that belong to the other side (remote vs. local), renaming `dl_dir=` to `local_dl_dir=`/`remote_dl_dir=` as appropriate (the local pass also renames `dl_dir_<profile>=` to `local_dl_dir_<profile>=`; the remote pass deliberately does not, so a per-profile `dl_dir_` only affects the local side), and `eval`-ing the result into globals. `eval_remote_config` first resolves `default_server` from the file if the caller didn't select one via `-i`/`-a`.
4. **`ARGSB`** — second pass over `argv`; consumes `-i <profile>` / `-a <profile>`, applies any per-profile `local_dl_dir_<profile>` / `remote_dl_dir_<profile>` override (looked up by indirect expansion; `profile_var_name` maps non-identifier characters in the profile name to `_`), substitutes `@profile` in `local_dl_dir`, and sets `sourceflag`/`destflag` once source/dest are known (falls back to using the profile name as `remote_dl_dir` if unset). Note that config blocks are selected by hostname (local) and `default_server` (remote) — *not* by the `-i`/`-a` argument, which only supplies the profile name; that is why per-profile keys live inside one block rather than in separate blocks.
5. **`ARGSC`** — third pass over `argv`; handles all remaining flags (`-s -u -p -P -ld -rd -l -n -ns -o -fs -jl -rl -rm -r -cl -d -do -nu --dry-run --dir-sizes --tui --editor`), overriding whatever the config supplied. Exits with an error if `destflag`/`sourceflag` never got set. Also builds `remote_dl_dir` as `complete_dir + dirname` or `data_dir + dirname` depending on `-d`.
6. **`WELCOME`** — checks `lftp` is installed, runs `validate_config` (errors by name if `server`/`username`/`port` are missing), then defaults and creates `$listfile`/`$logfile`, and derives `$listfile2`/`$listfile3`/`$listfile4` from `$listfile` so the parent and the in-session helper agree on them.
7. **`NEW_SESSION`** — the core logic. By default this is a *single* lftp login (`SINGLE_SESSION`); `--two-session` selects the older `CREATE_LIST` + `DOWNLD` pair. In single-session mode lftp lists the remote dir, then `!env ALFTP_EMIT_DL=... ALFTP_ARGV=... bash <self>` re-enters this same script mid-session (`MAIN` dispatches to `EMIT_DL` when `ALFTP_EMIT_DL` is set), which runs the picker and writes mirror/pget commands that lftp then `source`s. Argv is handed over in a NUL-delimited file so nothing has to survive the user's `$SHELL`; every other global is re-derived by re-parsing config + argv, which is why the child reproduces the parent's state exactly. The parent re-runs `TYPE` afterwards to learn what was downloaded, so `POST_PROCESS` knows what to unrar/chmod. Stages:
   - **`CREATE_LIST`** logs into the server via `lftp` and writes remote directory listings to `$listfile` (symlink-style completion listing), `$listfile2` (actual data listing, used to distinguish files from directories) and `$listfile4` (`ls -l` of the completed directory, which is the only thing that says where each symlink points; `ls_l_cmd` emits that line, and omits it when there is nowhere to put it).
   - **`FORMAT_LIST`** (called from `EDIT_LIST`, so it runs on both paths before the user sees the file) rewrites `$listfile` from lftp's `size date time name` order into aligned `name size date` columns; `strip_columns` is its inverse and is applied by `TYPE`, so only the name is ever read back. It is idempotent and passes through any line it does not recognise, so nothing drops out of the list.
   - **`LOAD_LINKS`** / **`VALIDATE_LINKS`** (both called from `EDIT_LIST`, before the picker) parse `$listfile4` into the `LINK_TARGET` map and use it to drop broken symlinks — a target resolving into `$data_dir$dirname` that `$listfile2` no longer lists — from `$listfile` (`PRUNE_LIST`) and into `$LINESB`, which `DLPRUNE` turns into `rm -f` lines. See "Symlink targets" below.
   - For `-a`/`-i`, **`pick_list`** hands `$listfile` to a picker so the user can choose entries: the terminal UI (`tui_*`, the default) or `$editor` (see README for the `#`-to-uncomment convention). Both leave the file in the same state — chosen lines uncommented, the rest commented out — which is all `TYPE` reads back.
   - **`TYPE`** reads the picked list into `$LINESD` (mirror), `$LINESF` (pget), `$LINESR` (remove the source symlink), `$LINESX` (delete symlink *and* data) and `$LINESO` (see below). The leading character of a line says which — `+` download, `-` unlink, `x` delete, `#`/`*` leave alone, no marker at all = download, which is what hand-editing produces. A top-level name is still cross-referenced against `$listfile2` to learn whether it is a file or a directory; a path from inside an opened directory was never in `$listfile2`, so it carries its own type instead (a trailing `/` means directory) and is kept whole, which is what puts the download under the same structure it has on the server.
   - **`$LINESO` is the download order.** `LINESD`/`LINESF` are grouped by kind, so emitting from them puts every directory before every file regardless of how the user ordered the list. `TYPE` therefore also builds `LINESO`: one `dir<TAB>path` or `file<TAB>path` record per download, appended in list order by `add_order` (the only thing that may append to it). `DLXFER` walks it and calls `dldr_line`/`dlfl_line` — the bodies of `DLDR`/`DLFL`, factored out — for one entry at a time. When `LINESO` is empty `DLXFER` falls back to `DLDR; DLFL`, which is what a caller that filled `LINESD`/`LINESF` by hand (several tests, `POST_PROCESS`) asked for. `LINESD`/`LINESF` still hold the same paths and are still what `POST_PROCESS` reads.
   - **`DOWNLD`** (two-session mode) / the sourced emit file (single-session mode) combines `set_opts`, `DLPRUNE` (`rm` per broken symlink, emitted first), `DLXFER` (the transfers, in list order), `DLRM` (`rm` per unlinked entry) and `DLDEL` (`rm -r -f` of the data plus `rm -f` of the symlink, per `x` entry, emitted last). Both transfer commands use `-c` so an interrupted run resumes; only a top-level entry appends the `&& rm -f` that drops its symlink once it is complete. `run_lftp_script` runs the generated script with `lftp -f` — **not** stdin, which is what leaves stdin free for the in-session editor — and keeps the file for inspection on failure or with `ALFTP_DEBUG=1`.
   - Post-download, downloaded directories are optionally passed through **`UNRAR_FUN`** (extracts and cleans up `.rar` sets: samples, screens, `.sfv`/`.nfo`, empty dirs) unless `-nu` was given, and permissions are normalized (`644` files, `777` dirs).
8. **`COMPLETE`** — removes the lock file, clears traps, and applies `-rl`/`-ns` post-processing (delete list file / restore previous session's list for next run).

## Symlink targets (`LINK_TARGET`, `link_*`)

The completed directory is symlinks into the data directory, so anything that needs to know what is *behind* an entry reads `LINK_TARGET`: an associative array filled by `LOAD_LINKS` from `$listfile4`, mapping an entry's name to the target the server's `ls -l` reported, verbatim. `link_data_path <name>` turns a name into the absolute remote path of the data (result in `$link_path`), resolving a relative target against `$remote_dl_dir` with `link_normalize` and falling back to `$data_dir$dirname/<name>` when there is no parsed target. `LOAD_LINKS` is cheap and idempotent — call it rather than re-parsing the listing.

`link_entry_path <path>` is the same question for a path the picker produced rather than a bare name: only the first component of a nested path has a symlink to resolve, and the rest hangs off whatever that resolved to. `DLDEL` is its only caller.

`link_targets` is the parser, and it is deliberately best-effort: `ls -l` output belongs to the server (the group column is sometimes missing, the date may be `Mon DD HH:MM`, `Mon DD  YYYY` or ISO), so the name is taken to be whatever follows a recognised timestamp and a line that does not parse produces no record at all. No record means the entry is never checked, and an unchecked entry counts as *valid* — `VALIDATE_LINKS` must never remove something it could not prove is broken, which is also why a target pointing outside `$data_dir$dirname`, or deeper into it than `$listfile2` goes, is left alone.

## The terminal UI (`tui_*`)

`pick_list` runs the UI when `tui_usable` says the terminal can drive it, and falls back to `$editor` otherwise (`--editor`/`-e` and `picker=editor` force the editor; `--tui`/`-t` forces the UI and reports `$tui_why` when it still cannot run). There are no curses bindings for bash: the UI is terminfo strings from `tput`, cached once in the `t_*` globals because each `tput` is a fork and the screen redraws on every keystroke. `tui_draw` builds the whole screen as one string and writes it in a single `printf` — no cursor addressing, no flicker.

What the user picks is a tree. Every node is one index into a set of parallel arrays (`TUI_NAME`, `TUI_PATH`, `TUI_DEPTH`, `TUI_PARENT`, `TUI_ISDIR`, `TUI_STATE`, …); `TUI_ORDER` is the tree flattened for display and `TUI_VIS` the part of it that open directories make visible, so movement and drawing work in rows and never touch the tree. Children are spliced into `TUI_ORDER` directly behind their parent, which is what makes a subtree a contiguous run (`tui_subtree`) and `TUI_POS` worth maintaining (`tui_reindex`).

Selection rules live in `tui_toggle`/`tui_split_ancestor` and are worth reading before changing: a node is selected (state 1) only if no ancestor of it is, so a selected directory means "mirror the whole thing" and its children show `+` by inheritance (`tui_sel_ancestor`) without holding state. Taking one child back out of a whole directory *splits* it — the directory drops to state 0 and every other child is selected in its place — which is what turns one mirror into a list of them. `TUI_SELCNT` counts selected descendants so the `*` marker is O(1) per row rather than a subtree walk per redraw; `tui_set_state` is the only place state changes, precisely so those counters stay right (it maintains `tui_nsel`, `tui_nrm` and `tui_ndel` too).

The action states are 0 nothing / 1 download `+` / 2 unlink the source symlink `-` / 3 delete the symlink and the data `x`. `d` sets 2 (`tui_mark_remove`, top level only), `x` and `Delete` set 3 (`tui_mark_delete`), `r` clears the entry under the cursor (`tui_clear_mark`) and `R` clears the whole tree (`tui_clear_all`). `a`/`A` deliberately skip anything at state 2 or 3: those are decisions about the remote side, and `R` is the only thing that undoes them wholesale. Note that `tui_clear_subtree` clears *descendants only* — the node itself is a separate `tui_set_state` call.

**Deleting asks first.** `tui_mark_delete` calls `tui_delete_prompt` before it sets state 3, and only `Y` confirms; a cancelled prompt leaves a `$tui_msg` and no mark. Taking the mark off again asks nothing. The prompt is `$tui_prompt` drawn as the footer with the list still behind it, the same mechanism `tui_quit_prompt` uses — it is a single blocking `tui_read_key`, not a loop, so a test drives it with one extra key in `KEYS`.

**`TUI_ORDER` is download priority, and its invariant is that a subtree is a contiguous run.** Everything that splices it (`tui_fetch`, `tui_move_node`) must keep children directly behind their parent, or `tui_subtree`, `tui_children`, `tui_rebuild_vis` and the `*` counters all break at once. `tui_move_node` (`Alt`+`j`/`k`, `Alt`+`↓`/`↑`) is a swap of two adjacent runs within one sibling group — it never changes a parent, which is why it needs no counter fix-up — followed by `tui_reindex`, `tui_rebuild_vis` and `tui_vis_pos` to put the cursor back on the node that moved.

Things worth knowing before changing it:

- **Tab costs a login.** `tui_fetch` runs its own `lftp -f` (stdin from `/dev/null`, output to a temp log so it cannot scribble on the screen) because the session that spawned the picker is blocked in its `!`. `TUI_LOADED` means at most one listing per directory per session. A failure sets `$tui_msg` and leaves the directory closed — never fails the run.

- **It must not require `/dev/tty`.** lftp's `!` hands its child the terminal on stdin/stdout but *without* a controlling terminal (`tpgid` is -1), and the single-session path runs the picker exactly there. `tui_open` therefore prefers `/dev/tty` and falls back to fds 0/1; `TUI_IN`/`TUI_OUT` are what the rest of the code reads and writes, and `tui_owns_fd` records whether the fd is ours to close.
- **The terminal must be handed back exactly as it was found.** `tui_open` saves `stty -g` and switches to `-echo -icanon min 1 time 0`; `tui_close` restores it, leaves the alternate screen, and re-installs whatever INT/TERM/WINCH traps were in place. `tui_abort` (Ctrl-C) closes the same way and then empties `$listfile`, so an interrupted run downloads nothing rather than downloading whatever was on screen.
- **Everything starts deselected**, including under `-a`; `a` selects all. `tui_save` writes one line per node that says something, marked `+`/`-`/`x`/`*`/`#`, in `TUI_ORDER` order (which is what carries the priority through to `TYPE`), with nested entries carrying their full relative path — the same format `TYPE` reads and a human can edit, so the two pickers stay interchangeable and `-o`/`-ns` keep working.
- The pure parts are testable without a terminal: `tui_load`/`tui_save`/`tui_widths`/`tui_key_action`/`tui_move`/`tui_toggle` take their input from globals (`tests/alftp.bats` builds a small tree by hand the way `tui_fetch` would), and `tui_loop` reads keys only through `tui_read_key`, which a test can redefine to pop from an array with `TUI_OUT` pointed at `/dev/null` (see `tests/alftp.bats`). For the parts that do need a terminal — `tput`, `stty`, the alternate screen, escape sequences from real arrow keys — drive the script under a pty (python's `pty` module) rather than trusting it by eye.

## Conventions specific to this script

- Functions are named in `SCREAMING_SNAKE_CASE` when they're pipeline stages (`MAIN`, `INIT`, `ARGSA/B/C`, `WELCOME`, `NEW_SESSION`, `TYPE`, `DOWNLD`, `COMPLETE`, `UNRAR_FUN`) and `lower_snake_case` for helpers (`eval_local_config`, `set_opts`, `chkrmd`, `chkrmf`, `pick_list`, `tui_*`). Keep new pipeline stages uppercase to match.
- There are no `local`s: state is unprefixed globals, all initialised in the DEFAULTS block so `set -u` catches typos. New helpers should namespace their globals (`tui_`/`TUI_`/`t_`) rather than reaching for `local`.
- Flags are parsed in three separate passes (`ARGSA`/`ARGSB`/`ARGSC`) rather than one `getopts` loop, specifically so priority flags (help) can short-circuit, and so config values (loaded between passes) can be overridden by later CLI flags. When adding a new flag, decide which pass it belongs to based on this ordering.
- Every generated script starts with `$(open_cmd)`, which carries the credentials; `lftp -f` must be used alone (no `-u`/`-p`/site arguments alongside it). `lftp_quote` quotes for lftp's parser, `sh_quote` for the `$SHELL` that runs the `!` line.
- Blocks marked `#DO NOT INDENT CONTENTS` (in `CREATE_LIST` and `DOWNLD`) are bash here-docs (`<< EOF`) whose contents become the lftp command script verbatim; reformatting/indenting them changes what gets sent to the remote lftp session.
- `format_columns` holds the awk that turns a raw lftp listing into aligned `name size date` columns; `FORMAT_LIST` applies it to `$listfile` and `tui_fetch` to each subdirectory listing, so everything the picker shows went through the same transformation.
- The first character of a list-file line is its mark, which means an unmarked line whose *name* starts with `-` or `x` is read as an unlink or a delete. The picker always writes a mark, so this only affects hand-edited lists; it is called out in `README.md` rather than worked around, because there is nothing in the format that could tell the two apart.
- `sed`/`awk` one-liners do double duty as data transforms and as escaping for filenames with spaces/brackets (the `SsS` sentinel marks trailing whitespace before it gets re-inserted, and `[` is escaped for lftp glob-safety). Preserve these when touching `DLDR`/`DLFL`/`TYPE`.
