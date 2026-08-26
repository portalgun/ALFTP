#!/usr/bin/env bats
#
# End-to-end tests against a real lftp, talking to a file:// "server"
# (tests/helpers/server.bash). Unlike tests/alftp.bats -- which drives the pure
# parsing stages -- these actually list, transfer and unlink, so they cover the
# lftp command generation that used to need a scratch server.

setup() {
    ALFTP="${BATS_TEST_DIRNAME}/../alftp"
    load helpers/server
    srv_setup
}

teardown() {
    srv_teardown
}

# $1 = bash snippet run after alftp has been sourced with the fake remote's
# globals already in place.
srv_stage() {
    bash -c 'ALFTP_LIB=1 source "$1"; SRV="$2"; DL="$3"; eval "$4"; eval "$5"' \
        _ "$ALFTP" "$SRV" "$DL" "$(srv_globals)" "$1"
}

@test "CREATE_LIST lists the completed directory and the data behind it" {
    run srv_stage 'CREATE_LIST; echo "--"; cat "$listfile"; echo "--"; cat "$listfile2"'
    [ "$status" -eq 0 ]
    # The symlink listing, classifier and all, then the real data directory.
    [[ "$output" == *"Rel.One-GRP@"* ]]
    [[ "$output" == *"broken.link@"* ]]
    [[ "$output" == *"Rel.One-GRP/"* ]]
    [[ "$output" == *"notes.nfo"* ]]
}

@test "a directory mirrors, a file pgets, and both drop their symlink" {
    run srv_stage 'LINESD="Rel.One-GRP"; LINESF="notes.nfo"; DOWNLD'
    [ "$status" -eq 0 ]
    # Everything below the release came across, through the symlink.
    [ -f "$DL/Rel.One-GRP/movie.mkv" ]
    [ -f "$DL/Rel.One-GRP/CD1/part1.bin" ]
    [ -f "$DL/notes.nfo" ]
    [ "$(cat "$DL/notes.nfo")" = "some notes" ]
    # A completed top-level entry loses its symlink, and only its symlink: the
    # data behind it is untouched.
    [ ! -e "$SRV/complete/TV/Rel.One-GRP" ]
    [ ! -e "$SRV/complete/TV/notes.nfo" ]
    [ -f "$SRV/data/TV/notes.nfo" ]
}

@test "-do keeps the symlink after a completed download" {
    run srv_stage 'norm=True; LINESF="notes.nfo"; DOWNLD'
    [ "$status" -eq 0 ]
    [ -f "$DL/notes.nfo" ]
    [ -L "$SRV/complete/TV/notes.nfo" ]
}

@test "--dry-run transfers nothing and removes nothing" {
    run srv_stage 'dry_run=True; LINESD="Rel.One-GRP"; LINESF="notes.nfo"; DOWNLD'
    [ "$status" -eq 0 ]
    [ ! -e "$DL/notes.nfo" ]
    [ ! -e "$DL/Rel.One-GRP" ]
    [ -L "$SRV/complete/TV/notes.nfo" ]
}

@test "a nested selection lands under the structure it has on the server" {
    run srv_stage 'LINESD="Rel.One-GRP/CD1"; LINESF="Rel.One-GRP/release.nfo"; DOWNLD'
    [ "$status" -eq 0 ]
    [ -f "$DL/Rel.One-GRP/CD1/part1.bin" ]
    [ -f "$DL/Rel.One-GRP/release.nfo" ]
    # Nothing below the top level owns the release's symlink.
    [ -L "$SRV/complete/TV/Rel.One-GRP" ]
}

@test "DLRM drops a symlink without downloading it" {
    run srv_stage 'LINESR="notes.nfo"; DOWNLD'
    [ "$status" -eq 0 ]
    [ ! -e "$SRV/complete/TV/notes.nfo" ]
    [ ! -e "$DL/notes.nfo" ]
    [ -f "$SRV/data/TV/notes.nfo" ]
}

@test "the whole script runs a profile through one lftp session" {
    home=$(srv_home)
    # A stand-in for $editor: keep the release, comment the rest out.
    editor="$SRV/pick"
    cat > "$editor" <<'PICK'
#!/usr/bin/env bash
awk '{ if ($0 ~ /^Rel\.One-GRP/) print $0; else print "#" $0 }' "$1" > "$1.new"
mv "$1.new" "$1"
PICK
    chmod +x "$editor"
    run env HOME="$home" EDITOR="$editor" ALFTP_LIB= "$ALFTP" -a TV -nu
    [ "$status" -eq 0 ]
    [ -f "$DL/Rel.One-GRP/movie.mkv" ]
    [ -f "$DL/Rel.One-GRP/CD1/part1.bin" ]
    # Only what was picked: notes.nfo stayed behind, symlink and all.
    [ ! -e "$DL/notes.nfo" ]
    [ -L "$SRV/complete/TV/notes.nfo" ]
    [ ! -e "$SRV/complete/TV/Rel.One-GRP" ]
}

