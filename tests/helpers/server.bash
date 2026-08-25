#!/usr/bin/env bash
#
# A "remote" for the tests to talk to, without a server: lftp speaks file://,
# and every command alftp generates (open with credentials, cd, cls, ls, mirror,
# pget, rm, "!") works against it exactly as it does over FTP. That makes the
# parts of the script that were previously only testable against a scratch
# server -- CREATE_LIST, SINGLE_SESSION, DLDR/DLFL/DLRM, the emit file -- real
# integration tests.
#
# The tree is laid out the way alftp assumes a server is: data/ holds the real
# files, complete/ holds symlinks into it, and one of those symlinks is broken.
#
#   $SRV/data/TV/Rel.One-GRP/{CD1/part1.bin,movie.mkv,release.nfo}
#   $SRV/data/TV/notes.nfo
#   $SRV/complete/TV/{Rel.One-GRP@,notes.nfo@,broken.link@}
#   $DL                                    <- local download directory

# Create the fake remote. Sets $SRV (its root) and $DL (the local side).
srv_setup () {
    SRV=$(mktemp -d "${TMPDIR:-/tmp}/alftp-srv.XXXXXX")
    DL="$SRV/local"
    mkdir -p "$SRV/data/TV/Rel.One-GRP/CD1" "$SRV/complete/TV" "$DL"
    printf 'movie contents\n' > "$SRV/data/TV/Rel.One-GRP/movie.mkv"
    printf 'release info\n'   > "$SRV/data/TV/Rel.One-GRP/release.nfo"
    printf 'part one\n'       > "$SRV/data/TV/Rel.One-GRP/CD1/part1.bin"
    printf 'some notes\n'     > "$SRV/data/TV/notes.nfo"
    ln -s ../../data/TV/Rel.One-GRP "$SRV/complete/TV/Rel.One-GRP"
    ln -s ../../data/TV/notes.nfo   "$SRV/complete/TV/notes.nfo"
    ln -s ../../data/TV/gone.mkv    "$SRV/complete/TV/broken.link"
}

srv_teardown () {
    if [[ -n ${SRV:-} ]] && [[ -d $SRV ]]; then
        rm -rf "$SRV"
    fi
}

# The globals a stage needs to talk to it, for tests that source alftp with
# ALFTP_LIB=1 and call one function directly. file:/// plus an absolute cd is
# what keeps this identical in shape to a real login.
srv_globals () {
    cat <<'SNIP'
    server="file:///"; username=""; password=""; port=""
    complete_dir="$SRV/complete/"; data_dir="$SRV/data/"
    local_dl_dir="$DL"; dirname="TV"
    remote_dl_dir="$SRV/complete/TV"
    listfile="$SRV/list"; listfile2="$SRV/list2"; listfile3=""
    listfile4="$SRV/list4"
    logfile="$SRV/xfer.log"
SNIP
}

# A throwaway $HOME with a config and the two profile blocks pointing at the
# fake remote, for tests that run the whole script rather than one stage. The
# split is the one a real alftp.src.conf has: the block carrying dl_dir is
# selected by hostname (the local pass), the block carrying the server settings
# by default_server (the remote pass) -- one block holding both would have its
# dl_dir read as the *remote* directory too.
srv_home () {
    mkdir -p "$SRV/home/.config/alftp" "$SRV/home/.cache/alftp"
    cat > "$SRV/home/.config/alftp/alftp.conf" <<CONF
listfile="$SRV/home/.cache/alftp/alftp.list"
logfile="$SRV/home/.cache/alftp/alftp.log"
picker=editor
CONF
    cat > "$SRV/home/.config/alftp/alftp.src.conf" <<CONF
default_server=testsrv

[$(hostname)|localhostname]
dl_dir='$DL'

[|testsrv]
server='file:///'
username='u'
password='p'
port=21
data_dir='$SRV/data/'
complete_dir='$SRV/complete/'
srcs=TV; films
CONF
    printf '%s' "$SRV/home"
}
