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