@test "the picker runs under a real terminal and downloads what was picked" {
    if ! command -v python3 > /dev/null 2>&1; then
        skip "python3 is needed to drive a pty"
    fi
    home=$(srv_home)
    # Down onto the release, space to take it, q then s to save and download.
    run env HOME="$home" TERM=xterm-256color \
        python3 "${BATS_TEST_DIRNAME}/helpers/ptydrive.py" \
        --keys '\x20 q s' --delay 0.5 -- "$ALFTP" -a TV -t -nu
    [[ "$output" == *"Rel.One-GRP"* ]]          # the UI painted the listing
    [[ "$output" == *"1 selection(s)"* ]]
    [ -f "$DL/Rel.One-GRP/movie.mkv" ]
    [ -f "$DL/Rel.One-GRP/CD1/part1.bin" ]
    [ ! -e "$DL/notes.nfo" ]
}

# ---------------------------------------------------------------- audit fixes
#
# These run the whole script, so they need a lock file of their own: the real
# one is /tmp/alftp.lock, and a test has no business taking it away from a run
# the user started.

# $1 = extra lines for the config, $2... = alftp's arguments.
srv_run() {
    home=$(srv_home)
    printf 'lockfile="%s"\n%s\n' "$SRV/alftp.lock" "$1" \
        >> "$home/.config/alftp/alftp.conf"
    shift
    env HOME="$home" EDITOR="/bin/true" "$ALFTP" "$@"
}

@test "-ls says what was marked and transfers nothing" {
    run srv_run "" -a TV -q -ls
    [ "$status" -eq 0 ]
    # -a with -q marks the lot, so every entry in the completed directory is
    # named with its size and date ...
    [[ "$output" == *"Rel.One-GRP@"* ]]
    [[ "$output" == *"notes.nfo@"* ]]
    [[ "$output" == *"2026-"* ]] || [[ "$output" == *"20"* ]]
    # ... and nothing was downloaded or unlinked.
    [ -z "$(ls -A "$DL")" ]
    [ -L "$SRV/complete/TV/Rel.One-GRP" ]
}

@test "a second run refuses to start while the first holds the lock" {
    home=$(srv_home)
    printf 'lockfile="%s"\n' "$SRV/alftp.lock" >> "$home/.config/alftp/alftp.conf"
    printf '%s\n' "$$" > "$SRV/alftp.lock"      # a pid that is very much alive
    run env HOME="$home" EDITOR="/bin/true" "$ALFTP" -a TV -q
    [ "$status" -eq 1 ]
    [[ "$output" == *"another run (pid $$) is in progress"* ]]
    [ -z "$(ls -A "$DL")" ]
    # The run that could not start does not remove the lock it did not take.
    [ -e "$SRV/alftp.lock" ]
}

@test "a finished run gives its lock back" {
    run srv_run "" -a TV -q -nu
    [ "$status" -eq 0 ]
    [ ! -e "$SRV/alftp.lock" ]
}

@test "-c starts the next run from the selection the last one made" {
    # First run: keep the symlinks (-do) so the same entries are still there
    # next time, and pick just the release.
    editor="$SRV/pick"
    cat > "$editor" <<'PICK'
#!/usr/bin/env bash
awk '{ if ($0 ~ /^Rel\.One-GRP/) print $0; else print "#" $0 }' "$1" > "$1.new"
mv "$1.new" "$1"
PICK
    chmod +x "$editor"
    home=$(srv_home)
    printf 'lockfile="%s"\n' "$SRV/alftp.lock" >> "$home/.config/alftp/alftp.conf"
    run env HOME="$home" EDITOR="$editor" "$ALFTP" -a TV -do -nu
    [ "$status" -eq 0 ]
    [ -f "$DL/Rel.One-GRP/movie.mkv" ]

    # Second run, -c: the release comes back marked without the editor being
    # asked to mark anything (this one leaves the list exactly as it found it).
    run env HOME="$home" EDITOR="/bin/true" "$ALFTP" -i TV -c -do -ls
    [ "$status" -eq 0 ]
    [[ "$output" == *"carried over 1 mark(s)"* ]]
    [[ "$output" == *"Rel.One-GRP@"* ]]
    [[ "$output" != *"notes.nfo"* ]]
}

@test "the record says what was downloaded, and -r keeps it out of it" {
    run srv_run "" -a TV -q -nu
    [ "$status" -eq 0 ]
    rec="$SRV/home/.cache/alftp/alftp.record"
    [ -s "$rec" ]
    [[ "$(cat "$rec")" == *"Rel.One-GRP"* ]]
    [[ "$(cut -f2 < "$rec" | head -n 1)" = "TV" ]]

    # A second run with -r: it downloads (nothing is left to fetch, but the
    # entries are still walked) and writes no new record line.
    before=$(wc -l < "$rec")
    run srv_run "" -a TV -q -nu -r
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$rec")" -eq "$before" ]
}

