```
░░░░░░░▀░░█▀█░█░░░█▀▀░▀█▀░█▀█░░▀░░░░░░░
░░░░▀░░▀░░█▀█░█░░░█▀▀░░█░░█▀▀░░▀░░▀░░░░
░▀░░▀░░▀░░▀░▀░▀▀▀░▀░░░░▀░░▀░░░░▀░░▀░░▀░
```
A super script for mass download via lftp
Copyright (C) 2016 David White

## Motivation
Makes lftp usage a more automatic by using profiles.

General configuration contained in alftp.conf.

Profiles are contained in alftp.src.conf.

## INSTALL
Written in bash. Simply move alftp into your path and install LFPT: https://lftp.yar.ru/ and ssh.

Only tested on Arch and Debian Linux.

Currently incompatible with mac.

## CONFIGURATION
Profiles look like this:

``` bash
[docs]
data_dir='~/data/'
remote_dl_dir='docs'
server=example.com
username=remoteDave
port=21
password=secretpassword
USER=dave
if [[ $(hostname) == dave ]]; then
    local_dl_dir='~/Downloads/0new'
else
    local_dl_dir='~/Downloads/docs/0new'
fi

[data]
remote_dl_dir='data'
local_dl_dir='~/Downloads/docs/0new'

[data2]
...
``` 

You'll notice that this is written in bash other than the header.
The header specifies the argument when calling alftp from command line.
With this configuration, I can download files/directories from '~/private/data/docs' to '~/Downloads/0new' on host 'dave' by using
``` bash
$ alftp -i docs
``` 

to download individual files, or
``` bash
$ alftp -a docs
``` 

The configuration under '''[data]''' does not contain all variables listed in '''[docs]'''. Anything not listed will inherit defaults form 'alftp.conf'

### Per-profile download directories
`dl_dir` sets the download directory for every profile in the block, and `@profile` in it is
replaced with the profile you asked for:

``` bash
dl_dir='~/Downloads/@profile'      # alftp -a docs  ->  ~/Downloads/docs
```

To send one profile somewhere else, add `dl_dir_<profile>`. It wins over the general `dl_dir` for
that profile only, and everything else keeps using `dl_dir`:

``` bash
dl_dir='~/Downloads/@profile'      # alftp -a docs  ->  ~/Downloads/docs
dl_dir_TV='/mnt/media/TV'          # alftp -a TV    ->  /mnt/media/TV
dl_dir_films='/mnt/media/@profile' # alftp -a films ->  /mnt/media/films
```

As the last line shows, an override can use `@profile` itself. `-ld` on the command line still beats
both.

The suffix is part of a shell variable name, so a profile whose name is not a valid identifier maps
to one that is — every character outside `A-Za-z0-9_` becomes `_`. Profile `tv-shows` is configured
as `dl_dir_tv_shows`.

`dl_dir_<profile>` sets the *local* directory, the same side `@profile` applies to. If you want to
override where a profile is fetched *from*, use `remote_dl_dir_<profile>`, which takes precedence
over the usual fallback of using the profile name as the remote directory.

## PICKING FILES
With `-i` or `-a`, alftp shows you what the remote directory holds and you pick what to fetch. That
happens in the terminal UI by default, and in `$editor` where the terminal cannot drive a UI.

### The terminal UI
```
 alftp  /remote/dir                                 2 selected, 1 to unlink
  NAME                       SIZE  DATE
* Some.Release.2026-GRP/     4.1G  2026-08-23 17:10
    CD1/                     2.0G  2026-08-23 17:10
+   CD2/                     2.0G  2026-08-23 17:10
+   release.nfo              2.1K  2026-08-23 17:10
- Another.Release-GRP/       2.7G  2026-08-23 14:42
  notes.nfo                  2.1K  2026-08-22 09:03
 j/k move  space toggle  tab open dir  d unlink  a all  A none  q quit
```
The far-left column is what will happen to each entry:

| | |
| --- | --- |
| `+` | download it |
| `-` | leave it, but remove the source symlink from the remote directory |
| `*` | a directory you have picked *part* of — the parts are the `+` lines under it |
| blank | leave it alone |

**Everything starts deselected** — `a` selects the lot if that is what you want, `A` clears it again.

| key | |
| --- | --- |
| `j` / `k`, `↓` / `↑` | move down / up |
| `space`, `enter` | toggle the entry under the cursor |
| `tab` | open a directory, or close it again |
| `d` | mark the source symlink for removal (top-level entries only) |
| `PgDn` / `PgUp` | move a screen at a time |
| `0` / `Home`, `G` / `End` | jump to the top / bottom |
| `a` / `A` | select all / select none — the `-` marks are left alone |
| `q` / `Esc` | quit, which asks first |

`q` asks `(c)ancel`, `(s)ave and download`, or `(e)xit without downloading`. Cancel puts you back in
the list; save writes your selection to the list file and the download starts; exit leaves the list
file empty, so nothing is downloaded and the run ends. `Ctrl-C` does the same as exit.

