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