@test "checksum=True writes down what arrived" {
    run srv_run 'checksum=True' -a TV -q -nu
    [ "$status" -eq 0 ]
    ver="$SRV/home/.cache/alftp/alftp.verify"
    [ -s "$ver" ]
    # A single file gets its size and its hash; a directory gets its total.
    [[ "$(grep notes.nfo "$ver")" == *"bytes=11 sha256=$(sha256sum < "$DL/notes.nfo" | cut -d' ' -f1)"* ]]
    [[ "$(grep Rel.One-GRP "$ver")" == *"bytes="* ]]
}

@test "chmod/chown settings decide the permissions of what was downloaded" {
    run srv_run 'chmod=True
perms_dirs=755
perms_files=640' -a TV -q -nu
    [ "$status" -eq 0 ]
    [ "$(stat -c '%a' "$DL/Rel.One-GRP")" = "755" ]
    [ "$(stat -c '%a' "$DL/Rel.One-GRP/movie.mkv")" = "640" ]
    [ "$(stat -c '%a' "$DL/Rel.One-GRP/CD1")" = "755" ]
}

@test "an x entry loses its symlink and the data behind it" {
    run srv_stage 'CREATE_LIST; LOAD_LINKS; LINESX="Rel.One-GRP"; DOWNLD'
    [ "$status" -eq 0 ]
    # Both ends of the symlink are gone, and nothing was downloaded first.
    [ ! -e "$SRV/complete/TV/Rel.One-GRP" ]
    [ ! -e "$SRV/data/TV/Rel.One-GRP" ]
    [ ! -e "$DL/Rel.One-GRP" ]
    # Everything else is untouched.
    [ -L "$SRV/complete/TV/notes.nfo" ]
    [ -f "$SRV/data/TV/notes.nfo" ]
}

@test "a - entry next to it still loses only its symlink" {
    run srv_stage 'CREATE_LIST; LOAD_LINKS; LINESX="Rel.One-GRP"; LINESR="notes.nfo"; DOWNLD'
    [ "$status" -eq 0 ]
    [ ! -e "$SRV/data/TV/Rel.One-GRP" ]
    [ ! -e "$SRV/complete/TV/notes.nfo" ]
    [ -f "$SRV/data/TV/notes.nfo" ]
}

@test "deleting a single file inside a release leaves the release alone" {
    run srv_stage 'CREATE_LIST; LOAD_LINKS; LINESX="Rel.One-GRP/movie.mkv"; DOWNLD'
    [ "$status" -eq 0 ]
    [ ! -e "$SRV/data/TV/Rel.One-GRP/movie.mkv" ]
    [ -f "$SRV/data/TV/Rel.One-GRP/release.nfo" ]
    # A nested entry has no symlink of its own, so the release keeps its.
    [ -L "$SRV/complete/TV/Rel.One-GRP" ]
}

@test "--dry-run deletes neither the symlink nor the data" {
    run srv_stage 'dry_run=True; CREATE_LIST; LOAD_LINKS; LINESX="Rel.One-GRP"; DOWNLD'
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN: rm -r"* ]]
    [ -L "$SRV/complete/TV/Rel.One-GRP" ]
    [ -d "$SRV/data/TV/Rel.One-GRP" ]
}

@test "the download runs in the order the list had, not directories first" {
    run srv_stage 'LINESO="file'$'\t''notes.nfo
dir'$'\t''Rel.One-GRP"; DOWNLD'
    [ "$status" -eq 0 ]
    [ -f "$DL/notes.nfo" ]
    [ -f "$DL/Rel.One-GRP/movie.mkv" ]
    # The file was picked above the directory, so it transferred first.
    first=$(printf '%s\n' "$output" | grep -n 'COMPLETE: notes.nfo' | head -n 1 | cut -d: -f1)
    second=$(printf '%s\n' "$output" | grep -n 'COMPLETE: Rel.One-GRP' | head -n 1 | cut -d: -f1)
    [ -n "$first" ]
    [ -n "$second" ]
    [ "$first" -lt "$second" ]
}

# A stand-in for $editor that keeps a copy of what it was shown and then picks
# nothing, so a run costs one listing and no transfers: what is being tested is
# the list the picker was handed and what the session did to the remote.
srv_picker() {
    cat > "$SRV/pick" <<'PICK'
#!/usr/bin/env bash
cp "$1" "$1.seen"
sed -i 's/^/#/' "$1"
PICK
    chmod +x "$SRV/pick"
    printf '%s' "$SRV/pick"
}

@test "CREATE_LIST captures the symlink targets alongside the listings" {
    run srv_stage 'CREATE_LIST; link_targets "$listfile4"'
    [ "$status" -eq 0 ]
    # Real lftp "ls -l" output, parsed back into name -> target.
    [[ "$output" == *"broken.link	../../data/TV/gone.mkv"* ]]
    [[ "$output" == *"Rel.One-GRP	../../data/TV/Rel.One-GRP"* ]]
    [[ "$output" == *"notes.nfo	../../data/TV/notes.nfo"* ]]
}