### Opening a directory
`tab` lists a remote directory and shows what is in it, indented one level per directory deep. Each
directory is listed once, over a short lftp login of its own — the session that opened the picker is
sitting inside its `!` waiting for you, so it cannot do the listing itself. If the server refuses
that second connection the footer says so and the directory stays closed; nothing else is affected.

Inside an open directory you can pick individual entries with `space`. Those are the only two states
there — `d` is refused below the top level, because the symlink it removes is the top-level entry
itself. Picking part of a directory turns it into a `*`, and `space` on a `*` takes the whole
selection back. `space` on a directory that has nothing picked inside it takes the directory whole
(its contents then show `+` without being listed separately), and taking any one entry back out of
it turns it into a `*` with everything else still picked.

### Where it lands, and picking up where it left off
A whole entry mirrors to `<local_dl_dir>/<name>`, as it always has. Anything picked from inside a
directory keeps the structure it has on the server: `Some.Release-GRP/CD2` lands in
`<local_dl_dir>/Some.Release-GRP/CD2`, not loose in the download directory.

Transfers resume. Directories go through `mirror -c`, which continues a part-transferred file and
skips what already matches the server, and single files through `pget -c`, so re-running after an
interruption — or after coming back for more of the same directory — costs only what is actually
missing. Permissions and timestamps come across with the files, the rest of what `rsync -a` means
here.

A `-` entry is never downloaded: its symlink is removed from the remote directory and that is all.
(`-cl` still does that to everything in one go; `d` is the per-entry version of it.)

### The editor
`--editor` (or `-e`), or `picker=editor` in the config, hands the list file to `$editor` instead.
The UI also steps aside on its own — without a terminal (a cron job, output redirected to a file),
without `tput`, with `TERM` unset or `dumb`, or in a window too small to draw in — so a run never
fails just because it could not open a UI. `--tui` (`-t`) asks for the UI explicitly, and says why
it fell back if it could not run.

Editing the list file directly, the convention is the reverse of the UI's: a line that is commented
out is not downloaded, and the file arrives fully commented under `-i` for you to uncomment what you
want. A line the UI wrote carries its mark in the first column instead — `+`, `-`, `*` or `#` — and
those mean in the file exactly what they mean on screen, so a saved list can be re-edited by hand.

Each line is three columns — name, size, modification date:
```
#file1                4.0K  2026-08-23 17:10
#file2                 753  2026-08-23 14:42
#directory1/           24K  2026-08-22 09:03
```
To download '''file1''' and '''directory1/''', simply uncomment them:
```
file1                 4.0K  2026-08-23 17:10
#file2                 753  2026-08-23 14:42
directory1/            24K  2026-08-22 09:03
```
Only the first column matters when the list is read back: the size and date columns are there to
inform the choice and are stripped off again, so you can leave them alone (or edit/delete them —
a line with just a name still works).

Most servers report no size for a directory, so that column comes up blank for them. `--dir-sizes`
(or `-ds`) fills it in by asking lftp for `du -h --max-depth=1` on the remote directory while the
listing session is still open:
``` bash
$ alftp -a docs --dir-sizes
```
It is off by default because it costs a recursive walk of everything below the remote directory —
one listing request per subdirectory — before the editor opens. On a directory with a few dozen
releases that is a moment; on a deep tree it is not. Where a server does report a directory size of
its own, the `du` total wins, since the server's figure is the size of the directory entry rather
than of its contents.

## DRY RUN
To see what a profile would transfer without downloading anything, add `--dry-run` (or `-dr`):
``` bash
$ alftp -a docs --dry-run
```
Directories are listed via `lftp mirror --dry-run`, files are printed rather than fetched, nothing
is removed from the remote, and no post-processing (unrar, permissions) runs.

## HOW A RUN CONNECTS
By default a run is a single lftp login. The one session lists the remote directory, shells out to
`$EDITOR` so you can pick what you want (lftp's `!` hands the editor the terminal), and then sources
the mirror/pget commands that selection produced — all without dropping the connection. `net:idle`
is set to `never` so the link survives however long you spend in the editor.

If that misbehaves against your server, `--two-session` restores the previous behaviour: one login
to build the list, a second to download.

Note that "one login" is not "one TCP connection" — FTP opens a separate data connection per
transfer, and `mirror -P5` / `pget -n 5` deliberately open several. Servers also enforce their own
idle timeout (proftpd's `TimeoutIdle` defaults to 10 minutes), and lftp will quietly reconnect if
yours fires while the editor is open.

Credentials are written into the generated session script (created by `mktemp`, mode 0600) instead
of being passed as `lftp -u user,pass`, so they no longer appear in `ps` output.

## DEVELOPMENT
There is no build step. Before committing:
``` bash
$ shellcheck --severity=warning alftp   # checks disabled on purpose are listed in .shellcheckrc
$ bats tests                            # parsing tests, no server required
```
Both run on push/PR via `.github/workflows/ci.yml`.

The tests source `alftp` with `ALFTP_LIB=1`, which defines the functions without running `MAIN`, and
drive the argument passes and profile evaluation against `tests/fixtures/alftp.src.conf`.

Set `ALFTP_DEBUG=1` to keep (and print the path of) the temporary lftp command script each session
generates; it is also kept automatically whenever lftp exits non-zero.
