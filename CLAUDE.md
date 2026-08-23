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
3. **`eval_local_config` / `eval_remote_config`** — parse `alftp.src.conf` with `awk`, splitting it into per-`[profile]` records (`RS="\n\n\\["`), filtering out fields that belong to the other side (remote vs. local), renaming `dl_dir=` to `local_dl_dir=`/`remote_dl_dir=` as appropriate, and `eval`-ing the result into globals. `eval_remote_config` first resolves `default_server` from the file if the caller didn't select one via `-i`/`-a`.
4. **`ARGSB`** — second pass over `argv`; consumes `-i <profile>` / `-a <profile>`, substitutes `@profile` in `local_dl_dir`, and sets `sourceflag`/`destflag` once source/dest are known (falls back to using the profile name as `remote_dl_dir` if unset).
5. **`ARGSC`** — third pass over `argv`; handles all remaining flags (`-s -u -p -P -ld -rd -l -n -ns -o -fs -jl -rl -rm -r -cl -d -do -nu`), overriding whatever the config supplied. Exits with an error if `destflag`/`sourceflag` never got set. Also builds `remote_dl_dir` as `complete_dir + dirname` or `data_dir + dirname` depending on `-d`.
6. **`WELCOME`** — checks `lftp` is installed, runs `validate_config` (errors by name if `server`/`username`/`port` are missing), then defaults and creates `$listfile`/`$logfile`.
7. **`NEW_SESSION`** — the core logic. By default this is a *single* lftp login (`SINGLE_SESSION`); `--two-session` selects the older `CREATE_LIST` + `DOWNLD` pair. In single-session mode lftp lists the remote dir, then `!env ALFTP_EMIT_DL=... ALFTP_ARGV=... bash <self>` re-enters this same script mid-session (`MAIN` dispatches to `EMIT_DL` when `ALFTP_EMIT_DL` is set), which runs the editor and writes mirror/pget commands that lftp then `source`s. Argv is handed over in a NUL-delimited file so nothing has to survive the user's `$SHELL`; every other global is re-derived by re-parsing config + argv, which is why the child reproduces the parent's state exactly. The parent re-runs `TYPE` afterwards to learn what was downloaded, so `POST_PROCESS` knows what to unrar/chmod. Stages:
   - **`CREATE_LIST`** logs into the server via `lftp` and writes remote directory listings to `$listfile` (symlink-style completion listing) and `$listfile2` (actual data listing, used to distinguish files from directories).
   - For `-a`/`-i`, opens `$editor` on `$listfile` so the user can comment/uncomment entries (see README for the `#`-to-uncomment convention).
   - **`TYPE`** cross-references `$listfile` against `$listfile2` to split the user's selection into `$LINESD` (directories) and `$LINESF` (files).
   - **`DOWNLD`** (two-session mode) / the sourced emit file (single-session mode) combines `set_opts`, `DLDR` (mirror commands per directory), and `DLFL` (pget commands per file). `run_lftp_script` runs the generated script with `lftp -f` — **not** stdin, which is what leaves stdin free for the in-session editor — and keeps the file for inspection on failure or with `ALFTP_DEBUG=1`.
   - Post-download, downloaded directories are optionally passed through **`UNRAR_FUN`** (extracts and cleans up `.rar` sets: samples, screens, `.sfv`/`.nfo`, empty dirs) unless `-nu` was given, and permissions are normalized (`644` files, `777` dirs).
8. **`COMPLETE`** — removes the lock file, clears traps, and applies `-rl`/`-ns` post-processing (delete list file / restore previous session's list for next run).

## Conventions specific to this script

- Functions are named in `SCREAMING_SNAKE_CASE` when they're pipeline stages (`MAIN`, `INIT`, `ARGSA/B/C`, `WELCOME`, `NEW_SESSION`, `TYPE`, `DOWNLD`, `COMPLETE`, `UNRAR_FUN`) and `lower_snake_case` for helpers (`eval_local_config`, `set_opts`, `chkrmd`, `chkrmf`). Keep new pipeline stages uppercase to match.
- Flags are parsed in three separate passes (`ARGSA`/`ARGSB`/`ARGSC`) rather than one `getopts` loop, specifically so priority flags (help) can short-circuit, and so config values (loaded between passes) can be overridden by later CLI flags. When adding a new flag, decide which pass it belongs to based on this ordering.
- Every generated script starts with `$(open_cmd)`, which carries the credentials; `lftp -f` must be used alone (no `-u`/`-p`/site arguments alongside it). `lftp_quote` quotes for lftp's parser, `sh_quote` for the `$SHELL` that runs the `!` line.
- Blocks marked `#DO NOT INDENT CONTENTS` (in `CREATE_LIST` and `DOWNLD`) are bash here-docs (`<< EOF`) whose contents become the lftp command script verbatim; reformatting/indenting them changes what gets sent to the remote lftp session.
- `sed`/`awk` one-liners do double duty as data transforms and as escaping for filenames with spaces/brackets (the `SsS` sentinel marks trailing whitespace before it gets re-inserted, and `[` is escaped for lftp glob-safety). Preserve these when touching `DLDR`/`DLFL`/`TYPE`.