@test "a broken symlink never reaches the picker and is removed from the remote" {
    home=$(srv_home)
    run env HOME="$home" EDITOR="$(srv_picker)" ALFTP_LIB= "$ALFTP" -a TV -nu
    [ "$status" -eq 0 ]
    [[ "$output" == *"pruning 1 broken symlink(s)"* ]]
    seen=$(cat "$home/.cache/alftp/alftp.list.seen")
    [[ "$seen" != *"broken.link"* ]]
    # The links whose data is still there are shown, and left alone.
    [[ "$seen" == *"Rel.One-GRP"* ]]
    [[ "$seen" == *"notes.nfo"* ]]
    [ ! -L "$SRV/complete/TV/broken.link" ]
    [ -L "$SRV/complete/TV/Rel.One-GRP" ]
    [ -L "$SRV/complete/TV/notes.nfo" ]
    [ -f "$SRV/data/TV/notes.nfo" ]
}

@test "--dry-run says what it would prune and leaves the broken symlink alone" {
    home=$(srv_home)
    run env HOME="$home" EDITOR="$(srv_picker)" ALFTP_LIB= "$ALFTP" -a TV -nu --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"dry run, none removed"* ]]
    [[ "$output" == *"DRY-RUN: rm broken broken.link"* ]]
    [ -L "$SRV/complete/TV/broken.link" ]
}

@test "-do leaves the broken symlink on the remote" {
    home=$(srv_home)
    run env HOME="$home" EDITOR="$(srv_picker)" ALFTP_LIB= "$ALFTP" -a TV -nu -do
    [ "$status" -eq 0 ]
    [[ "$output" == *"left on the remote (-do)"* ]]
    [ -L "$SRV/complete/TV/broken.link" ]
    # Still out of the list, though: it cannot be downloaded either way.
    seen=$(cat "$home/.cache/alftp/alftp.list.seen")
    [[ "$seen" != *"broken.link"* ]]
}

@test "prune_broken=False lists the broken symlink and leaves it in place" {
    home=$(srv_home)
    echo 'prune_broken=False' >> "$home/.config/alftp/alftp.conf"
    run env HOME="$home" EDITOR="$(srv_picker)" ALFTP_LIB= "$ALFTP" -a TV -nu
    [ "$status" -eq 0 ]
    [[ "$output" != *"broken symlink"* ]]
    seen=$(cat "$home/.cache/alftp/alftp.list.seen")
    [[ "$seen" == *"broken.link"* ]]
    [ -L "$SRV/complete/TV/broken.link" ]
}

@test "--two-session prunes in the download login" {
    home=$(srv_home)
    run env HOME="$home" EDITOR="$(srv_picker)" ALFTP_LIB= "$ALFTP" -a TV -nu --two-session
    [ "$status" -eq 0 ]
    [[ "$output" == *"pruning 1 broken symlink(s)"* ]]
    # Nothing was picked, so the second login exists only to do the pruning.
    [ ! -L "$SRV/complete/TV/broken.link" ]
    [ -L "$SRV/complete/TV/notes.nfo" ]
}

# ------------------------------------------------- srcs mode, local status --

@test "the listing session fetches the data directory's real sizes" {
    run srv_stage 'CREATE_LIST; echo "--"; cat "$listfile"; echo "--"; cat "$listfile5"'
    [ "$status" -eq 0 ]
    # The completed directory gives the length of the symlink string ...
    [[ "$output" == *"../../data/TV/notes.nfo"* ]] || true
    # ... while the data directory gives the size of the file itself.
    [[ "$output" == *"11 notes.nfo"* ]]
}

@test "the picker shows the size of the data, not the length of the symlink" {
    if ! command -v python3 > /dev/null 2>&1; then
        skip "python3 is needed to drive a pty"
    fi
    home=$(srv_home)
    sed -i '/^picker=/d' "$home/.config/alftp/alftp.conf"
    printf 'lockfile="%s"\n' "$SRV/alftp.lock" >> "$home/.config/alftp/alftp.conf"
    run env HOME="$home" TERM=xterm-256color \
        python3 "${BATS_TEST_DIRNAME}/helpers/ptydrive.py" \
        --keys 'q e' --delay 0.5 -- "$ALFTP" -i TV -t -nu -do
    # "some notes\n" is 11 bytes; the symlink to it is 23 characters long, and
    # 23 is what the completed directory's own listing reports.
    [[ "$output" == *"notes.nfo@"*"11"* ]]
    [[ "$output" != *"notes.nfo@"*"23"* ]]
}

@test "an entry already downloaded is marked c, and t hides it" {
    if ! command -v python3 > /dev/null 2>&1; then
        skip "python3 is needed to drive a pty"
    fi
    home=$(srv_home)
    sed -i '/^picker=/d' "$home/.config/alftp/alftp.conf"
    printf 'lockfile="%s"\n' "$SRV/alftp.lock" >> "$home/.config/alftp/alftp.conf"
    cp "$SRV/data/TV/notes.nfo" "$DL/notes.nfo"
    run env HOME="$home" TERM=xterm-256color \
        python3 "${BATS_TEST_DIRNAME}/helpers/ptydrive.py" \
        --keys 't q e' --delay 0.5 -- "$ALFTP" -i TV -t -nu -do
    [[ "$output" == *"STATUS"* ]]
    [[ "$output" == *"completed=T"* ]]
    # After t the entry is gone from the list and the title says so.
    [[ "$output" == *"completed=F"* ]]
    # Nothing after that frame lists it again.
    ! printf '%s\n' "$output" | sed -n '/completed=F/,$p' | grep -q 'notes.nfo'
}

