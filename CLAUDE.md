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
6. **`WELCOME`** — checks `lftp` is installed, runs `validate_config` (errors by name if `server`/`username`/`port` are missing), then defaults and creates `$listfile`/`$logfile`.
7. **`NEW_SESSION`** — the core logic. By default this is a *single* lftp login (`SINGLE_SESSION`); `--two-session` selects the older `CREATE_LIST` + `DOWNLD` pair. In single-session mode lftp lists the remote dir, then `!env ALFTP_EMIT_DL=... ALFTP_ARGV=... bash <self>` re-enters this same script mid-session (`MAIN` dispatches to `EMIT_DL` when `ALFTP_EMIT_DL` is set), which runs the picker and writes mirror/pget commands that lftp then `source`s. Argv is handed over in a NUL-delimited file so nothing has to survive the user's `$SHELL`; every other global is re-derived by re-parsing config + argv, which is why the child reproduces the parent's state exactly. The parent re-runs `TYPE` afterwards to learn what was downloaded, so `POST_PROCESS` knows what to unrar/chmod. Stages:
   - **`CREATE_LIST`** logs into the server via `lftp` and writes remote directory listings to `$listfile` (symlink-style completion listing) and `$listfile2` (actual data listing, used to distinguish files from directories).
   - **`FORMAT_LIST`** (called from `EDIT_LIST`, so it runs on both paths before the user sees the file) rewrites `$listfile` from lftp's `size date time name` order into aligned `name size date` columns; `strip_columns` is its inverse and is applied by `TYPE`, so only the name is ever read back. It is idempotent and passes through any line it does not recognise, so nothing drops out of the list.
   - For `-a`/`-i`, **`pick_list`** hands `$listfile` to a picker so the user can choose entries: the terminal UI (`tui_*`, the default) or `$editor` (see README for the `#`-to-uncomment convention). Both leave the file in the same state — chosen lines uncommented, the rest commented out — which is all `TYPE` reads back.
   - **`TYPE`** cross-references `$listfile` against `$listfile2` to split the user's selection into `$LINESD` (directories) and `$LINESF` (files).
   - **`DOWNLD`** (two-session mode) / the sourced emit file (single-session mode) combines `set_opts`, `DLDR` (mirror commands per directory), and `DLFL` (pget commands per file). `run_lftp_script` runs the generated script with `lftp -f` — **not** stdin, which is what leaves stdin free for the in-session editor — and keeps the file for inspection on failure or with `ALFTP_DEBUG=1`.
   - Post-download, downloaded directories are optionally passed through **`UNRAR_FUN`** (extracts and cleans up `.rar` sets: samples, screens, `.sfv`/`.nfo`, empty dirs) unless `-nu` was given, and permissions are normalized (`644` files, `777` dirs).
8. **`COMPLETE`** — removes the lock file, clears traps, and applies `-rl`/`-ns` post-processing (delete list file / restore previous session's list for next run).

## The terminal UI (`tui_*`)

`pick_list` runs the UI when `tui_usable` says the terminal can drive it, and falls back to `$editor` otherwise (`--editor`/`-e` and `picker=editor` force the editor; `--tui`/`-t` forces the UI and reports `$tui_why` when it still cannot run). There are no curses bindings for bash: the UI is terminfo strings from `tput`, cached once in the `t_*` globals because each `tput` is a fork and the screen redraws on every keystroke. `tui_draw` builds the whole screen as one string and writes it in a single `printf` — no cursor addressing, no flicker.

Things worth knowing before changing it:

- **It must not require `/dev/tty`.** lftp's `!` hands its child the terminal on stdin/stdout but *without* a controlling terminal (`tpgid` is -1), and the single-session path runs the picker exactly there. `tui_open` therefore prefers `/dev/tty` and falls back to fds 0/1; `TUI_IN`/`TUI_OUT` are what the rest of the code reads and writes, and `tui_owns_fd` records whether the fd is ours to close.
- **The terminal must be handed back exactly as it was found.** `tui_open` saves `stty -g` and switches to `-echo -icanon min 1 time 0`; `tui_close` restores it, leaves the alternate screen, and re-installs whatever INT/TERM/WINCH traps were in place. `tui_abort` (Ctrl-C) closes the same way and then empties `$listfile`, so an interrupted run downloads nothing rather than downloading whatever was on screen.
- **Everything starts deselected**, including under `-a`; `a` selects all. `tui_save` writes the selection back in the editor's own format, so the two pickers are interchangeable and `-o`/`-ns` keep working.
- The pure parts are testable without a terminal: `tui_load`/`tui_save`/`tui_widths`/`tui_key_action`/`tui_move` take their input from globals, and `tui_loop` reads keys only through `tui_read_key`, which a test can redefine to pop from an array with `TUI_OUT` pointed at `/dev/null` (see `tests/alftp.bats`). For the parts that do need a terminal — `tput`, `stty`, the alternate screen, escape sequences from real arrow keys — drive the script under a pty (python's `pty` module) rather than trusting it by eye.

## Conventions specific to this script

- Functions are named in `SCREAMING_SNAKE_CASE` when they're pipeline stages (`MAIN`, `INIT`, `ARGSA/B/C`, `WELCOME`, `NEW_SESSION`, `TYPE`, `DOWNLD`, `COMPLETE`, `UNRAR_FUN`) and `lower_snake_case` for helpers (`eval_local_config`, `set_opts`, `chkrmd`, `chkrmf`, `pick_list`, `tui_*`). Keep new pipeline stages uppercase to match.
- There are no `local`s: state is unprefixed globals, all initialised in the DEFAULTS block so `set -u` catches typos. New helpers should namespace their globals (`tui_`/`TUI_`/`t_`) rather than reaching for `local`.
- Flags are parsed in three separate passes (`ARGSA`/`ARGSB`/`ARGSC`) rather than one `getopts` loop, specifically so priority flags (help) can short-circuit, and so config values (loaded between passes) can be overridden by later CLI flags. When adding a new flag, decide which pass it belongs to based on this ordering.
- Every generated script starts with `$(open_cmd)`, which carries the credentials; `lftp -f` must be used alone (no `-u`/`-p`/site arguments alongside it). `lftp_quote` quotes for lftp's parser, `sh_quote` for the `$SHELL` that runs the `!` line.
- Blocks marked `#DO NOT INDENT CONTENTS` (in `CREATE_LIST` and `DOWNLD`) are bash here-docs (`<< EOF`) whose contents become the lftp command script verbatim; reformatting/indenting them changes what gets sent to the remote lftp session.
- `sed`/`awk` one-liners do double duty as data transforms and as escaping for filenames with spaces/brackets (the `SsS` sentinel marks trailing whitespace before it gets re-inserted, and `[` is escaped for lftp glob-safety). Preserve these when touching `DLDR`/`DLFL`/`TYPE`.