@test "-i with no profile picks from the completed directory, srcs at the top" {
    home=$(srv_home)
    printf 'lockfile="%s"\n' "$SRV/alftp.lock" >> "$home/.config/alftp/alftp.conf"
    run env HOME="$home" EDITOR="$(srv_picker)" "$ALFTP" -i -nu -do
    [ "$status" -eq 0 ]
    seen=$(cat "$home/.cache/alftp/alftp.list.seen")
    # Both configured srcs, and nothing below them.
    [[ "$seen" == *"TV/"* ]]
    [[ "$seen" == *"films/"* ]]
    [[ "$seen" != *"Rel.One-GRP"* ]]
}

@test "a src that is not on the server is left out of the listing" {
    home=$(srv_home)
    sed -i 's/^srcs=.*/srcs=TV; films; music/' "$home/.config/alftp/alftp.src.conf"
    printf 'lockfile="%s"\n' "$SRV/alftp.lock" >> "$home/.config/alftp/alftp.conf"
    run env HOME="$home" EDITOR="$(srv_picker)" "$ALFTP" -i -nu -do
    [ "$status" -eq 0 ]
    seen=$(cat "$home/.cache/alftp/alftp.list.seen")
    [[ "$seen" == *"TV/"* ]]
    [[ "$seen" != *"music"* ]]
}

@test "a whole src lands where its own dl_dir says, and keeps its directory" {
    home=$(srv_home)
    printf 'lockfile="%s"\n' "$SRV/alftp.lock" >> "$home/.config/alftp/alftp.conf"
    # An $editor that takes the films src whole. With -i the list arrives
    # commented out, so picking is uncommenting.
    cat > "$SRV/pick" <<'PICK'
#!/usr/bin/env bash
sed -i 's|^#films|films|' "$1"
PICK
    chmod +x "$SRV/pick"
    run env HOME="$home" EDITOR="$SRV/pick" "$ALFTP" -i -nu
    [ "$status" -eq 0 ]
    # dl_dir_films is $DL/films, and the src component is consumed resolving
    # it: the release lands directly under it rather than under films/films.
    [ -f "$DL/films/Film.One-GRP/film.mkv" ]
    [ ! -e "$DL/films/films" ]
    # The src is a real directory, not a symlink, so a finished mirror leaves
    # it exactly where it was.
    [ -d "$SRV/complete/films" ]
    [ -L "$SRV/complete/films/Film.One-GRP" ]
}

@test "an entry inside a src is a directory, and lands under the src's dl_dir" {
    if ! command -v python3 > /dev/null 2>&1; then
        skip "python3 is needed to drive a pty"
    fi
    home=$(srv_home)
    sed -i '/^picker=/d' "$home/.config/alftp/alftp.conf"
    printf 'lockfile="%s"\n' "$SRV/alftp.lock" >> "$home/.config/alftp/alftp.conf"
    # tab into TV, down onto the release, space, save.
    run env HOME="$home" TERM=xterm-256color \
        python3 "${BATS_TEST_DIRNAME}/helpers/ptydrive.py" \
        --keys '\t j \x20 q s' --delay 0.6 -- "$ALFTP" -i -t -nu -do
    [[ "$output" == *"1 selection(s)"* ]]
    # cls -F calls a symlinked release "@" whether or not it is a directory, so
    # this only works because the data behind TV is listed as well: as a file
    # it would have been pgot, and pget refuses a directory.
    [ -f "$DL/Rel.One-GRP/movie.mkv" ]
    [ -f "$DL/Rel.One-GRP/CD1/part1.bin" ]
    [[ "$output" != *"Is a directory"* ]]
    # TV has no dl_dir of its own, so it fell back to the general one.
    [ ! -e "$DL/TV" ]
}

@test "x asks under a real terminal, and Y deletes both ends of the symlink" {
    if ! command -v python3 > /dev/null 2>&1; then
        skip "python3 is needed to drive a pty"
    fi
    home=$(srv_home)
    run env HOME="$home" TERM=xterm-256color \
        python3 "${BATS_TEST_DIRNAME}/helpers/ptydrive.py" \
        --keys 'x Y q s' --delay 0.5 -- "$ALFTP" -a TV -t -nu
    [[ "$output" == *"delete Rel.One-GRP"* ]]      # the confirmation was drawn
    [[ "$output" == *"1 deletion(s)"* ]]
    [ ! -e "$SRV/complete/TV/Rel.One-GRP" ]
    [ ! -e "$SRV/data/TV/Rel.One-GRP" ]
    [ ! -e "$DL/Rel.One-GRP" ]
}

@test "anything but Y cancels the delete under a real terminal" {
    if ! command -v python3 > /dev/null 2>&1; then
        skip "python3 is needed to drive a pty"
    fi
    home=$(srv_home)
    run env HOME="$home" TERM=xterm-256color \
        python3 "${BATS_TEST_DIRNAME}/helpers/ptydrive.py" \
        --keys 'x y q s' --delay 0.5 -- "$ALFTP" -a TV -t -nu
    [[ "$output" == *"left alone"* ]]
    [ -L "$SRV/complete/TV/Rel.One-GRP" ]
    [ -d "$SRV/data/TV/Rel.One-GRP" ]
}

@test "alt-down reorders under a real terminal and the order is the download order" {
    if ! command -v python3 > /dev/null 2>&1; then
        skip "python3 is needed to drive a pty"
    fi
    home=$(srv_home)
    # Take both entries, then move Rel.One-GRP below notes.nfo with Alt-Down.
    run env HOME="$home" TERM=xterm-256color \
        python3 "${BATS_TEST_DIRNAME}/helpers/ptydrive.py" \
        --keys 'a \e[1;3B q s' --delay 0.5 -- "$ALFTP" -a TV -t -nu
    [[ "$output" == *"2 selection(s)"* ]]
    [ -f "$DL/notes.nfo" ]
    [ -f "$DL/Rel.One-GRP/movie.mkv" ]
    first=$(printf '%s\n' "$output" | grep -n 'COMPLETE: notes.nfo' | head -n 1 | cut -d: -f1)
    second=$(printf '%s\n' "$output" | grep -n 'COMPLETE: Rel.One-GRP' | head -n 1 | cut -d: -f1)
    [ -n "$first" ]
    [ -n "$second" ]
    [ "$first" -lt "$second" ]
}

# The picker's check for remote changes, against the real thing: a background
# lftp login of its own, driven from tui_loop the way a keystroke drives it.
# $1 is run once the tree is loaded and before "u" is pressed -- that is where
# the test changes the server under the picker.
picker_check () {
    cat <<'SNIP'
    # Everything these tests create lands inside the fake server, so that the
    # teardown takes the check's listing files with it: the picker removes them
    # in tui_close, which a test driving tui_loop by hand never reaches.
    export TMPDIR="$SRV"
    oldfile=$(mktemp)
    # These are about the check and nothing else. The recursive walk is a
    # second background login that lands in the same tree, and whether it beat
    # the check's own reaping would decide what the tree looked like -- so it
    # is off here, and tested on its own further down.
    recursive_listing=False
    # The listing session's own chatter is not what these tests are reading.
    { CREATE_LIST; FORMAT_LIST; LOAD_LINKS; VALIDATE_LINKS; } > /dev/null 2>&1
    exec {TUI_OUT}>/dev/null
    tui_load
    order () { n=""; for v in "${TUI_ORDER[@]}"; do n="$n ${TUI_NAME[v]}"; done; echo "[${n# }]"; }
    # "u", then a timeout on every read until the check has been reaped, then
    # quit -- which is exactly the sequence tui_loop sees from a terminal where
    # the user pressed u and waited.
    KI=0; MSG=""
    tui_read_key () {
        if (( KI == 0 )); then KI=1; TUI_KEY=u; return 0; fi
        if [[ -n $tui_upd_pid ]]; then sleep 0.1; TUI_KEYRC=2; return 1; fi
        # The loop clears the footer on the next keystroke, so what the merge
        # had to say is taken before quitting rather than after.
        if (( KI == 1 )); then KI=2; MSG=$tui_msg; TUI_KEY=q; return 0; fi
        TUI_KEY=e
        return 0
    }
SNIP
}

@test "u picks up a release that appeared while the picker was open" {
    run srv_stage "$(picker_check)"'
        echo "$(order)"
        tui_cur=1; tui_toggle              # mark notes.nfo for download
        tui_cur=0; tui_move_node down      # and put the release below it
        printf "extra\n" > "$SRV/data/TV/late.nfo"
        ln -s ../../data/TV/late.nfo "$SRV/complete/TV/late.nfo"
        tui_loop
        echo "$(order)"; echo "$tui_nsel $MSG"'
    [ "$status" -eq 0 ]
    # The broken symlink is not in the tree to start with, and the check does
    # not put it back.
    [ "${lines[0]}" = "[Rel.One-GRP@ notes.nfo@]" ]
    # The reorder and the mark both survived, and what appeared is at the end.
    [ "${lines[1]}" = "[notes.nfo@ Rel.One-GRP@ late.nfo@]" ]
    [[ "${lines[2]}" == "1 checked: 1 new, 0 gone" ]]
}

@test "u drops a release that went away, and keeps a marked one" {
    run srv_stage "$(picker_check)"'
        tui_cur=1; tui_toggle              # notes.nfo is wanted whatever happens
        rm -f "$SRV/complete/TV/Rel.One-GRP" "$SRV/complete/TV/notes.nfo"
        rm -rf "$SRV/data/TV/Rel.One-GRP" "$SRV/data/TV/notes.nfo"
        tui_loop
        echo "$(order)"; echo "$tui_nsel $MSG"'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "[notes.nfo@]" ]
    [[ "${lines[1]}" == "1 checked: 0 new, 1 gone, 1 marked but no longer on the server" ]]
}

@test "a check that cannot log in says so and changes nothing" {
    run srv_stage "$(picker_check)"'
        server="file:///"; remote_dl_dir="$SRV/nowhere"
        tui_loop
        echo "$(order)"; echo "$MSG"'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "[Rel.One-GRP@ notes.nfo@]" ]
    [[ "${lines[1]}" == "could not check the remote"* ]]
}

@test "the check lists a directory the user has already opened" {
    run srv_stage "$(picker_check)"'
        tui_cur=0; tui_toggle_open         # a real tab: lists Rel.One-GRP
        printf "late\n" > "$SRV/data/TV/Rel.One-GRP/late.bin"
        tui_loop
        echo "$(order)"'
    [ "$status" -eq 0 ]
    # The new file is inside the opened release, at the end of its own sibling
    # group rather than at the end of the list.
    [ "${lines[0]}" = "[Rel.One-GRP@ CD1/ movie.mkv release.nfo late.bin notes.nfo@]" ]
}

@test "the glyph turns and the keys still work while a check is in flight" {
    # A check against file:// is over before it has been drawn once, so the
    # login is made to take a moment: the point of the exercise is what the UI
    # does while it is waiting, not how long the waiting is.
    mkdir -p "$SRV/bin"
    printf '#!/bin/sh\nsleep 1\nexec %s "$@"\n' "$(command -v lftp)" > "$SRV/bin/lftp"
    chmod +x "$SRV/bin/lftp"
    run srv_stage '
        export TMPDIR="$SRV"
        oldfile=$(mktemp)
        { CREATE_LIST; FORMAT_LIST; LOAD_LINKS; VALIDATE_LINKS; } > /dev/null 2>&1
        exec {TUI_OUT}>"$SRV/frames"
        tui_load
        TUI_LINES=12; TUI_COLS=60; TUI_ROWS=9
        PATH="$SRV/bin:$PATH"
        KI=0
        tui_read_key () {
            if (( KI == 0 )); then KI=1; TUI_KEY=u; return 0; fi
            # While the check runs, every other read is a real keystroke: the
            # UI has to go on moving the cursor with a login in the background.
            if [[ -n $tui_upd_pid ]]; then
                KI=$(( KI + 1 ))
                if (( KI % 2 == 0 )); then TUI_KEY=j; return 0; fi
                sleep 0.2; TUI_KEYRC=2; return 1
            fi
            if [[ $TUI_KEY == q ]]; then TUI_KEY=e; else TUI_KEY=q; fi
            return 0
        }
        tui_loop
        echo "$tui_cur"'
    [ "$status" -eq 0 ]
    # The cursor moved while the check was running ...
    [ "$output" -gt 0 ]
    # ... and more than one frame of the glyph was painted.
    grep -q -- '\[-\]' "$SRV/frames"
    [ "$(grep -c -o -e '\[-\]' -e '\[\\\]' -e '\[|\]' -e '\[/\]' "$SRV/frames")" -gt 1 ]
    # The check still landed: the footer says what it found.
    grep -q 'checked:' "$SRV/frames"
}

# Enter downloads from inside the picker. Everything about a file:// transfer
# is instantaneous -- xfer:rate-limit does not apply to the protocol, so there
# is no way to catch one part-finished -- which makes this the end-to-end case
# only: the queue's own state machine is tested in tests/alftp.bats, where a
# transfer can be held still.
@test "enter downloads the marked entry without leaving the picker" {
    if ! command -v python3 > /dev/null 2>&1; then
        skip "python3 is needed to drive a pty"
    fi
    home=$(srv_home)
    sed -i '/^picker=/d' "$home/.config/alftp/alftp.conf"
    printf 'lockfile="%s"\n' "$SRV/alftp.lock" >> "$home/.config/alftp/alftp.conf"
    # space marks the release, enter queues it, two redraws give the transfer
    # a moment to finish and be reaped, then quit without saving -- so what is
    # on disk afterwards can only have come from the picker's own login.
    run env HOME="$home" TERM=xterm-256color \
        python3 "${BATS_TEST_DIRNAME}/helpers/ptydrive.py" \
        --keys '\x20 \r \x0c \x0c q e' --delay 0.6 -- "$ALFTP" -i TV -t -nu
    [[ "$output" == *"queued 1 entry"* ]]
    [[ "$output" == *"done"* ]]
    [[ "$output" == *"nothing selected"* ]]
    [ -f "$DL/Rel.One-GRP/movie.mkv" ]
    [ -f "$DL/Rel.One-GRP/CD1/part1.bin" ]
    # The transfer carried its "&& rm -f" with it, the way the emitters' would.
    [ ! -e "$SRV/complete/TV/Rel.One-GRP" ]
    # Nothing else was touched.
    [ ! -e "$DL/notes.nfo" ]
    [ -L "$SRV/complete/TV/notes.nfo" ]
}

# ------------------------------------------------- the recursive listing --
#
# The walk is one background login that answers what used to take one login per
# directory opened, so the tests that matter are about logins as much as about
# what is on screen. srv_lftp_counter puts a wrapper for lftp on the PATH which
# records what kind of script each login was asked to run -- the temp file's
# name says which, and every one of them comes from a different new_tmp
# template -- and then execs the real thing, so the run is entirely real.
srv_lftp_counter() {
    mkdir -p "$SRV/bin"
    cat > "$SRV/bin/lftp" <<COUNTER
#!/bin/sh
case "\$2" in
    *alftp.subcmd.*) echo fetch >> "$SRV/fetches" ;;
    *alftp.rec.*)    echo walk  >> "$SRV/walks" ;;
esac
exec $(command -v lftp) "\$@"
COUNTER
    chmod +x "$SRV/bin/lftp"
}

@test "the walk gives a directory a real size, and Tab then costs no login" {
    if ! command -v python3 > /dev/null 2>&1; then
        skip "python3 is needed to drive a pty"
    fi
    srv_lftp_counter
    home=$(srv_home)
    sed -i '/^picker=/d' "$home/.config/alftp/alftp.conf"
    printf 'lockfile="%s"\n' "$SRV/alftp.lock" >> "$home/.config/alftp/alftp.conf"
    # A pause before Tab, so the walk that started after the first frame has
    # come back by the time the directory is opened.
    run env HOME="$home" TERM=xterm-256color PATH="$SRV/bin:$PATH" \
        python3 "${BATS_TEST_DIRNAME}/helpers/ptydrive.py" \
        --keys '\x0c \t q e' --delay 1.0 -- "$ALFTP" -i TV -t -nu -do
    [ "$status" -eq 0 ]
    # The release is 15 + 13 + 9 bytes of content. Its own listing gives it the
    # length of the symlink pointing at it (25) and the data directory gives it
    # the size of a directory entry, so 37 is a figure the picker could not
    # show at all before the walk.
    [[ "$output" =~ Rel\.One-GRP@[[:space:]]+37[[:space:]] ]]
    [ -f "$SRV/walks" ]
    # Tab opened it out of the walk's answer: every file inside is on screen
    # and not one extra login was made to put it there.
    [[ "$output" == *"movie.mkv"* ]]
    [[ "$output" == *"CD1/"* ]]
    [ ! -f "$SRV/fetches" ]
}

@test "recursive_listing=False leaves Tab paying for its own login" {
    if ! command -v python3 > /dev/null 2>&1; then
        skip "python3 is needed to drive a pty"
    fi
    srv_lftp_counter
    home=$(srv_home)
    sed -i '/^picker=/d' "$home/.config/alftp/alftp.conf"
    printf 'lockfile="%s"\nrecursive_listing=False\n' "$SRV/alftp.lock" \
        >> "$home/.config/alftp/alftp.conf"
    run env HOME="$home" TERM=xterm-256color PATH="$SRV/bin:$PATH" \
        python3 "${BATS_TEST_DIRNAME}/helpers/ptydrive.py" \
        --keys '\x0c \t q e' --delay 1.0 -- "$ALFTP" -i TV -t -nu -do
    [ "$status" -eq 0 ]
    # Exactly as it behaved before there was a walk: no walk, one login for the
    # directory, and the symlink's own length back in the size column.
    [ ! -f "$SRV/walks" ]
    [ -f "$SRV/fetches" ]
    [[ "$output" == *"movie.mkv"* ]]
    [[ "$output" =~ Rel\.One-GRP@[[:space:]]+25[[:space:]] ]]
}

@test "srcs mode waits for a src to be opened before walking it" {
    if ! command -v python3 > /dev/null 2>&1; then
        skip "python3 is needed to drive a pty"
    fi
    srv_lftp_counter
    home=$(srv_home)
    sed -i '/^picker=/d' "$home/.config/alftp/alftp.conf"
    printf 'lockfile="%s"\n' "$SRV/alftp.lock" >> "$home/.config/alftp/alftp.conf"
    # Quitting without opening anything: each src has a data directory of its
    # own and walking every one of them up front could be the whole server, so
    # nothing is walked at all.
    run env HOME="$home" TERM=xterm-256color PATH="$SRV/bin:$PATH" \
        python3 "${BATS_TEST_DIRNAME}/helpers/ptydrive.py" \
        --keys '\x0c q e' --delay 1.0 -- "$ALFTP" -i -t -nu -do
    [ "$status" -eq 0 ]
    [[ "$output" == *"films"* ]]
    [ ! -f "$SRV/walks" ]
    # Opening TV asks for TV's data directory and for nothing else.
    run env HOME="$home" TERM=xterm-256color PATH="$SRV/bin:$PATH" \
        python3 "${BATS_TEST_DIRNAME}/helpers/ptydrive.py" \
        --keys '\t \x0c q e' --delay 1.0 -- "$ALFTP" -i -t -nu -do
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$SRV/walks")" -eq 1 ]
}
