#!/usr/bin/env bats
#
# Tests for the pure-parsing stages of alftp: the ARGSB/ARGSC flag passes and
# the alftp.src.conf profile evaluation. None of these need a live server.
#
# Sourcing alftp with ALFTP_LIB set defines the functions without running MAIN,
# so each test drives one stage in a throwaway bash -c subshell (they all exit
# or mutate globals, so isolation matters).

setup() {
    ALFTP="${BATS_TEST_DIRNAME}/../alftp"
    FIXTURE="${BATS_TEST_DIRNAME}/fixtures/alftp.src.conf"
}

# $1 = bash snippet run after alftp has been sourced. "$FIXTURE" is available
# to the snippet as $fixture.
stage() {
    bash -c 'ALFTP_LIB=1 source "$1"; fixture="$2"; eval "$3"' _ "$ALFTP" "$FIXTURE" "$1"
}

@test "-ld and -rd set the destination and source flags" {
    run stage 'ARGSC -s example.com -u u -p pw -P 21 -ld /local -rd /remote
               echo "dest=$destflag source=$sourceflag rd=$remote_dl_dir"'
    [ "$status" -eq 0 ]
    [ "$output" = "dest=1 source=1 rd=/remote" ]
}

@test "-ld without -rd complains about the missing source" {
    run stage 'ARGSC -ld /local'
    [[ "$output" == *"Please specify source"* ]]
}

@test "-rd without -ld complains about the missing destination" {
    run stage 'ARGSC -rd /remote'
    [[ "$output" == *"Please specify desitnation"* ]]
}

@test "a profile with only data_dir builds the remote path from data_dir" {
    run stage 'data_dir=/data/; ARGSC -ld /l -rd docs; echo "$remote_dl_dir"'
    [ "$output" = "/data/docs" ]
}

@test "complete_dir wins over data_dir when both are set" {
    run stage 'complete_dir=/complete/; data_dir=/data/
               ARGSC -ld /l -rd docs; echo "$remote_dl_dir"'
    [ "$output" = "/complete/docs" ]
}

@test "-d selects data_dir even when complete_dir is set" {
    run stage 'complete_dir=/complete/; data_dir=/data/
               ARGSC -d -ld /l -rd docs; echo "$remote_dl_dir"'
    [ "$output" = "/data/docs" ]
}

@test "--dry-run is accepted and sets dry_run" {
    run stage 'ARGSC -ld /l -rd d --dry-run; echo "dry=$dry_run"'
    [ "$output" = "dry=True" ]
}

@test "-i substitutes @profile and falls back to the profile name for the remote dir" {
    run stage 'local_dl_dir=/dl/@profile/new; ARGSB -i docs
               echo "$local_dl_dir $remote_dl_dir $destflag$sourceflag"'
    [ "$output" = "/dl/docs/new docs 11" ]
}

@test "-a keeps a remote_dl_dir supplied by the profile and still marks the source" {
    run stage 'remote_dl_dir=from_profile; ARGSB -a docs
               echo "$remote_dl_dir $destflag$sourceflag"'
    [ "$output" = "from_profile 11" ]
}

@test "dl_dir_<profile> overrides the general dl_dir for that profile only" {
    run stage 'local_dl_dir=/dl/@profile/new; local_dl_dir_TV=/mnt/media/TV
               ARGSB -a TV; echo "$local_dl_dir"'
    [ "$output" = "/mnt/media/TV" ]

    run stage 'local_dl_dir=/dl/@profile/new; local_dl_dir_TV=/mnt/media/TV
               ARGSB -a docs; echo "$local_dl_dir"'
    [ "$output" = "/dl/docs/new" ]
}

@test "a per-profile dl_dir may itself use @profile" {
    run stage 'local_dl_dir=/dl/@profile; local_dl_dir_TV=/mnt/@profile/hd
               ARGSB -i TV; echo "$local_dl_dir"'
    [ "$output" = "/mnt/TV/hd" ]
}

@test "remote_dl_dir_<profile> beats falling back to the profile name" {
    run stage 'remote_dl_dir_TV=/srv/tv; ARGSB -a TV; echo "$remote_dl_dir"'
    [ "$output" = "/srv/tv" ]
}

@test "a profile name that is not an identifier maps to the sanitised key" {
    run stage 'local_dl_dir=/dl/@profile; local_dl_dir_tv_shows=/mnt/tv-shows
               ARGSB -a tv-shows; echo "$local_dl_dir"'
    [ "$output" = "/mnt/tv-shows" ]
}

@test "-ld still overrides a per-profile dl_dir" {
    run stage 'local_dl_dir_TV=/mnt/media/TV; ARGSB -a TV
               ARGSC -a TV -ld /cli; echo "$local_dl_dir"'
    [ "$output" = "/cli" ]
}

@test "eval_local_config renames dl_dir_<profile> to local_dl_dir_<profile>" {
    run stage 'hostname() { echo testhost; }; configsrc="$fixture"
               eval_local_config
               echo "[$local_dl_dir] [${local_dl_dir_TV:-}]"'
    [ "$output" = "[/tmp/alftp-test/important] [/tmp/alftp-test/tv]" ]
}

@test "--two-session selects the two-login path" {
    run stage 'ARGSC -ld /l -rd d --two-session; echo "two=$two_session"'
    [ "$output" = "two=True" ]
}

@test "open_cmd quotes credentials for lftp and omits them when there is no user" {
    run stage 'username="us\"er"; password="pa,ss:word"; port=2121
               server=example.com; open_cmd
               username=""; open_cmd'
    [ "${lines[0]}" = 'open --user "us\"er" --password "pa,ss:word" -p "2121" "example.com"' ]
    [ "${lines[1]}" = 'open -p "2121" "example.com"' ]
}

@test "sh_quote survives a single quote" {
    run stage 'sh_quote "it'"'"'s here"'
    [ "$output" = "'it'\\''s here'" ]
}

@test "the single-session script lists, shells out and sources what the helper wrote" {
    run stage 'run_lftp_script() { cat "$1"; }   # capture instead of running lftp
               server=example.com; username=u; password=p; port=21
               remote_dl_dir=/complete/docs; data_dir=/data/; dirname=docs
               listfile=/tmp/alftp-test-list; listfile2=/tmp/alftp-test-list2
               self=/usr/local/bin/alftp; ARGV=(-i docs)
               SINGLE_SESSION'
    [ "$status" -eq 0 ]
    # one login for the whole run: a single open, then listing, helper, download
    [ "$(grep -c "^open " <<< "$output")" -eq 1 ]
    [[ "$output" == *"set net:idle never"* ]]          # survive the editor pause
    [[ "$output" == *'--size --date'*'> "/tmp/alftp-test-list"'* ]]
    [[ "$output" == *'cls -1 > "/tmp/alftp-test-list2"'* ]]
    [[ "$output" == *"!env ALFTP_EMIT_DL="*"ALFTP_ARGV="*"bash '/usr/local/bin/alftp'"* ]]
    [[ "$output" == *'source "'* ]]
}

@test "the helper stage re-parses argv from a file and reproduces the globals" {
    argvfile=$(mktemp)
    printf '%s\0' -ld /l -rd docs --dry-run > "$argvfile"
    run bash -c 'ALFTP_LIB=1 source "$1"; load_argv "$2"; ARGSC "${ARGV[@]}"
                 echo "$local_dl_dir $remote_dl_dir $dry_run"' _ "$ALFTP" "$argvfile"
    rm -f "$argvfile"
    [ "$output" = "/l docs True" ]
}

@test "eval_local_config keeps local keys whose values contain a remote key name" {
    run stage 'hostname() { echo testhost; }; configsrc="$fixture"
               eval_local_config
               echo "ld=[$local_dl_dir] port=[$port] user=[$username]"'
    # '/tmp/alftp-test/imPORTant' must survive the remote-key filter, and the
    # remote-only keys must not leak into the local config.
    [ "$output" = "ld=[/tmp/alftp-test/important] port=[] user=[]" ]
}

@test "eval_remote_config matches default_server literally, not as a regex" {
    run stage 'configsrc="$fixture"; eval_remote_config
               echo "rd=[$remote_dl_dir] port=[$port] srv=[$default_server]"'
    # The fixture also contains an [thirdhost|exampleXcom] block, which an
    # unescaped '.' in "example.com" would match instead.
    [ "$output" = "rd=[/tmp/alftp-test/important] port=[2222] srv=[example.com]" ]
}

@test "-t and -e choose the picker, later flags winning" {
    run stage 'ARGSC -ld /local -rd /remote --tui; echo "$picker"'
    [ "$output" = "tui" ]
    run stage 'ARGSC -ld /local -rd /remote -t -e; echo "$picker"'
    [ "$output" = "editor" ]
    run stage 'ARGSC -ld /local -rd /remote; echo "[$picker]"'
    [ "$output" = "[]" ]
}

@test "tui_usable refuses a terminal that cannot drive the UI" {
    run stage 'picker=editor; tui_usable; echo "$?: $tui_why"'
    [ "$output" = "1: picker is set to editor" ]
    # bats runs without a terminal, which is itself a reason to fall back.
    run stage 'TERM=dumb; tui_usable; echo "$?: $tui_why"'
    [ "$output" = "1: TERM is unset or dumb" ]
}

@test "pick_list falls back to the editor, commenting the list out for -i" {
    listfile=$(mktemp)
    log=$(mktemp)
    stub=$(mktemp)
    printf '%s\n' 'file1  4.0K  2026-08-23 17:10' 'file2   753  2026-08-23 14:42' > "$listfile"
    # A stub $editor that records the file it was handed and prints nothing:
    # anything it wrote to stdout would land in $output ahead of the list.
    printf '#!/bin/sh\nprintf %%s "$1" > %s\n' "$log" > "$stub"
    chmod +x "$stub"
    run stage 'listfile="'"$listfile"'"; ind_files=True; picker=editor
               editor="'"$stub"'"
               pick_list; cat "$listfile"'
    [ "$(cat "$log")" = "$listfile" ]
    # -i hands the editor a fully commented list for the user to uncomment.
    [ "${lines[0]}" = "#file1  4.0K  2026-08-23 17:10" ]
    [ "${lines[1]}" = "#file2   753  2026-08-23 14:42" ]
    rm -f "$listfile" "$log" "$stub"
}

# A small tree, built the way tui_fetch would: three top-level entries, the
# first one opened with a subdirectory and two files under it.
# Node ids run in creation order -- 0,1,2 are the top level and 3,4,5 the
# children -- while the cursor counts visible rows:
#   row 0 Rel.One-GRP@  1 CD1/  2 movie.mkv  3 movie.nfo  4 Rel.Two-GRP@  5 notes.nfo
tree () {
    cat <<'SNIP'
    exec {TUI_OUT}>/dev/null
    listfile=$(mktemp); listfile2=$(mktemp)
    printf '%s\n' 'Rel.One-GRP@   4.1G  2026-08-23 17:10' \
                  'Rel.Two-GRP@   2.7G  2026-08-23 14:42' \
                  'notes.nfo      2.1K  2026-08-22 09:03' > "$listfile"
    printf '%s\n' 'Rel.One-GRP/' 'Rel.Two-GRP/' 'notes.nfo' > "$listfile2"
    tui_load
    tui_kidsnew=()
    tui_add_node 'CD1/'      ''     '2026-08-23 17:10' 0 1; tui_kidsnew+=("$tui_new_id")
    tui_add_node 'movie.mkv' '4.0G' '2026-08-23 17:10' 0 0; tui_kidsnew+=("$tui_new_id")
    tui_add_node 'movie.nfo' '2.1K' '2026-08-23 17:10' 0 0; tui_kidsnew+=("$tui_new_id")
    TUI_ORDER=("${TUI_ORDER[@]:0:1}" "${tui_kidsnew[@]}" "${TUI_ORDER[@]:1}")
    TUI_LOADED[0]=1; TUI_OPEN[0]=1
    tui_reindex; tui_rebuild_vis; tui_widths
    TUI_LINES=12; TUI_COLS=60; TUI_ROWS=9; remote_dl_dir=/remote
    marks () { m=""; for v in "${TUI_VIS[@]}"; do tui_marker "$v"; m="$m$tui_mark"; done; echo "[$m]"; }
    names () { n=""; for v in "${TUI_VIS[@]}"; do n="$n ${TUI_NAME[v]}"; done; echo "[${n# }]"; }
SNIP
}

@test "tui_load reads the top level and takes the types from listfile2" {
    run stage "$(tree)"'
        echo "$TUI_N ${TUI_ISDIR[0]}${TUI_ISDIR[1]}${TUI_ISDIR[2]} ${TUI_STATE[0]}${TUI_STATE[1]}${TUI_STATE[2]}"'
    # Six rows visible (three top level, three children), the two symlinked
    # releases are directories, everything starts deselected.
    [ "$output" = "6 110 000" ]
}

@test "a directory with no size keeps its date in the date column" {
    # Most FTP servers report no size for a directory, so the size field of its
    # record is empty. The fields are separated by \037 rather than by a tab
    # precisely so that empty field survives being read back: tab is IFS
    # whitespace, so `IFS=$'\t' read nm sz dt` folds the two delimiters into
    # one, the date lands in $sz and $dt comes up empty -- which showed up as
    # dates drawn in the SIZE column, and then as directory dates vanishing
    # entirely once the recursive walk overwrote the size the date was sitting
    # in.
    listfile=$(mktemp); listfile2=$(mktemp)
    printf '%s\n' 'Some.Release-GRP/       2026-08-23 14:42' \
                  'somefile.mkv     4.0K  2026-08-22 09:03' > "$listfile"
    printf '%s\n' 'Some.Release-GRP/' 'somefile.mkv' > "$listfile2"
    run stage 'exec {TUI_OUT}>/dev/null
               listfile="'"$listfile"'"; listfile2="'"$listfile2"'"; listfile5=""
               tui_load
               echo "dir  size=[${TUI_SIZE[0]}] date=[${TUI_DATE[0]}]"
               echo "file size=[${TUI_SIZE[1]}] date=[${TUI_DATE[1]}]"'
    rm -f "$listfile" "$listfile2"
    [ "${lines[0]}" = "dir  size=[] date=[2026-08-23 14:42]" ]
    [ "${lines[1]}" = "file size=[4.0K] date=[2026-08-22 09:03]" ]
}

@test "a path below the top level drops the listing's classifier" {
    run stage "$(tree)"'
        echo "${TUI_PATH[0]} | ${TUI_PATH[3]} | ${TUI_PATH[4]}"'
    [ "$output" = "Rel.One-GRP@ | Rel.One-GRP/CD1/ | Rel.One-GRP/movie.mkv" ]
}

@test "one file picked inside a directory marks the directory *" {
    run stage "$(tree)"'
        tui_cur=2; tui_toggle; marks; echo "$tui_nsel"'
    [ "${lines[0]}" = "[* +   ]" ]
    [ "${lines[1]}" = "1" ]
}

@test "space on a * directory takes the whole selection back" {
    run stage "$(tree)"'
        tui_cur=2; tui_toggle; tui_cur=0; tui_toggle; marks; echo "$tui_nsel"'
    [ "${lines[0]}" = "[      ]" ]
    [ "${lines[1]}" = "0" ]
}

@test "space on a directory takes all of it, and its children show it" {
    run stage "$(tree)"'
        tui_cur=0; tui_toggle; marks; echo "$tui_nsel"'
    [ "${lines[0]}" = "[++++  ]" ]
    # One selection, not four: the directory is mirrored whole.
    [ "${lines[1]}" = "1" ]
}

@test "taking one child back out of a whole directory splits it" {
    run stage "$(tree)"'
        tui_cur=0; tui_toggle; tui_cur=3; tui_toggle; marks; echo "$tui_nsel"'
    [ "${lines[0]}" = "[*++   ]" ]
    [ "${lines[1]}" = "2" ]
}

@test "d marks the source symlink, and only at the top level" {
    run stage "$(tree)"'
        tui_cur=4; tui_mark_remove; marks; echo "$tui_nrm"
                        tui_cur=2; tui_msg=""; tui_mark_remove; echo "$tui_msg"
                        tui_cur=4; tui_mark_remove; marks; echo "$tui_nrm"'
    [ "${lines[0]}" = "[    - ]" ]
    [ "${lines[1]}" = "1" ]
    [ "${lines[2]}" = "only a top-level entry has a symlink to remove" ]
    [ "${lines[3]}" = "[      ]" ]
    [ "${lines[4]}" = "0" ]
}

@test "a and A work on the selection and leave the unlink marks alone" {
    run stage "$(tree)"'
        tui_cur=4; tui_mark_remove
                        tui_set_all 1; marks; echo "$tui_nsel/$tui_nrm"
                        tui_set_all 0; marks; echo "$tui_nsel/$tui_nrm"'
    [ "${lines[0]}" = "[++++-+]" ]
    [ "${lines[1]}" = "2/1" ]
    [ "${lines[2]}" = "[    - ]" ]
    [ "${lines[3]}" = "0/1" ]
}

@test "tui_save writes a marker per line and nested paths in full" {
    run stage "$(tree)"'
        tui_cur=0; tui_toggle; tui_cur=3; tui_toggle
                        tui_cur=4; tui_mark_remove; tui_save; cat "$listfile"'
    # The directory is partial, so it is "*" and its selected children are
    # listed under it; movie.nfo was taken back out, so it is not written.
    [ "${lines[0]}" = "*Rel.One-GRP@           4.1G  2026-08-23 17:10" ]
    [ "${lines[1]}" = "+Rel.One-GRP/CD1/             2026-08-23 17:10" ]
    [ "${lines[2]}" = "+Rel.One-GRP/movie.mkv  4.0G  2026-08-23 17:10" ]
    [ "${lines[3]}" = "-Rel.Two-GRP@           2.7G  2026-08-23 14:42" ]
    [ "${lines[4]}" = "#notes.nfo              2.1K  2026-08-22 09:03" ]
}

@test "tui_widths counts the indentation of nested names" {
    run stage "$(tree)"'
        echo "$tui_namew $tui_sizew"'
    # "  movie.mkv" is 11, "Rel.One-GRP@" is 12.
    [ "$output" = "12 4" ]
}

@test "TYPE splits the picked list into mirrors, pgets and unlinks" {
    listfile=$(mktemp); listfile2=$(mktemp)
    # Two spaces before the size column, which is what FORMAT_LIST and
    # tui_save always write: strip_columns needs them to tell the columns from
    # a name that has spaces in it.
    printf '%s\n' '*Rel.One-GRP@          4.1G  2026-08-23 17:10' \
                  '+Rel.One-GRP/CD1/            2026-08-23 17:10' \
                  '+Rel.One-GRP/movie.mkv  4.0G  2026-08-23 17:10' \
                  '-Rel.Two-GRP@          2.7G  2026-08-23 14:42' \
                  '#notes.nfo             2.1K  2026-08-22 09:03' > "$listfile"
    printf '%s\n' 'Rel.One-GRP/' 'Rel.Two-GRP/' 'notes.nfo' > "$listfile2"
    run stage 'listfile="'"$listfile"'"; listfile2="'"$listfile2"'"; TYPE
               echo "D=[$LINESD]"; echo "F=[$LINESF]"; echo "R=[$LINESR]"'
    rm -f "$listfile" "$listfile2"
    # The "*" line is a container, not a download; the nested paths keep their
    # directories and the "-" line only loses its symlink.
    [ "${lines[0]}" = "D=[Rel.One-GRP/CD1]" ]
    [ "${lines[1]}" = "F=[Rel.One-GRP/movie.mkv]" ]
    [ "${lines[2]}" = "R=[Rel.Two-GRP]" ]
}

@test "TYPE still reads a hand-edited list with no markers" {
    listfile=$(mktemp); listfile2=$(mktemp)
    printf '%s\n' 'Rel.One-GRP@   4.1G  2026-08-23 17:10' \
                  '#notes.nfo      2.1K  2026-08-22 09:03' \
                  'other.nfo       753  2026-08-22 09:03' > "$listfile"
    printf '%s\n' 'Rel.One-GRP/' 'notes.nfo' 'other.nfo' > "$listfile2"
    run stage 'listfile="'"$listfile"'"; listfile2="'"$listfile2"'"; TYPE
               echo "D=[$LINESD] F=[$LINESF] R=[$LINESR]"'
    rm -f "$listfile" "$listfile2"
    [ "$output" = "D=[Rel.One-GRP] F=[other.nfo] R=[]" ]
}

@test "a nested download keeps the remote structure and the symlink" {
    run stage 'LINESD="Rel.One-GRP/CD1"; LINESF="Rel.One-GRP/movie.mkv"
               local_dl_dir=/dl; logfile=/dl/log; DLDR; DLFL'
    [ "${lines[0]}" = 'mirror -c -P5 --log="/dl/log" "Rel.One-GRP/CD1" /dl/"Rel.One-GRP/CD1"; !echo COMPLETE: "Rel.One-GRP/CD1"' ]
    # pget will not create the directory, and neither entry may unlink the
    # release: only whole top-level entries have a symlink of their own.
    [ "${lines[1]}" = "!mkdir -p '/dl/Rel.One-GRP'" ]
    [ "${lines[2]}" = 'pget -c -n 5 "Rel.One-GRP/movie.mkv" -o /dl/"Rel.One-GRP/movie.mkv"; !echo COMPLETE: "Rel.One-GRP/movie.mkv"' ]
}

@test "a whole top-level entry still unlinks itself when it is done" {
    run stage 'LINESF="notes.nfo"; local_dl_dir=/dl; DLFL'
    [ "${lines[0]}" = 'pget -c -n 5 "notes.nfo" -o /dl/"notes.nfo" && rm -f "notes.nfo"' ]
}

@test "DLRM drops the symlink of a - entry without downloading it" {
    run stage 'LINESR="Rel.Two-GRP"; DLRM'
    [ "${lines[0]}" = 'rm -f "Rel.Two-GRP"; !echo UNLINKED: "Rel.Two-GRP"' ]
    run stage 'LINESR="Rel.Two-GRP"; dry_run=True; DLRM'
    [ "${lines[0]}" = '!echo DRY-RUN: rm "Rel.Two-GRP"' ]
}

# ------------------------------------------------------------- srcs mode ----
#
# "srcs" is the one key in a profile block that is not valid bash, so it is
# read textually rather than eval'd; "-i" with no profile after it is what
# turns the list into the top level of the picker.

@test "parse_srcs reads the ;-separated list the eval cannot" {
    run stage 'configsrc="$fixture"; eval_remote_config
               echo "${#SRCS[@]} [${SRCS[0]}] [${SRCS[1]}] [${SRCS[2]}]"'
    # Split on ";" and trimmed, and the trailing space on the last one is gone.
    [ "$output" = "3 [TV] [music] [other]" ]
}

@test "srcs never reaches the eval of either config pass" {
    run stage 'configsrc="$fixture"; eval_remote_config; echo "[${srcs:-unset}]"'
    [ "$output" = "[unset]" ]
    run stage 'hostname() { echo testhost; }; configsrc="$fixture"
               eval_local_config; echo "[${srcs:-unset}]"'
    [ "$output" = "[unset]" ]
}

@test "-i with no profile after it enters srcs mode, with one it does not" {
    run stage 'configsrc="$fixture"; eval_remote_config; ARGSB -i
               echo "[$srcs_mode] [$profile]"'
    [ "$output" = "[True] []" ]
    run stage 'configsrc="$fixture"; eval_remote_config; ARGSB -i TV
               echo "[$srcs_mode] [$profile]"'
    [ "$output" = "[] [TV]" ]
    # Another flag after -i is no profile name either.
    run stage 'configsrc="$fixture"; eval_remote_config; ARGSB -i -q
               echo "[$srcs_mode]"'
    [ "$output" = "[True]" ]
}

@test "srcs mode needs no -ld/-rd, and lists the completed directory itself" {
    run stage 'srcs_mode=True; complete_dir=/complete/
               ARGSC -i; echo "[$remote_dl_dir] [$dirname]"'
    [ "$status" -eq 0 ]
    [ "$output" = "[/complete/] []" ]
    # Without srcs mode the same argv is still the old error.
    run stage 'complete_dir=/complete/; ARGSC -i'
    [[ "$output" == *"Please specify desitnation"* ]]
}

@test "local_dir_for sends each src to its own dl_dir, and the rest to one" {
    run stage 'local_dl_dir=/dl
               local_dir_for "Rel.One-GRP"; echo "[$local_dir] [$local_rel]"
               local_dir_for "Rel.One-GRP/CD1"; echo "[$local_dir] [$local_rel]"'
    # An ordinary run has one answer: everything under $local_dl_dir, whole.
    [ "${lines[0]}" = "[/dl] [Rel.One-GRP]" ]
    [ "${lines[1]}" = "[/dl] [Rel.One-GRP/CD1]" ]

    run stage 'srcs_mode=True; local_dl_dir=/dl/@profile; local_dl_dir_films=/mnt/films
               local_dir_for "films/Film-GRP"; echo "[$local_dir] [$local_rel]"
               local_dir_for "TV/Rel.One-GRP/CD1"; echo "[$local_dir] [$local_rel]"
               local_dir_for "TV/"; echo "[$local_dir] [$local_rel]"'
    # The src is consumed by resolving it: its own dl_dir wins, and the general
    # one has @profile substituted with the src the way a profile name would.
    [ "${lines[0]}" = "[/mnt/films] [Film-GRP]" ]
    [ "${lines[1]}" = "[/dl/TV] [Rel.One-GRP/CD1]" ]
    # A whole src is the root itself, with nothing below it.
    [ "${lines[2]}" = "[/dl/TV] []" ]
}

@test "local_dir_for expands a dl_dir whose tilde was quoted in the config" {
    run stage "HOME=/home/u; local_dl_dir='~/dl'; local_dl_dir_films='~/films'
               local_dir_for 'Rel.One-GRP'; echo \"[\$local_dir]\"
               srcs_mode=True; local_dl_dir='~'
               local_dir_for 'films/Film-GRP'; echo \"[\$local_dir]\"
               local_dir_for 'TV/Rel'; echo \"[\$local_dir]\"
               local_dl_dir='~bob/dl'; local_dir_for 'TV/Rel'; echo \"[\$local_dir]\""
    # du and [ -e ] do not expand a tilde, so a literal one measures nothing.
    [ "${lines[0]}" = "[/home/u/dl]" ]
    [ "${lines[1]}" = "[/home/u/films]" ]
    [ "${lines[2]}" = "[/home/u]" ]
    [ "${lines[3]}" = "[~bob/dl]" ]
}

@test "a whole src mirrors into its own directory, not into a copy of itself" {
    run stage 'srcs_mode=True; local_dl_dir=/dl; local_dl_dir_films=/mnt/films
               LINESD="films"; DLDR'
    # No trailing slash and no empty name behind it: "…/films/\"\"" would make
    # mirror take the source basename and nest it a second time.
    [ "${lines[0]}" = 'mirror -c -P5 --log="" "films" "/mnt/films"; !echo COMPLETE: "films"' ]
}

@test "srcs mode never unlinks the source directory it just mirrored" {
    run stage 'srcs_mode=True; local_dl_dir=/dl; LINESD="TV"; DLDR'
    # The "&& rm -f" that a completed top-level entry gets is a symlink's; a
    # src is a real directory and removing it would take the lot.
    [[ "$output" != *"rm -f"* ]]
    run stage 'srcs_mode=True; local_dl_dir=/dl; LINESF="TV/notes.nfo"; DLFL'
    [[ "$output" != *"rm -f"* ]]
    # TV has no dl_dir of its own, so it falls back to $local_dl_dir and the
    # file lands there directly -- no directory to make, exactly as a
    # top-level entry outside srcs mode.
    [ "${lines[0]}" = 'pget -c -n 5 "TV/notes.nfo" -o /dl/"notes.nfo"; !echo COMPLETE: "TV/notes.nfo"' ]

    run stage 'srcs_mode=True; local_dl_dir=/dl; local_dl_dir_films=/mnt/films
               LINESF="films/Film-GRP/film.mkv"; DLFL'
    # A src with a directory of its own does need one made: pget will not.
    [ "${lines[0]}" = "!mkdir -p '/mnt/films/Film-GRP'" ]
    [ "${lines[1]}" = 'pget -c -n 5 "films/Film-GRP/film.mkv" -o /mnt/films/"Film-GRP/film.mkv"; !echo COMPLETE: "films/Film-GRP/film.mkv"' ]
}

@test "a src is neither unlinked nor deleted" {
    run stage "$(tree)"'
        srcs_mode=True; tui_cur=0
        tui_mark_remove; echo "1 [$tui_msg] ${TUI_STATE[0]}"
        tui_mark_delete; echo "2 [$tui_msg] ${TUI_STATE[0]}"'
    [ "${lines[0]}" = "1 [Rel.One-GRP@ is a source directory, not an entry] 0" ]
    [ "${lines[1]}" = "2 [Rel.One-GRP@ is a source directory, not an entry] 0" ]
}

# ---------------------------------------------------------- local status ----

@test "tui_size_bytes parses a rounded size and says how rounded it is" {
    run stage 'for z in 753 4.1G 2.9M 1.5K 4G ""; do
                   tui_size_bytes "$z"; echo "$z $tui_bytes $tui_tol"
               done'
    # A plain byte count is exact; a suffix is a tenth of its unit out, and a
    # suffix with no decimal at all is half of it.
    [ "${lines[0]}" = "753 753 0" ]
    [ "${lines[1]}" = "4.1G 4402341478 107374182" ]
    [ "${lines[2]}" = "2.9M 3040870 104857" ]
    [ "${lines[3]}" = "1.5K 1536 102" ]
    [ "${lines[4]}" = "4G 4294967296 536870912" ]
    # Nothing recognisable is -1, which is what leaves the status empty.
    [ "${lines[5]}" = " -1 0" ]
}

@test "a file is complete when it is there at its size, and short when it is not" {
    dir=$(mktemp -d)
    printf '%s' 0123456789 > "$dir/whole"
    printf '%s' 012 > "$dir/part"
    run stage "$(tree)"'
        local_dl_dir="'"$dir"'"
        TUI_SIZE[2]=10; TUI_NAME[2]=whole; TUI_PATH[2]=whole
        TUI_SIZE[4]=10; TUI_NAME[4]=part;  TUI_PATH[4]=part; TUI_PARENT[4]=-1
        TUI_SIZE[5]=10; TUI_NAME[5]=gone;  TUI_PATH[5]=gone; TUI_PARENT[5]=-1
        tui_status_scan
        echo "[${TUI_STATUS[2]}][${TUI_STATUS[4]}][${TUI_STATUS[5]}] w=$tui_statusw"'
    rm -rf "$dir"
    # There at its size, there and short, not there at all.
    [ "$output" = "[c][i][] w=1" ]
}

@test "a rounded size still matches the file it was rounded from" {
    dir=$(mktemp -d)
    head -c 3000000 /dev/zero > "$dir/big"
    run stage "$(tree)"'
        local_dl_dir="'"$dir"'"
        TUI_SIZE[2]=2.9M; TUI_NAME[2]=big; TUI_PATH[2]=big
        tui_status_scan; echo "[${TUI_STATUS[2]}]"'
    rm -rf "$dir"
    # 2.9M is 3040870 bytes read back literally; the file is 3000000, and only
    # the rounding tolerance closes the gap.
    [ "$output" = "[c]" ]
}

@test "a directory is judged by its children, and stays empty where they are not loaded" {
    dir=$(mktemp -d)
    mkdir -p "$dir/Rel.One-GRP"
    printf '%s' 0123456789 > "$dir/Rel.One-GRP/movie.mkv"
    printf '%s' 0123456789 > "$dir/Rel.One-GRP/movie.nfo"
    mkdir -p "$dir/Rel.One-GRP/CD1"
    run stage "$(tree)"'
        local_dl_dir="'"$dir"'"
        TUI_SIZE[4]=10; TUI_SIZE[5]=10
        tui_status_scan
        echo "one=[${TUI_STATUS[0]}] cd1=[${TUI_STATUS[3]}] two=[${TUI_STATUS[1]}]"
        # take one of the files away and the directory follows it
        rm -f "'"$dir"'/Rel.One-GRP/movie.nfo"
        tui_status_scan; echo "one=[${TUI_STATUS[0]}]"'
    rm -rf "$dir"
    # CD1 is there but never listed, so nothing can be said about it -- and
    # that only blocks "complete", it never claims it. Rel.Two-GRP was never
    # downloaded at all.
    [ "${lines[0]}" = "one=[] cd1=[] two=[]" ]
    [ "${lines[1]}" = "one=[i]" ]
}

# In the completed directory every entry is a symlink and the size column
# measures the *link*, not what is behind it: a release symlink lists as the
# length of its target path. That figure used to be shown, and -- far worse --
# compared against what was on disk. A symlink's length is a small number, so
# anything at all in the local directory cleared it and the entry read as
# already downloaded.
@test "a symlink's own length is never used as the entry's size" {
    dir=$(mktemp -d)
    mkdir -p "$dir/Rel.One-GRP"
    head -c 4096 /dev/zero > "$dir/Rel.One-GRP/movie.mkv"
    # Part of a download: far more than the 23 its symlink measures, far less
    # than the file behind it.
    head -c 4096 /dev/zero > "$dir/notes.nfo"
    list=$(mktemp); list2=$(mktemp)
    # What the completed directory really lists: the length of each target.
    printf '%s\n' 'Rel.One-GRP@     25  2026-08-23 17:10' \
                  'notes.nfo@       23  2026-08-22 09:03' > "$list"
    printf '%s\n' 'Rel.One-GRP/' 'notes.nfo' > "$list2"
    run stage 'exec {TUI_OUT}>/dev/null
        listfile="'"$list"'"; listfile2="'"$list2"'"; listfile5=""; listfile3=""
        local_dl_dir="'"$dir"'"
        declare -gA LINK_TARGET=([Rel.One-GRP]=../../data/TV/Rel.One-GRP \
                                 [notes.nfo]=../../data/TV/notes.nfo)
        tui_load
        echo "size=[${TUI_SIZE[0]}][${TUI_SIZE[1]}]"
        echo "status=[${TUI_STATUS[0]}][${TUI_STATUS[1]}] w=$tui_statusw"'
    rm -rf "$dir" "$list" "$list2"
    # Nothing is known about either size, so neither is shown ...
    [ "${lines[0]}" = "size=[][]" ]
    # ... and nothing is claimed about either. notes.nfo in particular is a
    # part-downloaded file, and it used to read "c" here: 4096 bytes on disk is
    # more than the 23 the symlink measures, so the comparison called it done.
    [ "${lines[1]}" = "status=[][] w=0" ]
}

@test "a real file in the completed directory keeps its listed size" {
    dir=$(mktemp -d)
    printf '%s' 0123456789 > "$dir/notes.nfo"
    list=$(mktemp); list2=$(mktemp)
    printf '%s\n' 'notes.nfo       10  2026-08-22 09:03' > "$list"
    printf '%s\n' 'notes.nfo' > "$list2"
    # No LINK_TARGET entry: the server did not list this one as a symlink, so
    # its size is its own and the completeness check can still use it.
    run stage 'exec {TUI_OUT}>/dev/null
        listfile="'"$list"'"; listfile2="'"$list2"'"; listfile5=""; listfile3=""
        local_dl_dir="'"$dir"'"
        declare -gA LINK_TARGET=()
        tui_load; echo "[${TUI_SIZE[0]}][${TUI_STATUS[0]}]"'
    rm -rf "$dir" "$list" "$list2"
    [ "$output" = "[10][c]" ]
}

@test "the data directory's size wins over the symlink's, as before" {
    dir=$(mktemp -d)
    printf '%s' 0123456789 > "$dir/notes.nfo"
    list=$(mktemp); list2=$(mktemp); list5=$(mktemp)
    printf '%s\n' 'notes.nfo@      23  2026-08-22 09:03' > "$list"
    printf '%s\n' 'notes.nfo' > "$list2"
    printf '%s\n' '      10 notes.nfo' > "$list5"
    run stage 'exec {TUI_OUT}>/dev/null
        listfile="'"$list"'"; listfile2="'"$list2"'"
        listfile5="'"$list5"'"; listfile3=""
        local_dl_dir="'"$dir"'"
        declare -gA LINK_TARGET=([notes.nfo]=../../data/TV/notes.nfo)
        tui_load; echo "[${TUI_SIZE[0]}][${TUI_STATUS[0]}]"'
    rm -rf "$dir" "$list" "$list2" "$list5"
    [ "$output" = "[10][c]" ]
}

# "?" replaced the cut-down list of bindings the footer used to carry -- three
# abbreviations of the same thing, each of which had to be kept in step with
# tui_key_action by hand.
@test "? is the key that opens the window" {
    run stage 'tui_key_action "?"; echo "$tui_action"'
    [ "$output" = "help" ]
}

@test "? opens the window and any other key shuts it" {
    run stage "$(tree)"$'\n'"$(keys)"'
        TUI_COLS=80; TUI_LINES=24; tui_rows_calc
        KEYS=("?"); tui_loop; echo "open=$tui_help_open top=$tui_help_top"
        KI=0; KEYS=(z); tui_loop; echo "open=$tui_help_open"'
    [ "${lines[0]}" = "open=1 top=0" ]
    [ "${lines[1]}" = "open=0" ]
}

# The key that closes the window is spent doing so. Shutting a window and
# marking an entry for deletion with the same keystroke is not what anyone
# means by it.
@test "the key that closes the window does not also act on the list" {
    run stage "$(tree)"$'\n'"$(keys)"'
        TUI_COLS=80; TUI_LINES=24; tui_rows_calc
        tui_cur=0
        KEYS=("?" x " "); tui_loop
        echo "open=$tui_help_open state=${TUI_STATE[0]} nsel=$tui_nsel ndel=$tui_ndel"'
    # x shut the window and marked nothing; the space after it is the first key
    # the list sees, and it is the one that marked.
    [ "$output" = "open=0 state=1 nsel=1 ndel=0" ]
}

@test "the window scrolls, and stops at either end of itself" {
    run stage "$(tree)"$'\n'"$(keys)"'
        TUI_COLS=80; TUI_LINES=24; tui_rows_calc
        KEYS=("?"); tui_loop
        tui_help_geom
        n=${#TUI_HELP[@]}; h=$tui_helph
        KI=0; KEYS=(j j j); tui_loop; tui_help_geom; echo "down3=$tui_help_top"
        KI=0; KEYS=(k k k k k k); tui_loop; tui_help_geom; echo "up=$tui_help_top"
        KI=0; KEYS=(G); tui_loop; tui_help_geom; echo "end=$(( tui_help_top == n - h ))"
        KI=0; KEYS=(0); tui_loop; tui_help_geom; echo "home=$tui_help_top"
        echo "still-open=$tui_help_open"'
    [ "${lines[0]}" = "down3=3" ]
    # Scrolling up past the top stops there rather than going negative.
    [ "${lines[1]}" = "up=0" ]
    # G lands on the last screenful, not past it.
    [ "${lines[2]}" = "end=1" ]
    [ "${lines[3]}" = "home=0" ]
    # None of the scrolling keys shut it.
    [ "${lines[4]}" = "still-open=1" ]
}

@test "the window is as wide as its widest line and centred in the terminal" {
    run stage "$(tree)"'
        TUI_COLS=100; TUI_LINES=40; tui_rows_calc; tui_help_geom
        w=0; for l in "${TUI_HELP[@]}"; do
            if (( ${#l} > w )); then w=${#l}; fi
        done
        echo "w=$(( tui_helpw == w + 2 )) x=$(( tui_helpx == (100 - tui_helpw) / 2 ))"
        echo "h=$(( tui_helph == ${#TUI_HELP[@]} ))"
        # A terminal with no room for all of it shows as much as it has.
        TUI_LINES=10; tui_rows_calc; tui_help_geom
        echo "clipped=$(( tui_helph == TUI_ROWS ))"'
    # A blank column each side of the text, and centred on what is left.
    [ "${lines[0]}" = "w=1 x=1" ]
    [ "${lines[1]}" = "h=1" ]
    [ "${lines[2]}" = "clipped=1" ]
}

# Every width is worked out on plain strings and the escapes go on last, which
# is what keeps a row the width it says it is -- tui_fit measures with ${#1}.
@test "a row with the window over it is still one terminal wide" {
    run stage "$(tree)"'
        TUI_COLS=60; TUI_LINES=24; tui_rows_calc; tui_help_geom
        printf -v row "%-*s" 60 "abcdefghij"
        tui_help_row "$row" "KEY"
        # The escapes come off, and what is left is what the terminal shows.
        plain=${tui_line//$'"'"'\033'"'"'\[[0-9]*m/}
        plain=${plain//$'"'"'\033'"'"'\[m/}
        echo "${#plain}"
        echo "[${plain:tui_helpx:tui_helpw}]"'
    # Same width as the row that went in.
    [ "${lines[0]}" = "60" ]
    # The window text sits where the geometry says, a blank column each side.
    [[ "${lines[1]}" == "[ KEY "* ]]
    [[ "${lines[1]}" == *" ]" ]]
}

@test "the footer says how to reach the keys instead of listing them" {
    run stage "$(tree)"'
        TUI_COLS=120; TUI_LINES=12; tui_rows_calc; tui_widths
        exec {TUI_OUT}>&1
        tui_draw'
    # The three cut-down lists are gone; one line points at the window.
    [[ "$output" == *"? keys"* ]]
    [[ "$output" != *"r/R clear"* ]]
    [[ "$output" != *"M-j/k order"* ]]
}

@test "t hides what is complete, and shows it again" {
    run stage "$(tree)"$'\n'"$(keys)"'
        TUI_STATUS[1]=c; TUI_STATUS[2]=c; tui_status_width
        KEYS=(t q e); tui_loop
        names; echo "show=$tui_show_done"'
    # The two completed top-level entries drop out of view; the tree, the
    # marks and the order are untouched, so pressing it again puts them back.
    [ "${lines[0]}" = "[Rel.One-GRP@ CD1/ movie.mkv movie.nfo]" ]
    [ "${lines[1]}" = "show=0" ]
    run stage "$(tree)"$'\n'"$(keys)"'
        TUI_STATUS[1]=c; TUI_STATUS[2]=c; tui_status_width
        KEYS=(t t q e); tui_loop; names'
    [ "$output" = "[Rel.One-GRP@ CD1/ movie.mkv movie.nfo Rel.Two-GRP@ notes.nfo]" ]
}

@test "t is the key that does it" {
    run stage 'tui_key_action t; echo "$tui_action"'
    [ "$output" = "showdone" ]
}

@test "hiding a completed directory hides its subtree with it" {
    run stage "$(tree)"$'\n'"$(keys)"'
        TUI_STATUS[0]=c; tui_status_width
        KEYS=(t q e); tui_loop; names'
    [ "$output" = "[Rel.Two-GRP@ notes.nfo]" ]
}

@test "t with nothing to hide, and t that would hide everything, both refuse" {
    run stage "$(tree)"'
        tui_toggle_done; echo "[$tui_msg] $TUI_N show=$tui_show_done"'
    [ "$output" = "[nothing here is known to be downloaded already] 6 show=1" ]
    run stage "$(tree)"'
        for i in 0 1 2; do TUI_STATUS[i]=c; done; tui_status_width
        tui_toggle_done; echo "[$tui_msg] $TUI_N show=$tui_show_done"'
    [ "$output" = "[everything here is already downloaded] 6 show=1" ]
}

@test "the STATUS column appears only when there is a status to show" {
    run stage "$(tree)"'
        TUI_OUT=1; tui_widths; tui_draw; echo'
    [[ "$output" == *"NAME"*"SIZE"*"DATE"* ]]
    [[ "$output" != *"STATUS"* ]]
    [[ "$output" != *"completed="* ]]
    run stage "$(tree)"'
        TUI_STATUS[5]=c; tui_widths
        TUI_OUT=1; tui_draw; echo'
    [[ "$output" == *"SIZE"*"DATE"*"STATUS"* ]]
    [[ "$output" == *"completed=T"* ]]
}

# The queue without lftp. A transfer is a "sleep", which is a real process with
# a real pid, so kill -0, kill -TERM and wait all behave exactly as they do for
# the login this stands in for -- only nothing is downloaded and nothing has to
# be slowed down to be caught half-finished (a file:// transfer cannot be: the
# rate limits do not apply to it).
fakerun () {
    cat <<'SNIP'
    local_dl_dir=/nonexistent/dl; srcs_mode=False; concurrent_downloads=2
    tui_dl_run () {
        sleep 30 < /dev/null > /dev/null 2>&1 &
        TUI_DLPID[$1]=$!
        TUI_DLSTATE[$1]=running
        TUI_STATUS[${TUI_DLID[$1]}]="0%"
        return 0
    }
    states () {
        s=""
        for (( i = 0; i < tui_dl_n; i++ )); do s="$s ${TUI_DLSTATE[i]}"; done
        echo "[${s# }]"
    }
SNIP
}

# The event loop, driven by a scripted key source instead of a terminal.
keys () {
    cat <<'SNIP'
    KI=0
    tui_read_key () {
        if (( KI >= ${#KEYS[@]} )); then return 1; fi
        TUI_KEY=${KEYS[KI]}; KI=$(( KI + 1 )); return 0
    }
SNIP
}

# A count typed before a motion, the way vi takes one. The tree has six
# visible rows: 0 Rel.One-GRP@ 1 CD1/ 2 movie.mkv 3 movie.nfo 4 Rel.Two-GRP@
# 5 notes.nfo.
@test "a count repeats a motion, and runs out at the ends of the list" {
    run stage "$(tree)"$'\n'"$(keys)"'
        KEYS=(2 j); tui_loop; echo "$tui_cur"
        tui_cur=5; KI=0; KEYS=(3 k); tui_loop; echo "$tui_cur"
        # Further than there is list: the clamp is what stops it, not the count.
        KI=0; KEYS=(9 9 j); tui_loop; echo "$tui_cur"
        KI=0; KEYS=(9 9 k); tui_loop; echo "$tui_cur"'
    [ "${lines[0]}" = "2" ]
    [ "${lines[1]}" = "2" ]
    [ "${lines[2]}" = "5" ]
    [ "${lines[3]}" = "0" ]
}

@test "a count is spent on the key that follows it and on no other" {
    run stage "$(tree)"$'\n'"$(keys)"'
        # 2j moves two; the j after it moves one, not two again.
        KEYS=(2 j j); tui_loop; echo "$tui_cur"'
    [ "$output" = "3" ]
}

@test "gg goes to the first line, and 0 still does too" {
    run stage "$(tree)"$'\n'"$(keys)"'
        tui_cur=4; KEYS=(g g); tui_loop; echo "$tui_cur"
        tui_cur=4; KI=0; KEYS=(0); tui_loop; echo "$tui_cur"'
    [ "${lines[0]}" = "0" ]
    [ "${lines[1]}" = "0" ]
}

# A count's own digits include 0 once one is being typed, which is the only
# way "10j" can work while "0" on its own still means the first line.
@test "0 is a count digit only when a count is already being typed" {
    run stage "$(tree)"$'\n'"$(keys)"'
        # 10j: further than the list goes, so it lands on the last row rather
        # than on row 1, which is where a "0" read as "top" would have left it.
        KEYS=(1 0 j); tui_loop; echo "$tui_cur"'
    [ "$output" = "5" ]
}

@test "a count sends G and gg to that line, without one they are the ends" {
    run stage "$(tree)"$'\n'"$(keys)"'
        KEYS=(3 G); tui_loop; echo "$tui_cur"
        KI=0; KEYS=(2 g g); tui_loop; echo "$tui_cur"
        KI=0; KEYS=(G); tui_loop; echo "$tui_cur"'
    # Counted, they are line numbers and the rows are numbered from 1.
    [ "${lines[0]}" = "2" ]
    [ "${lines[1]}" = "1" ]
    [ "${lines[2]}" = "5" ]
}

# "gx" reaching "x" would ask to delete the entry under the cursor, so a "g"
# followed by anything else does nothing at all.
@test "g followed by anything but g does nothing" {
    run stage "$(tree)"$'\n'"$(keys)"'
        tui_cur=2; KEYS=(g x); tui_loop
        echo "$tui_cur ${TUI_STATE[4]} $tui_ndel [$tui_prompt]"'
    [ "$output" = "2 0 0 []" ]
}

@test "Esc takes back a count half typed instead of quitting" {
    run stage "$(tree)"$'\n'"$(keys)"'
        printf -v ESC "\033"
        KEYS=(2 "$ESC" j); tui_loop; echo "$tui_cur [$tui_count]"'
    # The 2 was dropped, so the j that follows moves one line.
    [ "$output" = "1 []" ]
}

@test "a count moves a node that many places" {
    run stage "$(tree)"$'\n'"$(keys)"'
        tui_cur=1; KEYS=(2 $'"'"'\ej'"'"'); tui_loop
        names'
    # CD1/ was the first of the three children; two moves down put it last.
    [ "$output" = "[Rel.One-GRP@ movie.mkv movie.nfo CD1/ Rel.Two-GRP@ notes.nfo]" ]
}

# The gutter down the left: how far each row is from the cursor, except the
# cursor's own row, which says where in the list it is.
@test "the line numbers are relative, and absolute under the cursor" {
    run stage "$(tree)"'
        TUI_COLS=80; tui_cur=2; tui_widths; tui_name_field
        g=""; for ((i = 0; i < TUI_N; i++)); do tui_row_number "$i"; g="$g[$tui_gut]"; done
        echo "$g w=$tui_gutw"'
    [ "$output" = "[ 2 ][ 1 ][ 3 ][ 1 ][ 2 ][ 3 ] w=3" ]
}

@test "line_numbers=False leaves the gutter out and gives the name the room" {
    run stage "$(tree)"'
        TUI_COLS=80; tui_widths
        tui_name_field; tui_row_number 0; on=$tui_namefld
        line_numbers=False
        tui_name_field; tui_row_number 0
        echo "off=[$tui_gut] w=$tui_gutw wider=$(( tui_namefld - on ))"'
    # No gutter, and the three columns it took go back to the name.
    [ "$output" = "off=[] w=0 wider=3" ]
}

@test "space toggles the entry under the cursor, q then s saves" {
    # Space also steps down, so the cursor is on CD1/ when the second space
    # splits the directory it was given whole -- one row further on than the
    # same two keystrokes used to reach.
    run stage "$(tree)"$'\n'"$(keys)"'
        KEYS=(" " " " q s); tui_loop
        marks; echo "$tui_nsel $tui_result"'
    [ "${lines[0]}" = "[* ++  ]" ]
    [ "${lines[1]}" = "2 save" ]
}

@test "space toggles and moves down, and stops on the last entry" {
    run stage "$(tree)"$'\n'"$(keys)"'
        KEYS=(" " " "); tui_loop
        echo "$tui_cur"
        tui_cur=5; KI=0; KEYS=(" "); tui_loop
        echo "$tui_cur ${TUI_STATE[5]}"'
    # Two spaces from the top leave the cursor on the third row.
    [ "${lines[0]}" = "2" ]
    # On the last row it toggles and stays: there is nowhere below to go.
    [ "${lines[1]}" = "5 1" ]
}

@test "shift-space toggles and moves up, and stops on the first entry" {
    run stage "$(tree)"$'\n'"$(keys)"'
        SS=$'"'"'\e[32;2u'"'"'
        tui_cur=3; KEYS=("$SS" "$SS"); tui_loop
        echo "$tui_cur"
        tui_clear_all
        tui_cur=0; KI=0; KEYS=("$SS"); tui_loop
        echo "$tui_cur ${TUI_STATE[0]}"'
    # Two shift-spaces from the fourth row leave the cursor on the second.
    [ "${lines[0]}" = "1" ]
    # On the first row it toggles and stays.
    [ "${lines[1]}" = "0 1" ]
}

# Neither protocol is turned on by the script, so a terminal may send either
# spelling of shift+space depending on what it has been asked for.
@test "both spellings of shift-space map to toggling upwards" {
    run stage 'tui_key_action " "; echo "$tui_action"
               tui_key_action $'"'"'\e[32;2u'"'"'; echo "$tui_action"
               tui_key_action $'"'"'\e[27;2;32~'"'"'; echo "$tui_action"'
    [ "${lines[0]}" = "toggledn" ]
    [ "${lines[1]}" = "toggleup" ]
    [ "${lines[2]}" = "toggleup" ]
}

# Enter used to be a synonym for space. It starts the download queue now, and
# the mark it lands on is the one space already made -- deliberately changed
# with the transfer manager.
@test "enter no longer toggles: it queues what is marked" {
    run stage "$(tree)"$'\n'"$(keys)"$'\n'"$(fakerun)"'
        printf -v NL "\n"
        KEYS=(" " "$NL" q e); tui_loop
        marks; echo "$tui_nsel $tui_dl_n ${TUI_DLSTATE[0]} ${TUI_STATUS[0]}"'
    [ "${lines[0]}" = "[++++  ]" ]
    [ "${lines[1]}" = "1 1 running 0%" ]
}

# Three top-level entries marked by hand: movie.mkv is inside the open
# directory and comes first in the order, then Rel.Two-GRP, then notes.nfo.
picked () {
    cat <<'SNIP'
    tui_set_state 4 1; tui_set_state 1 1; tui_set_state 2 1
SNIP
}

@test "enter queues in list order and starts concurrent_downloads of them" {
    run stage "$(tree)"$'\n'"$(fakerun)"$'\n'"$(picked)"'
        tui_dl_enqueue
        states; echo "${TUI_DLPATH[0]} ${TUI_DLPATH[1]} ${TUI_DLPATH[2]}"
        echo "${TUI_STATUS[4]} ${TUI_STATUS[1]} ${TUI_STATUS[2]}"'
    [ "${lines[0]}" = "[running running queued]" ]
    [ "${lines[1]}" = "Rel.One-GRP/movie.mkv Rel.Two-GRP notes.nfo" ]
    # The one still waiting says so; the two with a login of their own start
    # at nothing transferred.
    [ "${lines[2]}" = "0% 0% queued" ]
}

@test "moving a queued entry above a running one pauses the running one" {
    run stage "$(tree)"$'\n'"$(fakerun)"$'\n'"$(picked)"'
        tui_dl_enqueue; states
        tui_cur=5; tui_move_node up; tui_dl_sched
        states; echo "${TUI_STATUS[1]}"
        # ... and putting it back gives the slot straight back.
        tui_cur=4; tui_move_node down; tui_dl_sched; states'
    [ "${lines[0]}" = "[running running queued]" ]
    [ "${lines[1]}" = "[running paused running]" ]
    [ "${lines[2]}" = "paused" ]
    [ "${lines[3]}" = "[running running paused]" ]
}

@test "a second enter queues only what was marked since the first" {
    run stage "$(tree)"$'\n'"$(fakerun)"$'\n'"$(picked)"'
        tui_dl_enqueue; echo "$tui_dl_n"
        tui_dl_enqueue; echo "$tui_dl_n $tui_msg"
        tui_set_state 5 1; tui_dl_enqueue; echo "$tui_dl_n ${TUI_DLPATH[3]}"'
    [ "${lines[0]}" = "3" ]
    [ "${lines[1]}" = "3 everything marked is already queued" ]
    [ "${lines[2]}" = "4 Rel.One-GRP/movie.nfo" ]
}

@test "c takes a queued entry out of the queue and asks nothing" {
    run stage "$(tree)"$'\n'"$(fakerun)"$'\n'"$(picked)"'
        tui_dl_enqueue
        tui_cur=5; tui_dl_cancel
        states; echo "${TUI_STATUS[2]} | $tui_msg | $tui_prompt"'
    [ "${lines[0]}" = "[running running cancelled]" ]
    [ "${lines[1]}" = "cancelled | notes.nfo cancelled | " ]
}

@test "c on an entry that was never queued says so" {
    run stage "$(tree)"$'\n'"$(fakerun)"'
        tui_cur=5; tui_dl_cancel; echo "$tui_msg"'
    [ "$output" = "notes.nfo is not queued" ]
}

# Cancelling a running transfer may leave part of a release behind. Only what
# this session put there is ever offered up, and only "Y" takes it.
@test "cancelling a running transfer offers to delete what it created" {
    run stage "$(tree)"$'\n'"$(keys)"$'\n'"$(fakerun)"$'\n'"$(picked)"'
        local_dl_dir=$(mktemp -d)
        tui_dl_enqueue
        mkdir -p "$local_dl_dir/Rel.Two-GRP"; : > "$local_dl_dir/Rel.Two-GRP/part"
        tui_cur=4; KEYS=(n); tui_dl_cancel
        echo "kept: $([ -e "$local_dl_dir/Rel.Two-GRP" ] && echo yes || echo no) $tui_msg"
        TUI_DLSTATE[1]=running; TUI_DLPID[1]=""
        tui_cur=4; KI=0; KEYS=(Y); tui_dl_cancel
        echo "gone: $([ -e "$local_dl_dir/Rel.Two-GRP" ] && echo yes || echo no)"
        rm -rf "$local_dl_dir"'
    [ "${lines[0]}" = "kept: yes Rel.Two-GRP@ cancelled, what arrived is still there" ]
    [ "${lines[1]}" = "gone: no" ]
}

# A destination that was already there when the job was queued is not this
# session's to remove, however far the transfer got.
@test "cancelling never offers to delete what was there beforehand" {
    run stage "$(tree)"$'\n'"$(keys)"$'\n'"$(fakerun)"$'\n'"$(picked)"'
        local_dl_dir=$(mktemp -d)
        mkdir -p "$local_dl_dir/Rel.Two-GRP"
        tui_dl_enqueue
        tui_cur=4; KEYS=(Y); tui_dl_cancel
        echo "$tui_msg | $([ -e "$local_dl_dir/Rel.Two-GRP" ] && echo yes || echo no)"
        rm -rf "$local_dl_dir"'
    [ "$output" = "Rel.Two-GRP@ cancelled | yes" ]
}

@test "progress is a percentage of the expected size, or the bytes themselves" {
    run stage "$(tree)"$'\n'"$(fakerun)"$'\n'"$(picked)"'
        local_dl_dir=$(mktemp -d)
        tui_dl_enqueue
        # 2.7G listed for Rel.Two-GRP is a symlink length, not a size, and it
        # is a directory besides, so there is no expected figure for it.
        echo "${TUI_DLEXP[1]}"
        # Well above a filesystem block: what is measured is the space
        # allocated, which is rounded up to a block per file, so toy sizes
        # would be all rounding.
        head -c 2097152 /dev/zero > "$local_dl_dir/Rel.Two-GRP"
        TUI_DLEXP[1]=4194304; tui_dl_progress; echo "${TUI_STATUS[1]}"
        TUI_DLEXP[1]=-1;      tui_dl_progress; echo "${TUI_STATUS[1]}"
        # A transfer that has reached its (rounded) expected size is still not
        # done: only the exit status says that.
        TUI_DLEXP[1]=1048576; tui_dl_progress; echo "${TUI_STATUS[1]}"
        rm -rf "$local_dl_dir"'
    [ "${lines[0]}" = "-1" ]
    [ "${lines[1]}" = "50%" ]
    # Human sizes are written the way lftp's -h and ls -h write them, so a
    # directory's byte count in this column reads like the sizes beside it.
    [ "${lines[2]}" = "2.0M" ]
    [ "${lines[3]}" = "99%" ]
}

@test "a finished transfer is saved as = and everything else as it was" {
    run stage "$(tree)"$'\n'"$(fakerun)"$'\n'"$(picked)"'
        tui_dl_enqueue
        TUI_DLSTATE[0]=done; TUI_DLSTATE[1]=failed; TUI_DLSTATE[2]=cancelled
        tui_save; cut -c1 "$listfile" | tr -d "\n"; echo
        grep -c . "$listfile"'
    # Rel.One-GRP holds a selection below it (*), movie.mkv is done (=) -- not
    # "#", because the parent must still post-process it -- and Rel.Two-GRP
    # failed while notes.nfo was cancelled, so both are still "+" for the
    # parent session to finish.
    [ "${lines[0]}" = "*=++" ]
    [ "${lines[1]}" = "4" ]
}

@test "quitting with transfers in flight says what will be stopped" {
    run stage "$(tree)"$'\n'"$(keys)"$'\n'"$(fakerun)"$'\n'"$(picked)"'
        tui_dl_enqueue
        tui_draw () { echo "$tui_prompt"; }
        KEYS=(e); tui_quit_prompt'
    [[ "$output" == *"2 running and 1 queued will be stopped"* ]]
}

@test "tab opens a directory and closes it again" {
    run stage "$(tree)"$'\n'"$(keys)"'
        printf -v TAB "\t"
        KEYS=("$TAB" q e); tui_loop; echo "$TUI_N"'
    # The tree starts with Rel.One-GRP open; tab on it hides its three children.
    [ "$output" = "3" ]
}

@test "tab on something that is not a directory says so" {
    # Straight at tui_toggle_open: the loop clears the message on the next
    # keystroke, which is the whole point of it being a footer note.
    run stage "$(tree)"'
        tui_cur=2; tui_toggle_open; echo "$tui_msg"; echo "$TUI_N"'
    [ "${lines[0]}" = "movie.mkv is not a directory" ]
    [ "${lines[1]}" = "6" ]
}

@test "d and the quit dialog work from the loop too" {
    run stage "$(tree)"$'\n'"$(keys)"'
        KEYS=(j j j j d q c q s); tui_loop; marks; echo "$tui_nrm $tui_result"'
    [ "${lines[0]}" = "[    - ]" ]
    [ "${lines[1]}" = "1 save" ]
}

@test "the quit dialog cancels back to the list, saves, or exits" {
    run stage "$(tree)"$'\n'"$(keys)"'
        KEYS=(" " q c j " " q s); tui_loop; echo "cancel-then-save: $tui_nsel $tui_result"'
    [ "$output" = "cancel-then-save: 2 save" ]
    run stage "$(tree)"$'\n'"$(keys)"'
        KEYS=(" " q e); tui_loop; echo "exit: $tui_result"'
    [ "$output" = "exit: exit" ]
}

@test "G jumps to the last row and the arrow keys move too" {
    run stage "$(tree)"$'\n'"$(keys)"'
        KEYS=(G " " q s); tui_loop; marks
        KI=0; tui_set_all 0; tui_cur=0; tui_top=0
        KEYS=($(printf "\e[B") $(printf "\e[B") " " q s); tui_loop; marks'
    [ "${lines[0]}" = "[     +]" ]
    [ "${lines[1]}" = "[* +   ]" ]
}

@test "alt-j moves an entry down its sibling group and the cursor follows" {
    run stage "$(tree)"'
        tui_cur=4; tui_move_node down; names; echo "$tui_cur"'
    # Rel.Two-GRP swaps with notes.nfo; the cursor stays on Rel.Two-GRP.
    [ "${lines[0]}" = "[Rel.One-GRP@ CD1/ movie.mkv movie.nfo notes.nfo Rel.Two-GRP@]" ]
    [ "${lines[1]}" = "5" ]
}

@test "a directory moved down takes its whole subtree with it" {
    run stage "$(tree)"'
        tui_cur=0; tui_move_node down; names; echo "$tui_cur"'
    # The three children stay behind Rel.One-GRP, which is now second.
    [ "${lines[0]}" = "[Rel.Two-GRP@ Rel.One-GRP@ CD1/ movie.mkv movie.nfo notes.nfo]" ]
    [ "${lines[1]}" = "1" ]
}

@test "alt-k puts it back where it was" {
    run stage "$(tree)"'
        tui_cur=0; tui_move_node down; tui_move_node up; names; echo "$tui_cur"'
    [ "${lines[0]}" = "[Rel.One-GRP@ CD1/ movie.mkv movie.nfo Rel.Two-GRP@ notes.nfo]" ]
    [ "${lines[1]}" = "0" ]
}

@test "an entry never leaves its sibling group" {
    # CD1 is the first child, movie.nfo the last: neither may step out of the
    # directory they are in.
    run stage "$(tree)"'
        tui_cur=1; tui_move_node up; echo "$tui_msg"; names
        tui_cur=3; tui_msg=""; tui_move_node down; echo "$tui_msg"; names'
    [ "${lines[0]}" = "CD1/ is already first here" ]
    [ "${lines[1]}" = "[Rel.One-GRP@ CD1/ movie.mkv movie.nfo Rel.Two-GRP@ notes.nfo]" ]
    [ "${lines[2]}" = "movie.nfo is already last here" ]
    [ "${lines[3]}" = "[Rel.One-GRP@ CD1/ movie.mkv movie.nfo Rel.Two-GRP@ notes.nfo]" ]
}

@test "children reorder among themselves without disturbing the top level" {
    run stage "$(tree)"'
        tui_cur=2; tui_move_node up; names; echo "$tui_cur"'
    [ "${lines[0]}" = "[Rel.One-GRP@ movie.mkv CD1/ movie.nfo Rel.Two-GRP@ notes.nfo]" ]
    [ "${lines[1]}" = "1" ]
}

@test "reordering keeps the selection counters and the marks right" {
    run stage "$(tree)"'
        tui_cur=0; tui_toggle; tui_move_node down; marks; echo "$tui_nsel"'
    [ "${lines[0]}" = "[ ++++ ]" ]
    [ "${lines[1]}" = "1" ]
}

@test "alt-j and the alt-arrows reach tui_move_node from the loop" {
    run stage "$(tree)"$'\n'"$(keys)"'
        KEYS=(G $(printf "\ek") q e); tui_loop; names; echo "$tui_cur"'
    [ "${lines[0]}" = "[Rel.One-GRP@ CD1/ movie.mkv movie.nfo notes.nfo Rel.Two-GRP@]" ]
    [ "${lines[1]}" = "4" ]
    run stage "$(tree)"$'\n'"$(keys)"'
        KEYS=($(printf "\e[1;3B") q e); tui_loop; names'
    [ "${lines[0]}" = "[Rel.Two-GRP@ Rel.One-GRP@ CD1/ movie.mkv movie.nfo notes.nfo]" ]
}

@test "x asks before it marks, and only Y confirms" {
    run stage "$(tree)"$'\n'"$(keys)"'
        KEYS=(x Y); tui_loop; marks; echo "$tui_ndel"'
    [ "${lines[0]}" = "[x     ]" ]
    [ "${lines[1]}" = "1" ]
    run stage "$(tree)"$'\n'"$(keys)"'
        KEYS=(x n); tui_loop; marks; echo "$tui_ndel $tui_msg"'
    [ "${lines[0]}" = "[      ]" ]
    [ "${lines[1]}" = "0 Rel.One-GRP@ left alone" ]
}

@test "x on an entry already marked x clears it without asking" {
    # Only two keys: if the second x had asked, tui_read_key would have run out
    # and the loop would have exited before the mark came off.
    run stage "$(tree)"$'\n'"$(keys)"'
        KEYS=(x Y x q e); tui_loop; marks; echo "$tui_ndel $tui_result"'
    [ "${lines[0]}" = "[      ]" ]
    # The mark came off, so there is nothing left to save and quitting asks the
    # one question rather than three; "q" confirms it.
    [ "${lines[1]}" = "0 save" ]
}

@test "Delete marks the same way x does" {
    run stage "$(tree)"$'\n'"$(keys)"'
        KEYS=(j j $(printf "\e[3~") Y q s); tui_loop; marks; echo "$tui_ndel"'
    [ "${lines[0]}" = "[  x   ]" ]
    [ "${lines[1]}" = "1" ]
}

@test "a and A leave a delete mark alone, R clears everything" {
    run stage "$(tree)"$'\n'"$(keys)"'
        KEYS=(x Y j j j j d a); tui_loop; marks; echo "$tui_nsel/$tui_nrm/$tui_ndel"
        KI=0; KEYS=(A); tui_loop; marks
        KI=0; KEYS=(R); tui_loop; marks; echo "$tui_nsel/$tui_nrm/$tui_ndel"'
    [ "${lines[0]}" = "[x   -+]" ]
    [ "${lines[1]}" = "1/1/1" ]
    [ "${lines[2]}" = "[x   - ]" ]
    [ "${lines[3]}" = "[      ]" ]
    [ "${lines[4]}" = "0/0/0" ]
}

@test "r clears the mark under the cursor, subtree and all" {
    run stage "$(tree)"$'\n'"$(keys)"'
        KEYS=(" " k r); tui_loop; marks; echo "$tui_nsel"
        KI=0; KEYS=(j j " " k k k r); tui_loop; marks; echo "$tui_nsel"'
    [ "${lines[0]}" = "[      ]" ]
    [ "${lines[1]}" = "0" ]
    # The "*" on the directory is its child's selection; r on the child's
    # parent takes the whole thing back.
    [ "${lines[2]}" = "[      ]" ]
    [ "${lines[3]}" = "0" ]
}

@test "tui_save writes the x mark for TYPE to read back" {
    run stage "$(tree)"$'\n'"$(keys)"'
        KEYS=(x Y q s); tui_loop; tui_save; head -n 1 "$listfile"'
    [ "$output" = "xRel.One-GRP@           4.1G  2026-08-23 17:10" ]
}

@test "TYPE reads an x line into LINESX and leaves it out of the download" {
    listfile=$(mktemp); listfile2=$(mktemp)
    printf '%s\n' 'xRel.One-GRP@          4.1G  2026-08-23 17:10' \
                  '+notes.nfo             2.1K  2026-08-22 09:03' > "$listfile"
    printf '%s\n' 'Rel.One-GRP/' 'notes.nfo' > "$listfile2"
    run stage 'listfile="'"$listfile"'"; listfile2="'"$listfile2"'"; TYPE
               echo "D=[$LINESD] F=[$LINESF] X=[$LINESX]"'
    rm -f "$listfile" "$listfile2"
    [ "$output" = "D=[] F=[notes.nfo] X=[Rel.One-GRP]" ]
}

@test "DLDEL removes the data and then the symlink, and neither under --dry-run" {
    run stage 'LINESX="Rel.Two-GRP"; data_dir=/srv/data/; dirname=TV
               remote_dl_dir=/srv/complete/TV; DLDEL'
    # No parsed ls -l target, so the data path is the one the layout implies.
    [ "${lines[0]}" = 'rm -r -f "/srv/data/TV/Rel.Two-GRP"; !echo DELETED: "/srv/data/TV/Rel.Two-GRP"' ]
    [ "${lines[1]}" = 'rm -f "Rel.Two-GRP"; !echo UNLINKED: "Rel.Two-GRP"' ]
    run stage 'LINESX="Rel.Two-GRP"; data_dir=/srv/data/; dirname=TV
               remote_dl_dir=/srv/complete/TV; dry_run=True; DLDEL'
    [ "${lines[0]}" = '!echo DRY-RUN: rm -r "/srv/data/TV/Rel.Two-GRP"' ]
    [ "${lines[1]}" = '!echo DRY-RUN: rm "Rel.Two-GRP"' ]
}

@test "DLDEL follows the parsed symlink target and leaves a nested entry its symlink" {
    run stage 'LINESX="Rel.One-GRP"; data_dir=/srv/data/; dirname=TV
               remote_dl_dir=/srv/complete/TV
               LINK_TARGET[Rel.One-GRP]="../../data/OTHER/Rel.One-GRP"; DLDEL'
    [ "${lines[0]}" = 'rm -r -f "/srv/data/OTHER/Rel.One-GRP"; !echo DELETED: "/srv/data/OTHER/Rel.One-GRP"' ]
    [ "${lines[1]}" = 'rm -f "Rel.One-GRP"; !echo UNLINKED: "Rel.One-GRP"' ]
    # Nested: the data hangs off whatever the top-level link resolved to, and
    # there is no symlink of its own to drop.
    run stage 'LINESX="Rel.One-GRP/movie.mkv"; data_dir=/srv/data/; dirname=TV
               remote_dl_dir=/srv/complete/TV
               LINK_TARGET[Rel.One-GRP]="../../data/OTHER/Rel.One-GRP"; DLDEL'
    [ "${lines[0]}" = 'rm -r -f "/srv/data/OTHER/Rel.One-GRP/movie.mkv"; !echo DELETED: "/srv/data/OTHER/Rel.One-GRP/movie.mkv"' ]
    [ "${#lines[@]}" -eq 1 ]
}

@test "LINESO carries the list order, and DLXFER emits the transfers in it" {
    listfile=$(mktemp); listfile2=$(mktemp)
    # A file above a directory: without LINESO the directory would go first.
    printf '%s\n' '+notes.nfo             2.1K  2026-08-22 09:03' \
                  '+Rel.One-GRP@          4.1G  2026-08-23 17:10' > "$listfile"
    printf '%s\n' 'Rel.One-GRP/' 'notes.nfo' > "$listfile2"
    run stage 'listfile="'"$listfile"'"; listfile2="'"$listfile2"'"; TYPE
               echo "O=[$(printf "%s" "$LINESO" | tr "\t\n" ":,")]"
               local_dl_dir=/dl; logfile=/dl/log; DLXFER'
    rm -f "$listfile" "$listfile2"
    [ "${lines[0]}" = "O=[file:notes.nfo,dir:Rel.One-GRP]" ]
    [[ "${lines[1]}" == 'pget -c -n 5 "notes.nfo"'* ]]
    [[ "${lines[3]}" == 'mirror -c -P5'*'"Rel.One-GRP"'* ]]
}

@test "DLXFER with no LINESO falls back to the grouped order" {
    run stage 'LINESD="Rel.One-GRP"; LINESF="notes.nfo"
               local_dl_dir=/dl; logfile=/dl/log; DLXFER'
    [[ "${lines[0]}" == 'mirror -c -P5'* ]]
    [[ "${lines[2]}" == 'pget -c -n 5'* ]]
}

@test "FORMAT_LIST puts the name first and lines the columns up" {
    listfile=$(mktemp)
    printf '%s\n' '    4.0K 2026-08-23 17:10 tests/' \
                  '     753 2026-08-23 14:42 a file  with spaces' > "$listfile"
    run stage 'listfile="'"$listfile"'"; FORMAT_LIST; cat "$listfile"'
    rm -f "$listfile"
    [ "${lines[0]}" = "tests/               4.0K  2026-08-23 17:10" ]
    [ "${lines[1]}" = "a file  with spaces   753  2026-08-23 14:42" ]
}

@test "FORMAT_LIST left-aligns directories, which have no size" {
    listfile=$(mktemp)
    printf '%s\n' '    4.0K 2026-08-23 17:10 somefile.mkv' \
                  '         2026-08-23 14:42 A.Dir.Name/' > "$listfile"
    run stage 'listfile="'"$listfile"'"; FORMAT_LIST; cat "$listfile"'
    rm -f "$listfile"
    # The name starts at column 1 on both lines; the size column is blank for
    # the directory, and the dates still line up.
    [ "${lines[0]}" = "somefile.mkv  4.0K  2026-08-23 17:10" ]
    [ "${lines[1]}" = "A.Dir.Name/         2026-08-23 14:42" ]
}

@test "FORMAT_LIST fills the directory size column from the du listing" {
    listfile=$(mktemp)
    listfile3=$(mktemp)
    printf '%s\n' '    4.0K 2026-08-23 17:10 somefile.mkv' \
                  '         2026-08-23 14:42 A.Dir.Name/' \
                  '         2026-08-01 09:00 no.du.entry/' > "$listfile"
    # A server that reports a size for the directory entry itself: du wins.
    printf '%s\t%s\n' '40K' './A.Dir.Name' '41K' '.' > "$listfile3"
    run stage 'listfile="'"$listfile"'"; listfile3="'"$listfile3"'"; FORMAT_LIST; cat "$listfile"'
    rm -f "$listfile" "$listfile3"
    [ "${lines[0]}" = "somefile.mkv  4.0K  2026-08-23 17:10" ]
    [ "${lines[1]}" = "A.Dir.Name/    40K  2026-08-23 14:42" ]
    [ "${lines[2]}" = "no.du.entry/        2026-08-01 09:00" ]
}

@test "du_cmd is emitted only with --dir-sizes" {
    run stage 'listfile3="/tmp/x y/list3"; dir_sizes=True; du_cmd; dir_sizes=""; echo "off:[$(du_cmd)]"'
    [ "${lines[0]}" = 'du -h --max-depth=1 . > "/tmp/x y/list3"' ]
    [ "${lines[1]}" = "off:[]" ]
}

@test "strip_columns recovers a directory name with no size column" {
    run stage 'printf "%s\n" "A.Dir.Name/         2026-08-23 14:42" | strip_columns'
    [ "${lines[0]}" = "A.Dir.Name/" ]
}

@test "FORMAT_LIST is idempotent and leaves unrecognised lines alone" {
    listfile=$(mktemp)
    printf '%s\n' '    4.0K 2026-08-23 17:10 tests/' '#a comment' 'plain-name' > "$listfile"
    run stage 'listfile="'"$listfile"'"; FORMAT_LIST; FORMAT_LIST; cat "$listfile"'
    rm -f "$listfile"
    [ "${lines[0]}" = "tests/  4.0K  2026-08-23 17:10" ]
    [ "${lines[1]}" = "#a comment" ]
    [ "${lines[2]}" = "plain-name" ]
}

@test "strip_columns recovers just the filename" {
    run stage 'printf "%s\n" "a file  with spaces   753  2026-08-23 14:42" "plain-name" | strip_columns'
    [ "${lines[0]}" = "a file  with spaces" ]
    [ "${lines[1]}" = "plain-name" ]
}

# ---------------------------------------------------------------- audit fixes

@test "-c/--continue and -ls are parsed, and -ns only suspends the old list" {
    run stage 'ARGSC -ld /l -rd d -c; echo "[$continue_prev]"'
    [ "$output" = "[True]" ]
    run stage 'ARGSC -ld /l -rd d --continue; echo "[$continue_prev]"'
    [ "$output" = "[True]" ]
    run stage 'ARGSC -ld /l -rd d -ls; echo "[$print_ls]"'
    [ "$output" = "[True]" ]
    run stage 'ARGSC -ld /l -rd d -ns; echo "[$suspend_old]"'
    [ "$output" = "[True]" ]
}

@test "set_opts configures the ssh key, under either spelling, and only then" {
    run stage 'set_opts | grep -c sftp:connect-program'
    [ "$output" = "0" ]
    run stage 'keyfile=/home/me/.ssh/id_ed25519; resolve_keyfile; set_opts | grep sftp'
    [ "$output" = 'set sftp:connect-program "ssh -a -x -i /home/me/.ssh/id_ed25519"' ]
    # The config in the wild spells it keyFile.
    run stage 'keyFile=/home/me/.ssh/id_rsa; resolve_keyfile; set_opts | grep sftp'
    [ "$output" = 'set sftp:connect-program "ssh -a -x -i /home/me/.ssh/id_rsa"' ]
}

@test "marked_entries reads +, - and unmarked lines and drops the columns" {
    f=$(mktemp)
    printf '%s\n' '+Rel.One-GRP@   4.1G  2026-08-23 17:10' \
                  '-Rel.Two-GRP@   2.7G  2026-08-23 14:42' \
                  '#notes.nfo      2.1K  2026-08-22 09:03' \
                  '*Rel.Three-GRP@ 1.0G  2026-08-22 09:03' \
                  'hand.edited.nfo  753  2026-08-22 09:03' > "$f"
    run stage 'marked_entries "'"$f"'"'
    rm -f "$f"
    [ "${lines[0]}" = "$(printf '+\tRel.One-GRP@')" ]
    [ "${lines[1]}" = "$(printf -- '-\tRel.Two-GRP@')" ]
    [ "${lines[2]}" = "$(printf '+\thand.edited.nfo')" ]
    [ "${#lines[@]}" -eq 3 ]
}

@test "-c carries the previous session's marks into a fresh listing" {
    listfile=$(mktemp); oldfile=$(mktemp)
    # What the picker saved last time ...
    printf '%s\n' '+Rel.One-GRP@   4.1G  2026-08-23 17:10' \
                  '-Rel.Two-GRP@   2.7G  2026-08-23 14:42' \
                  '#notes.nfo      2.1K  2026-08-22 09:03' > "$oldfile"
    # ... and this run's listing: the same two entries, plus a new one.
    printf '%s\n' 'Rel.One-GRP@    4.1G  2026-08-24 17:10' \
                  'Rel.Two-GRP@    2.7G  2026-08-24 14:42' \
                  'brand.new.nfo    753  2026-08-24 09:03' > "$listfile"
    run stage 'listfile="'"$listfile"'"; oldfile="'"$oldfile"'"; CONTINUE_LIST
               cat "$listfile"'
    rm -f "$listfile" "$oldfile"
    [[ "${lines[0]}" == *"carried over 2 mark(s)"* ]]
    [ "${lines[1]}" = "+Rel.One-GRP@    4.1G  2026-08-24 17:10" ]
    [ "${lines[2]}" = "-Rel.Two-GRP@    2.7G  2026-08-24 14:42" ]
    # Anything the last run said nothing about starts unmarked, as always.
    [ "${lines[3]}" = "brand.new.nfo    753  2026-08-24 09:03" ]
}

@test "-c with no previous list says so and changes nothing" {
    listfile=$(mktemp); oldfile=$(mktemp)
    printf '%s\n' 'only.nfo   753  2026-08-24 09:03' > "$listfile"
    run stage 'listfile="'"$listfile"'"; oldfile="'"$oldfile"'"; CONTINUE_LIST; cat "$listfile"'
    rm -f "$listfile" "$oldfile"
    [[ "${lines[0]}" == *"no previous session list"* ]]
    [ "${lines[1]}" = "only.nfo   753  2026-08-24 09:03" ]
}

@test "-c puts last session's marks back into the picker's tree" {
    run stage "$(tree)"'
        printf "%s\n" "+Rel.One-GRP@   4.1G  2026-08-23 17:10" \
                      "-Rel.Two-GRP@   2.7G  2026-08-23 14:42" \
                      "#notes.nfo      2.1K  2026-08-22 09:03" > "$listfile"
        tui_load; tui_apply_marks
        marks; echo "$tui_nsel $tui_nrm"'
    # tui_load leaves the tree closed, so only the top level comes back: the
    # release selected and the second one marked for unlinking.
    [ "${lines[0]}" = "[+- ]" ]
    [ "${lines[1]}" = "1 1" ]
}

@test "-ls prints the marked entries with their size and date" {
    listfile=$(mktemp)
    printf '%s\n' '+Rel.One-GRP@   4.1G  2026-08-23 17:10' \
                  '-Rel.Two-GRP@   2.7G  2026-08-23 14:42' \
                  '#notes.nfo      2.1K  2026-08-22 09:03' \
                  'hand.edited.nfo  753  2026-08-22 09:03' > "$listfile"
    run stage 'listfile="'"$listfile"'"; LIST_MARKED'
    rm -f "$listfile"
    [ "${lines[0]}" = "Rel.One-GRP@   4.1G  2026-08-23 17:10" ]
    [ "${lines[1]}" = "hand.edited.nfo  753  2026-08-22 09:03" ]
    [ "${#lines[@]}" -eq 2 ]
}

@test "the lock refuses a live run, ignores a stale one, and is given back" {
    lock=$(mktemp -u)
    run stage 'lockfile="'"$lock"'"; take_lock; cat "$lockfile"; release_lock
               if [[ -e $lockfile ]]; then echo "still there"; else echo "gone"; fi'
    [ -n "${lines[0]}" ]                # the holder's pid
    [ "${lines[1]}" = "gone" ]

    # A pid that is alive (this test) holds it against everyone else.
    printf '%s\n' "$$" > "$lock"
    run stage 'lockfile="'"$lock"'"; take_lock; echo "took it anyway"'
    [ "$status" -eq 1 ]
    [[ "$output" == *"another run (pid $$) is in progress"* ]]

    # A pid that is gone does not.
    printf '%s\n' 999999 > "$lock"
    run stage 'lockfile="'"$lock"'"; take_lock; echo "lock=[$lock_held]"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"stale lock"* ]]
    [[ "$output" == *"lock=[1]"* ]]
    rm -f "$lock"
}

@test "an interrupted run gives the lock back and dies of the signal" {
    lock=$(mktemp -u)
    run stage 'lockfile="'"$lock"'"; install_traps; take_lock
               kill -INT $$; sleep 5'
    # 128 + SIGINT: the trap re-raises rather than swallowing it.
    [ "$status" -eq 130 ]
    [ ! -e "$lock" ]
}

@test "a temp file the run made is taken back when it is interrupted" {
    run stage 'new_tmp "${TMPDIR:-/tmp}/alftp.test.XXXXXX"; echo "$tmpfile_new"
               install_traps; kill -TERM $$; sleep 5'
    [ "$status" -eq 143 ]
    [ ! -e "${lines[0]}" ]
}

@test "gpg_file is decrypted and evaluated, and a failure is named" {
    secret=$(mktemp)
    printf '%s\n' 'password=fromgpg' 'port=2121' > "$secret"
    # A stub for gpg: the decryption itself is gpg's business, not alftp's.
    run stage 'gpg () { cat "${!#}"; }
               gpg_file="'"$secret"'"; eval_gpg_config
               echo "[$password] [$port]"'
    [ "$output" = "[fromgpg] [2121]" ]

    run stage 'gpg () { return 2; }
               gpg_file="'"$secret"'"; eval_gpg_config; echo "carried on"'
    rm -f "$secret"
    [ "$status" -eq 1 ]
    [[ "$output" == *"could not decrypt"* ]]

    run stage 'gpg_file=/nonexistent/secrets.gpg; eval_gpg_config'
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not exist"* ]]
}

@test "a password is asked for only when there is nothing else to log in with" {
    # No terminal under bats, so the prompt is skipped and the empty password
    # stands -- which is what a cron run needs.
    run stage 'username=u; server=s; prompt_password; echo "[$password][$password_prompted]"'
    [ "$output" = "[][]" ]
    run stage 'username=u; server=s; password=set; prompt_password; echo "[$password]"'
    [ "$output" = "[set]" ]
    run stage 'username=u; server=s; keyfile=/k; prompt_password; echo "[$password]"'
    [ "$output" = "[]" ]
}

@test "an interactively typed password reaches the in-session helper" {
    run stage 'emitfile=/tmp/e; argvfile=/tmp/a; password=secret; child_env'
    [ "$output" = "ALFTP_EMIT_DL='/tmp/e' ALFTP_ARGV='/tmp/a'" ]
    run stage 'emitfile=/tmp/e; argvfile=/tmp/a; password=secret
               password_prompted=1; child_env'
    [ "$output" = "ALFTP_EMIT_DL='/tmp/e' ALFTP_ARGV='/tmp/a' ALFTP_PASSWORD='secret'" ]
}

@test "permissions are left alone unless the config asks for them" {
    d=$(mktemp -d); touch "$d/f"; chmod 700 "$d"; chmod 600 "$d/f"
    run stage 'apply_perms "'"$d"'"'
    [ "$(stat -c '%a' "$d")" = "700" ]
    [ "$(stat -c '%a' "$d/f")" = "600" ]
    run stage 'chmod=True; perms_dirs=755; perms_files=640; apply_perms "'"$d"'"'
    [ "$(stat -c '%a' "$d")" = "755" ]
    [ "$(stat -c '%a' "$d/f")" = "640" ]
    rm -rf "$d"
}

# An archive holds other files rather than being one, so chmod treats it as a
# directory. Every part of a multipart set counts, not just the first.
@test "is_archive knows an archive from an ordinary file" {
    run stage 'for n in a.rar A.RAR a.part01.rar a.r00 a.r15 a.zip a.z01 a.7z \
                        a.tar a.tar.gz a.tgz a.tar.bz2 a.tar.xz a.gz a.xz \
                        a.mkv a.nfo a.sfv rar a.rarely a.r a.txt; do
                   if is_archive "$n"; then echo "$n yes"; else echo "$n no"; fi
               done'
    [[ "$output" == *"a.rar yes"* ]]
    [[ "$output" == *"A.RAR yes"* ]]
    [[ "$output" == *"a.part01.rar yes"* ]]
    [[ "$output" == *"a.r00 yes"* ]]
    [[ "$output" == *"a.r15 yes"* ]]
    [[ "$output" == *"a.zip yes"* ]]
    [[ "$output" == *"a.z01 yes"* ]]
    [[ "$output" == *"a.tar.gz yes"* ]]
    # Not archives, including the names that look like one at a glance.
    [[ "$output" == *"a.mkv no"* ]]
    [[ "$output" == *"a.nfo no"* ]]
    [[ "$output" == *"a.sfv no"* ]]
    [[ "$output" == *"rar no"* ]]
    [[ "$output" == *"a.rarely no"* ]]
    [[ "$output" == *"a.r no"* ]]
}

@test "an archive downloaded on its own takes the directory permissions" {
    d=$(mktemp -d)
    touch "$d/Rel.rar" "$d/movie.mkv"
    chmod 600 "$d/Rel.rar" "$d/movie.mkv"
    run stage 'chmod=True; perms_dirs=755; perms_files=640
               apply_perms "'"$d"'/Rel.rar"; apply_perms "'"$d"'/movie.mkv"'
    # The archive is a container: it gets perms_dirs even though it is a file.
    [ "$(stat -c '%a' "$d/Rel.rar")" = "755" ]
    [ "$(stat -c '%a' "$d/movie.mkv")" = "640" ]
    rm -rf "$d"
}

@test "an archive inside a downloaded directory takes them too, at any depth" {
    d=$(mktemp -d)
    mkdir -p "$d/CD1"
    touch "$d/movie.mkv" "$d/Rel.rar" "$d/CD1/Rel.r00" "$d/CD1/part1.bin"
    chmod 600 "$d/movie.mkv" "$d/Rel.rar" "$d/CD1/Rel.r00" "$d/CD1/part1.bin"
    chmod 700 "$d" "$d/CD1"
    run stage 'chmod=True; perms_dirs=755; perms_files=640; apply_perms "'"$d"'"'
    [ "$(stat -c '%a' "$d")" = "755" ]
    [ "$(stat -c '%a' "$d/CD1")" = "755" ]
    [ "$(stat -c '%a' "$d/movie.mkv")" = "640" ]
    [ "$(stat -c '%a' "$d/CD1/part1.bin")" = "640" ]
    # Both parts of the set, one of them a directory deep.
    [ "$(stat -c '%a' "$d/Rel.rar")" = "755" ]
    [ "$(stat -c '%a' "$d/CD1/Rel.r00")" = "755" ]
    rm -rf "$d"
}

# unrar finds the rest of a set itself, so only one volume of it is ever
# unpacked. Every volume arrives as its own top-level entry, and without this
# each of them would unpack the whole set again.
@test "only the volume a set opens at counts as an entry point" {
    run stage 'for n in a.rar A.RAR a.part01.rar a.part001.rar a.part1.rar \
                        a.zip a.7z a.7z.001 a.tar a.tar.gz a.gz \
                        a.part02.rar a.part10.rar a.r00 a.r01 \
                        a.z01 a.7z.002 a.mkv a.nfo; do
                   if archive_first_volume "$n"; then echo "$n yes"; else echo "$n no"; fi
               done'
    # Anything that is not multipart opens itself.
    [[ "$output" == *"a.rar yes"* ]]
    [[ "$output" == *"A.RAR yes"* ]]
    [[ "$output" == *"a.part01.rar yes"* ]]
    [[ "$output" == *"a.part001.rar yes"* ]]
    [[ "$output" == *"a.part1.rar yes"* ]]
    [[ "$output" == *"a.zip yes"* ]]
    [[ "$output" == *"a.7z yes"* ]]
    [[ "$output" == *"a.7z.001 yes"* ]]
    [[ "$output" == *"a.tar yes"* ]]
    [[ "$output" == *"a.tar.gz yes"* ]]
    [[ "$output" == *"a.gz yes"* ]]
    # The rest of a set, and things that are not archives at all.
    [[ "$output" == *"a.part02.rar no"* ]]
    [[ "$output" == *"a.part10.rar no"* ]]
    [[ "$output" == *"a.r00 no"* ]]
    [[ "$output" == *"a.r01 no"* ]]
    [[ "$output" == *"a.z01 no"* ]]
    [[ "$output" == *"a.7z.002 no"* ]]
    [[ "$output" == *"a.mkv no"* ]]
    [[ "$output" == *"a.nfo no"* ]]
}

# A stand-in for unrar that writes what a release looks like when it comes out
# of one, into whatever directory it is run from.
unrar_stub() {
    cat <<'SNIP'
    mkdir -p "$STUBDIR"
    PATH="$STUBDIR:$PATH"
    cat > "$STUBDIR/unrar" <<'STUB'
#!/usr/bin/env bash
mkdir -p sample
printf 'movie\n' > movie.mkv
printf 'info\n'  > release.nfo
printf 'junk\n'  > sample/small.mkv
STUB
    chmod +x "$STUBDIR/unrar"
SNIP
}

@test "archive_kind names the kind, compound suffixes first" {
    run stage 'for n in a.rar a.r00 a.zip a.z01 a.7z a.7z.002 a.tar a.tar.gz \
                        a.tgz a.tar.bz2 a.tar.xz a.txz a.tar.zst a.gz a.bz2 \
                        a.xz a.zst a.mkv a.nfo a.r a.rarely; do
                   if archive_kind "$n"; then echo "$n=$arch_kind"; else echo "$n=none"; fi
               done'
    [[ "$output" == *"a.rar=rar"* ]]
    [[ "$output" == *"a.r00=rar"* ]]
    [[ "$output" == *"a.zip=zip"* ]]
    [[ "$output" == *"a.z01=zip"* ]]
    [[ "$output" == *"a.7z=7z"* ]]
    [[ "$output" == *"a.7z.002=7z"* ]]
    # A .tar.gz is a tar, not a gz -- unpacking it as a gz would leave a .tar
    # sitting there. The compound suffixes have to be tested first for that.
    [[ "$output" == *"a.tar.gz=tar"* ]]
    [[ "$output" == *"a.tgz=tar"* ]]
    [[ "$output" == *"a.tar.bz2=tar"* ]]
    [[ "$output" == *"a.tar.xz=tar"* ]]
    [[ "$output" == *"a.tar.zst=tar"* ]]
    # ... and on their own they are what they say.
    [[ "$output" == *"a.gz=gz"* ]]
    [[ "$output" == *"a.bz2=bz2"* ]]
    [[ "$output" == *"a.xz=xz"* ]]
    [[ "$output" == *"a.zst=zst"* ]]
    [[ "$output" == *"a.mkv=none"* ]]
    [[ "$output" == *"a.r=none"* ]]
    [[ "$output" == *"a.rarely=none"* ]]
}

@test "archive_basename takes off the whole suffix, compound or multipart" {
    run stage 'for n in X.rar X.part01.rar X.7z.001 X.zip X.tar X.tar.gz \
                        X.tgz X.tar.bz2 X.tar.zst X.txt.gz; do
                   archive_basename "$n"; echo "$n -> $arch_base"
               done'
    [[ "$output" == *"X.rar -> X"* ]]
    [[ "$output" == *"X.part01.rar -> X"* ]]
    [[ "$output" == *"X.7z.001 -> X"* ]]
    [[ "$output" == *"X.tar.gz -> X"* ]]
    [[ "$output" == *"X.tar.bz2 -> X"* ]]
    [[ "$output" == *"X.tar.zst -> X"* ]]
    # A .gz of one file keeps the name it had before it was compressed.
    [[ "$output" == *"X.txt.gz -> X.txt"* ]]
}

@test "uncompress_exclude blacklists by kind, on spaces or commas" {
    run stage 'for x in "" "zip" "zip 7z" "zip,7z" " ZIP , 7z " "rar"; do
                   uncompress_exclude=$x
                   out=""
                   for k in rar zip 7z tar gz; do
                       if archive_enabled "$k"; then out="$out $k"; fi
                   done
                   echo "[$x] ->$out"
               done'
    [ "${lines[0]}" = "[] -> rar zip 7z tar gz" ]
    [ "${lines[1]}" = "[zip] -> rar 7z tar gz" ]
    [ "${lines[2]}" = "[zip 7z] -> rar tar gz" ]
    [ "${lines[3]}" = "[zip,7z] -> rar tar gz" ]
    # Whitespace and case are not the user's problem.
    [ "${lines[4]}" = "[ ZIP , 7z ] -> rar tar gz" ]
    [ "${lines[5]}" = "[rar] -> zip 7z tar gz" ]
}

@test "a blacklist naming something that is not a kind says so" {
    dl=$(mktemp -d)
    run stage 'local_dl_dir="'"$dl"'"; record=/dev/null; errors=/dev/null
               uncompress_exclude="zip, rarr, 7z"; LINESF=""; LINESD=""
               POST_PROCESS'
    [[ "$output" == *"no such archive kind: rarr"* ]]
    # Only the one that is wrong.
    [[ "$output" != *"no such archive kind: zip"* ]]
    [[ "$output" != *"no such archive kind: 7z"* ]]
    rm -rf "$dl"
}

@test "a compressed single file lands beside the archive, not in a directory" {
    d=$(mktemp -d)
    printf 'the contents\n' > "$d/notes.txt"
    gzip -c "$d/notes.txt" > "$d/report.txt.gz"
    rm -f "$d/notes.txt"
    run stage 'errors=/dev/null
        UNPACK_FILE "'"$d"'/report.txt.gz"; echo "out=${unpack_out#'"$d"'/}"'
    [ "$output" = "out=report.txt" ]
    # One file, named the way gzip names it, and no directory holding one thing
    # of the same name.
    [ "$(cat "$d/report.txt")" = "the contents" ]
    [ ! -d "$d/report.txt" ]
    [ -f "$d/report.txt.gz" ]
    rm -rf "$d"
}

@test "a compressed file does not write over something already there" {
    d=$(mktemp -d); err=$(mktemp)
    printf 'new\n' > "$d/keep.txt"
    gzip -c "$d/keep.txt" > "$d/keep.txt.gz"
    printf 'do not lose me\n' > "$d/keep.txt"
    run stage 'errors="'"$err"'"; profile=TV
        UNPACK_FILE "'"$d"'/keep.txt.gz"; echo "out=[$unpack_out]"'
    [ "$output" = "out=[]" ]
    [ "$(cat "$d/keep.txt")" = "do not lose me" ]
    [[ "$(cat "$err")" == *"in the way"* ]]
    rm -rf "$d" "$err"
}

@test "a kind with no tool installed is stepped over and said once" {
    d=$(mktemp -d); err=$(mktemp)
    printf 'x\n' > "$d/Some.zip"
    # A PATH holding date and nothing else: unzip is not installed as far as
    # this is concerned, while log_event still has what it needs to say so.
    mkdir -p "$d/onlybin"
    ln -s "$(command -v date)" "$d/onlybin/date"
    run stage 'errors="'"$err"'"; profile=TV
        keep=$PATH; PATH="'"$d"'/onlybin"
        if archive_tool zip; then echo "found"; else echo "none"; fi
        UNPACK_FILE "'"$d"'/Some.zip"; echo "out=[$unpack_out]"
        PATH=$keep'
    [ "${lines[0]}" = "none" ]
    [ "${lines[1]}" = "out=[]" ]
    [[ "$(cat "$err")" == *"no tool for zip archives"* ]]
    [ -f "$d/Some.zip" ]
    rm -rf "$d" "$err"
}

@test "an archive of its own unpacks into a directory named after it" {
    d=$(mktemp -d)
    printf 'archive\n' > "$d/Some.Release-GRP.rar"
    run stage "STUBDIR=$d/bin"$'\n'"$(unrar_stub)"'
        errors=/dev/null
        here=$PWD
        UNPACK_FILE "'"$d"'/Some.Release-GRP.rar"
        echo "out=${unpack_out#'"$d"'/}"
        [ "$PWD" = "$here" ] && echo same || echo moved'
    [ "${lines[0]}" = "out=Some.Release-GRP" ]
    # The cd is kept in a subshell here as much as in UNPACK_DIR.
    [ "${lines[1]}" = "same" ]
    [ -f "$d/Some.Release-GRP/movie.mkv" ]
    # Tidied the same way a release directory is.
    [ ! -e "$d/Some.Release-GRP/release.nfo" ]
    [ ! -e "$d/Some.Release-GRP/sample" ]
    # The archive itself stays: it is the entry the listing and the record
    # name, and POST_PROCESS would otherwise report it as never having arrived.
    [ -f "$d/Some.Release-GRP.rar" ]
    rm -rf "$d"
}

@test "a set unpacks once, from its first volume only" {
    d=$(mktemp -d)
    printf 'archive\n' > "$d/Set-GRP.part01.rar"
    printf 'archive\n' > "$d/Set-GRP.part02.rar"
    run stage "STUBDIR=$d/bin"$'\n'"$(unrar_stub)"'
        errors=/dev/null
        UNPACK_FILE "'"$d"'/Set-GRP.part01.rar"; echo "one=${unpack_out#'"$d"'/}"
        UNPACK_FILE "'"$d"'/Set-GRP.part02.rar"; echo "two=[$unpack_out]"'
    # Part one names the set without its volume suffix; part two does nothing.
    [ "${lines[0]}" = "one=Set-GRP" ]
    [ "${lines[1]}" = "two=[]" ]
    [ -f "$d/Set-GRP/movie.mkv" ]
    rm -rf "$d"
}

@test "an unpacking that fails leaves nothing behind and says so" {
    d=$(mktemp -d); err=$(mktemp)
    printf 'not an archive\n' > "$d/Broken-GRP.rar"
    run stage 'mkdir -p "'"$d"'/bin"
        printf "#!/bin/sh\nexit 1\n" > "'"$d"'/bin/unrar"
        chmod +x "'"$d"'/bin/unrar"
        PATH="'"$d"'/bin:$PATH"
        errors="'"$err"'"; profile=TV
        UNPACK_FILE "'"$d"'/Broken-GRP.rar"; echo "out=[$unpack_out]"'
    [ "$output" = "out=[]" ]
    # No empty directory left looking as though something had come out of it.
    [ ! -e "$d/Broken-GRP" ]
    [ -f "$d/Broken-GRP.rar" ]
    [[ "$(cat "$err")" == *"could not be unpacked"* ]]
    rm -rf "$d" "$err"
}

@test "an archive whose name is already taken by a file is left alone" {
    d=$(mktemp -d); err=$(mktemp)
    printf 'archive\n' > "$d/Some-GRP.rar"
    printf 'in the way\n' > "$d/Some-GRP"
    run stage "STUBDIR=$d/bin"$'\n'"$(unrar_stub)"'
        errors="'"$err"'"; profile=TV
        UNPACK_FILE "'"$d"'/Some-GRP.rar"; echo "out=[$unpack_out]"'
    [ "$output" = "out=[]" ]
    # The file that was there is untouched.
    [ "$(cat "$d/Some-GRP")" = "in the way" ]
    [[ "$(cat "$err")" == *"in the way"* ]]
    rm -rf "$d" "$err"
}

# UNPACK_DIR has to run from the directory it unpacks into. It used to cd there
# and stay, so everything after it resolved a relative path against the wrong
# directory -- apply_perms's target among them, which left a downloaded
# directory with none of its permissions applied.
@test "unrarring does not move the process out of the working directory" {
    d=$(mktemp -d)
    mkdir -p "$d/Rel.Rar-GRP"
    touch "$d/Rel.Rar-GRP/archive.rar"
    run stage 'here=$PWD
               PATH="'"$d"'/bin:$PATH"
               mkdir -p "'"$d"'/bin"
               printf "#!/bin/sh\nexit 0\n" > "'"$d"'/bin/unrar"
               chmod +x "'"$d"'/bin/unrar"
               UNPACK_DIR "'"$d"'/Rel.Rar-GRP"
               [ "$PWD" = "$here" ] && echo same || echo "moved to $PWD"'
    [ "$output" = "same" ]
    rm -rf "$d"
}

@test "POST_PROCESS records what arrived, logs what did not, and verifies" {
    dl=$(mktemp -d); rec=$(mktemp); err=$(mktemp); ver=$(mktemp)
    printf 'four\n' > "$dl/here.nfo"          # five bytes
    run stage 'local_dl_dir="'"$dl"'"; record="'"$rec"'"; errors="'"$err"'"
               verify="'"$ver"'"; profile=TV; checksum=True
               LINESF="here.nfo
missing.nfo"; POST_PROCESS'
    [ "$status" -eq 0 ]
    [ "$(cut -f3,4 < "$rec")" = "$(printf 'here.nfo\tdownloaded')" ]
    [ "$(cut -f3,4 < "$err")" = "$(printf 'missing.nfo\tdid not arrive')" ]
    # checksum=True says what landed: its size, and the hash of a single file.
    [[ "$(cat "$ver")" == *"bytes=5"* ]]
    [[ "$(cat "$ver")" == *"sha256=$(sha256sum < "$dl/here.nfo" | cut -d" " -f1)"* ]]

    # -r keeps the record file out of it; the errors log is not a record of
    # downloads, so it stays.
    : > "$rec"
    run stage 'local_dl_dir="'"$dl"'"; record="'"$rec"'"; errors="'"$err"'"
               no_append=True; LINESF="here.nfo"; POST_PROCESS'
    [ ! -s "$rec" ]
    rm -rf "$dl" "$rec" "$err" "$ver"
}

@test "unrar runs only when autoUncompress asks for it" {
    dl=$(mktemp -d); mkdir "$dl/Rel.One-GRP"
    run stage 'local_dl_dir="'"$dl"'"; record=""; errors=""; verify=""
               UNPACK_DIR () { echo "unrar $1"; }
               LINESD="Rel.One-GRP"; POST_PROCESS'
    [ "$output" = "" ]
    run stage 'local_dl_dir="'"$dl"'"; record=""; errors=""; verify=""
               autoUncompress=True; UNPACK_DIR () { echo "unrar $1"; }
               LINESD="Rel.One-GRP"; POST_PROCESS'
    [ "$output" = "unrar $dl/Rel.One-GRP" ]
    # -nu turns it off again even where the config asked for it.
    run stage 'local_dl_dir="'"$dl"'"; record=""; errors=""; verify=""
               autoUncompress=True; nounrar=True; UNPACK_DIR () { echo "unrar $1"; }
               LINESD="Rel.One-GRP"; POST_PROCESS'
    [ "$output" = "" ]
    rm -rf "$dl"
}

# ---------------------------------------------------------------- SYMLINKS --
# The "ls -l" parser and the validity rules built on it. tests/fixtures/ls-l.txt
# is a listing of the shape a server produces, complete with the awkward cases:
# a name with a space, a target with spaces, an old entry whose date is a year
# rather than a time, an ISO date, and one line no parser could make sense of.

@test "link_targets reads name and target out of an ls -l listing" {
    run stage 'link_targets "'"${BATS_TEST_DIRNAME}"'/fixtures/ls-l.txt"'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "Rel.One-GRP	../../data/TV/Rel.One-GRP" ]
    [ "${lines[1]}" = "notes.nfo	../../data/TV/notes.nfo" ]
    [ "${lines[2]}" = "broken.link	../../data/TV/gone.mkv" ]
    # A name and a target may both contain spaces; only " -> " separates them.
    [ "${lines[3]}" = "spaced link	../../data/TV/with space name.mkv" ]
    # "Mon DD  YYYY" and the ISO form are both dates, and the name is whatever
    # follows either of them.
    [ "${lines[4]}" = "elsewhere.mkv	/srv/archive/elsewhere.mkv" ]
    [ "${lines[5]}" = "deep.mkv	../../data/TV/Rel.One-GRP/movie.mkv" ]
    # The unparsable line and the two non-symlinks contribute nothing.
    [ "${#lines[@]}" -eq 6 ]
}

@test "a line with no date it recognises yields no record at all" {
    run stage 'printf "%s\n" "lrwxrwxrwx 1 u g 12 who knows -> anywhere" | link_targets /dev/stdin'
    [ "$output" = "" ]
}

@test "link_normalize folds . and .. out of a remote path" {
    run stage 'link_normalize "/srv/complete/TV/../../data/TV/gone.mkv"; echo "$link_norm"
               link_normalize "rel/./path/../x"; echo "$link_norm"
               link_normalize "/a/b/"; echo "$link_norm"'
    [ "${lines[0]}" = "/srv/data/TV/gone.mkv" ]
    [ "${lines[1]}" = "rel/x" ]
    [ "${lines[2]}" = "/a/b" ]
}

@test "link_data_path resolves the parsed target and falls back to the layout" {
    run stage 'listfile4="'"${BATS_TEST_DIRNAME}"'/fixtures/ls-l.txt"
               remote_dl_dir=/srv/complete/TV; data_dir=/srv/data/; dirname=TV
               LOAD_LINKS
               link_data_path "notes.nfo@"; echo "$link_path"
               link_data_path "elsewhere.mkv"; echo "$link_path"
               link_data_path "who.knows.mkv"; echo "$link_path"'
    # A relative target hangs off the completed directory, an absolute one
    # stands on its own, and an entry with no parsed target falls back to the
    # path the data_dir/dirname layout implies.
    [ "${lines[0]}" = "/srv/data/TV/notes.nfo" ]
    [ "${lines[1]}" = "/srv/archive/elsewhere.mkv" ]
    [ "${lines[2]}" = "/srv/data/TV/who.knows.mkv" ]
}

# The listing and the data behind it, as VALIDATE_LINKS expects to find them:
# of everything the long listing names, only gone.mkv is missing from the data
# directory.
links () {
    cat <<'SNIP'
    listfile4="$FIXTURES/ls-l.txt"
    remote_dl_dir=/srv/complete/TV; data_dir=/srv/data/; dirname=TV
    listfile=$(mktemp); listfile2=$(mktemp)
    printf '%s\n' 'Rel.One-GRP/' 'notes.nfo' 'with space name.mkv' > "$listfile2"
    printf '%s\n' 'Rel.One-GRP@   4.1G  2026-08-23 17:10' \
                  'broken.link@     22  2026-08-22 09:03' \
                  'notes.nfo@       23  2026-08-23 17:10' \
                  'spaced link@     33  2019-01-02 00:00' \
                  'elsewhere.mkv@   30  2026-08-23 17:10' \
                  'deep.mkv@        41  2026-08-23 17:10' \
                  'who knows@       12  2026-08-23 17:10' > "$listfile"
    LOAD_LINKS
SNIP
}

@test "VALIDATE_LINKS drops the links whose data is gone and keeps the rest" {
    run stage 'FIXTURES="'"${BATS_TEST_DIRNAME}"'/fixtures"'$'\n'"$(links)"'
        VALIDATE_LINKS
        echo "B=[$LINESB]"
        cat "$listfile"
        rm -f "$listfile" "$listfile2"'
    [ "${lines[0]}" = "alftp: pruning 1 broken symlink(s) from /srv/complete/TV" ]
    [ "${lines[1]}" = "B=[broken.link]" ]
    # Everything else survives: the two live links, the one pointing outside the
    # data directory entirely (elsewhere.mkv), the one pointing deeper into it
    # than the data listing goes (deep.mkv), and the entry whose ls -l line
    # could not be parsed at all (who knows). None of those could be checked,
    # and unchecked means kept.
    [ "${lines[2]}" = "Rel.One-GRP@   4.1G  2026-08-23 17:10" ]
    [ "${lines[3]}" = "notes.nfo@       23  2026-08-23 17:10" ]
    [ "${lines[4]}" = "spaced link@     33  2019-01-02 00:00" ]
    [ "${lines[5]}" = "elsewhere.mkv@   30  2026-08-23 17:10" ]
    [ "${lines[6]}" = "deep.mkv@        41  2026-08-23 17:10" ]
    [ "${lines[7]}" = "who knows@       12  2026-08-23 17:10" ]
    [ "${#lines[@]}" -eq 8 ]
}

@test "prune_broken=False leaves the listing alone" {
    run stage 'FIXTURES="'"${BATS_TEST_DIRNAME}"'/fixtures"'$'\n'"$(links)"'
        prune_broken=False; VALIDATE_LINKS
        echo "B=[$LINESB] count=$link_count"
        grep -c broken.link "$listfile"
        rm -f "$listfile" "$listfile2"'
    [ "${lines[0]}" = "B=[] count=0" ]
    [ "${lines[1]}" = "1" ]
}

@test "a listing with no long form to check it against prunes nothing" {
    run stage 'FIXTURES="'"${BATS_TEST_DIRNAME}"'/fixtures"'$'\n'"$(links)"'
        listfile4=""; LOAD_LINKS; VALIDATE_LINKS
        echo "B=[$LINESB] targets=${#LINK_TARGET[@]}"
        grep -c broken.link "$listfile"
        rm -f "$listfile" "$listfile2"'
    [ "${lines[0]}" = "B=[] targets=0" ]
    [ "${lines[1]}" = "1" ]
}

@test "DLPRUNE removes a broken link, prints it under --dry-run and skips it under -do" {
    run stage 'LINESB="broken.link"; DLPRUNE'
    [ "${lines[0]}" = 'rm -f "broken.link"; !echo PRUNED: "broken.link"' ]
    run stage 'LINESB="broken.link"; dry_run=True; DLPRUNE'
    [ "${lines[0]}" = '!echo DRY-RUN: rm broken "broken.link"' ]
    run stage 'LINESB="broken.link"; norm=True; echo "[$(DLPRUNE)]"'
    [ "$output" = "[]" ]
}

@test "the listing session captures the long listing, and only where it has somewhere to go" {
    run stage 'listfile4="/tmp/x y/list4"; ls_l_cmd; listfile4=""; echo "off:[$(ls_l_cmd)]"'
    [ "${lines[0]}" = 'ls -l > "/tmp/x y/list4"' ]
    [ "${lines[1]}" = "off:[]" ]
}

# A fresh listing as lftp writes one -- "size date time name", before
# format_columns has been anywhere near it -- plus the data listing beside it
# that says which of the entries are directories. $raw and $rawdata are the two
# files; the arguments are the lines of each, separated by "--".
listing () {
    cat <<'SNIP'
    raw=$(mktemp); rawdata=$(mktemp)
    printf '%s\n' '4.1G  2026-08-23 17:10 Rel.One-GRP@' \
                  '2.1K  2026-08-22 09:03 notes.nfo' \
                  '9.9G  2026-08-25 11:00 Rel.Three-GRP@' > "$raw"
    printf '%s\n' 'Rel.One-GRP/' 'notes.nfo' 'Rel.Three-GRP/' > "$rawdata"
    order () { n=""; for v in "${TUI_ORDER[@]}"; do n="$n ${TUI_NAME[v]}"; done; echo "[${n# }]"; }
    depths () { d=""; for v in "${TUI_ORDER[@]}"; do d="$d${TUI_DEPTH[v]}"; done; echo "$d"; }
    merge () { tui_upd_new=0; tui_upd_gone=0; tui_upd_kept=0
               tui_upd_group "$1" "$raw" "$rawdata"
               tui_status_scan; tui_widths; tui_rebuild_vis; }
SNIP
}

@test "u asks for a check of the remote" {
    run stage 'tui_key_action u; echo "$tui_action"'
    [ "$output" = "update" ]
}

@test "the loop ticks while nothing is typed and still ends at end of input" {
    run stage "$(tree)"'
        TICKS=0; KI=0
        tui_tick () { TICKS=$(( TICKS + 1 )); tui_dirty=1; }
        tui_read_key () {
            if (( KI < 3 )); then KI=$(( KI + 1 )); TUI_KEYRC=2; return 1; fi
            return 1
        }
        tui_loop; echo "$TICKS $tui_result"'
    # Three timeouts are three ticks and no exit; the fourth read is the
    # terminal going away, which is what ends the loop.
    [ "$output" = "3 exit" ]
}

@test "a check leaves surviving entries where the user put them" {
    run stage "$(tree)"$'\n'"$(listing)"'
        tui_cur=4; tui_move_node up          # Rel.Two-GRP above the open release
        echo "$(order)"; merge -1; echo "$(order)"; echo "$tui_upd_new"'
    # Rel.Two-GRP is not in the fresh listing and carries no mark, so it goes;
    # everything else keeps the order the reorder gave it, children and all,
    # and the entry that appeared is added at the end.
    [ "${lines[0]}" = "[Rel.Two-GRP@ Rel.One-GRP@ CD1/ movie.mkv movie.nfo notes.nfo]" ]
    [ "${lines[1]}" = "[Rel.One-GRP@ CD1/ movie.mkv movie.nfo notes.nfo Rel.Three-GRP@]" ]
    [ "${lines[2]}" = "1" ]
}

@test "an entry that is gone but marked stays, and the count says so" {
    run stage "$(tree)"$'\n'"$(listing)"'
        tui_cur=4; tui_toggle                # mark Rel.Two-GRP for download
        merge -1
        echo "$(order)"; echo "$tui_upd_new $tui_upd_gone $tui_upd_kept"
        echo "$tui_nsel ${TUI_STATE[1]}"'
    [ "${lines[0]}" = "[Rel.One-GRP@ CD1/ movie.mkv movie.nfo Rel.Two-GRP@ notes.nfo Rel.Three-GRP@]" ]
    [ "${lines[1]}" = "1 0 1" ]
    # The mark it was kept for is still on it and still counted.
    [ "${lines[2]}" = "1 1" ]
}

@test "a directory holding a selection is not dropped from under it" {
    run stage "$(tree)"$'\n'"$(listing)"'
        tui_cur=2; tui_toggle                # movie.mkv, inside Rel.One-GRP
        merge -1
        echo "$(order)"; echo "$tui_nsel $tui_upd_kept"'
    # Rel.One-GRP is still listed, so nothing here turns on it; what matters is
    # that the selection below it survived the merge intact.
    [ "${lines[0]}" = "[Rel.One-GRP@ CD1/ movie.mkv movie.nfo notes.nfo Rel.Three-GRP@]" ]
    [ "${lines[1]}" = "1 0" ]
}

@test "dropping an entry takes its whole subtree and leaves the rest contiguous" {
    run stage "$(tree)"$'\n'"$(listing)"'
        printf %s "$(depths)"; echo " -> "
        merge -1
        echo "$(depths)"
        tui_subtree "${TUI_POS[0]}"; echo "$tui_r0 $tui_r1"'
    [ "${lines[0]}" = "011100 -> " ]
    # Rel.Two-GRP went; the three children of Rel.One-GRP are still the run
    # directly behind it, and the new entry is at depth 0 at the end.
    [ "${lines[1]}" = "011100" ]
    [ "${lines[2]}" = "1 4" ]
}

@test "a merge into an open directory adds to that sibling group only" {
    run stage "$(tree)"$'\n'"$(listing)"'
        printf "%s\n" "13K  2026-08-25 11:00 extra.sub" > "$raw"
        : > "$rawdata"
        merge 0
        echo "$(order)"; echo "$(depths)"; echo "$tui_upd_new $tui_upd_gone"'
    # Everything that was in the directory has gone from the listing, but the
    # new entry still lands inside it, directly behind its siblings.
    [ "${lines[0]}" = "[Rel.One-GRP@ extra.sub Rel.Two-GRP@ notes.nfo]" ]
    [ "${lines[1]}" = "0100" ]
    [ "${lines[2]}" = "1 3" ]
}

@test "a check with nothing to say still leaves the tree alone" {
    run stage "$(tree)"$'\n'"$(listing)"'
        : > "$raw"
        merge -1; echo "$(order)"; echo "$tui_upd_new $tui_upd_gone $tui_upd_kept"'
    # An empty listing is a check that did not work, not a directory that
    # emptied itself: nothing is dropped on the strength of it.
    [ "${lines[0]}" = "[Rel.One-GRP@ CD1/ movie.mkv movie.nfo Rel.Two-GRP@ notes.nfo]" ]
    [ "${lines[1]}" = "0 0 0" ]
}

@test "srcs mode keeps a check to the source directories the profile named" {
    run stage "$(tree)"$'\n'"$(listing)"'
        srcs_mode=True; SRCS=(Rel.One-GRP notes.nfo)
        merge -1; echo "$(order)"; echo "$tui_upd_new"'
    # Rel.Three-GRP is on the server but is not one of the srcs, so it is no
    # more part of the top level after the check than it was before it.
    [ "${lines[0]}" = "[Rel.One-GRP@ CD1/ movie.mkv movie.nfo notes.nfo]" ]
    [ "${lines[1]}" = "0" ]
}

@test "the title bar carries a turning glyph while a check is running" {
    run stage "$(tree)"'
        TUI_OUT=1; tui_upd_pid=999; tui_draw; echo
        tui_spin=2; tui_draw; echo'
    [[ "$output" == *"[-]"* ]]
    [[ "$output" == *"[|]"* ]]
}

@test "closing the picker takes the check's listing files back" {
    run stage '
        d=$(mktemp -d)
        tui_upd_top="$d/top"; tui_upd_log="$d/log"
        TUI_UPD_RAW=([3]="$d/raw3"); TUI_UPD_DATA=([3]="$d/data3")
        touch "$d/top" "$d/log" "$d/raw3" "$d/data3"
        tui_upd_clean
        echo "$(ls -A "$d" | wc -l) ${#TUI_UPD_RAW[@]}"
        # And again with nothing left to remove, which is the state every run
        # that never checked anything closes in.
        tui_upd_clean; echo "$?"
        rm -rf "$d"'
    [ "${lines[0]}" = "0 0" ]
    [ "${lines[1]}" = "0" ]
}

# --------------------------------------------------- the recursive listing --

# An "ls -R" reply as a server sends one, with the three things that break a
# naive parser in it: a name with spaces, a symlink (whose " -> target" is not
# part of its name), and a date in the other format ls uses once a file is old
# enough to lose its time. $lsr is the file.
lsr () {
    cat <<'SNIP'
    lsr=$(mktemp)
    cat > "$lsr" <<'LSR'
.:
total 8
-rw-r--r--   1 u  g        11 Aug 26 12:13 notes.nfo
drwxr-xr-x   3 u  g       100 Aug 26 12:13 Rel.One-GRP
lrwxrwxrwx   1 u  g        23 Aug 26 12:13 latest -> ./Rel.One-GRP
-rw-r--r--   1 u  g       100 Jan  5  2019 old file.txt

./Rel.One-GRP:
total 8
drwxr-xr-x   2 u  g        60 Aug 26 12:13 CD1
-rw-r--r--   1 u  g        15 Aug 26 12:13 movie.mkv

./Rel.One-GRP/CD1:
total 4
-rw-r--r--   1 u  g         9 Aug 26 12:13 part1.bin
LSR
    # The parsers separate fields with \037, not a tab, so that an empty field
    # survives being read back (see tui_parse_listing). Translated to tabs here
    # so the expectations stay readable.
    recs () { tui_rec_parse_lsr "$lsr" /data/TV 2026 | tr "\037" "\t"; }
SNIP
}

@test "the ls -R parser reads a walk, spaces, symlinks and old dates alike" {
    run stage "$(lsr)"'
        recs | grep -c "^D"
        recs | grep "^E	/data/TV	old file.txt"
        recs | grep "^E	/data/TV	latest"
        recs | grep "^E	/data/TV	Rel.One-GRP"'
    # Three directories were walked: the root and the two blocks under it.
    [ "${lines[0]}" = "3" ]
    # A name with spaces survives, and "Jan  5  2019" is a date with no time.
    [ "${lines[1]}" = $'E\t/data/TV\told file.txt\t0\t100\t2019-01-05 00:00' ]
    # The symlink keeps its own name and nothing of its target.
    [ "${lines[2]}" = $'E\t/data/TV\tlatest\t0\t23\t2026-08-26 12:13' ]
    # A directory's size is the recursive total of what is under it -- 15 for
    # movie.mkv plus 9 for part1.bin -- not the 100 ls gave the directory entry.
    [ "${lines[3]}" = $'E\t/data/TV\tRel.One-GRP\t1\t24\t2026-08-26 12:13' ]
}

@test "a directory the walk covered is known even when it is empty" {
    run stage '
        lsr=$(mktemp)
        printf "%s\n" ".:" "total 0" "" "./Empty:" "total 0" > "$lsr"
        tui_rec_parse_lsr "$lsr" /data/TV 2026 | tr "\037" "\t"'
    # No entries at all, but both blocks are still reported, which is what
    # stops tui_fetch spending a login on a directory known to hold nothing.
    [ "${lines[0]}" = $'D\t/data/TV\t\t1\t0\t' ]
    [ "${lines[1]}" = $'D\t/data/TV/Empty\t\t1\t0\t' ]
}

@test "a reply that is not recursive is spotted, and an empty tree is not" {
    run stage '
        f=$(mktemp)
        # What a server that ignores -R sends: one flat block with a directory
        # in it and no block describing that directory.
        printf "%s\n" ".:" "drwxr-xr-x 2 u g 60 Aug 26 12:13 Sub" > "$f"
        tui_rec_recursive "$f"; echo "flat=$?"
        # The same listing with no directory in it is a complete answer.
        printf "%s\n" ".:" "-rw-r--r-- 1 u g 11 Aug 26 12:13 a.txt" > "$f"
        tui_rec_recursive "$f"; echo "leaf=$?"
        printf "%s\n" ".:" "drwxr-xr-x 2 u g 60 Aug 26 12:13 Sub" "" "./Sub:" > "$f"
        tui_rec_recursive "$f"; echo "deep=$?"
        : > "$f"; tui_rec_recursive "$f"; echo "empty=$?"'
    [ "${lines[0]}" = "flat=1" ]
    [ "${lines[1]}" = "leaf=0" ]
    [ "${lines[2]}" = "deep=0" ]
    [ "${lines[3]}" = "empty=1" ]
}

@test "the find/du fallback sizes directories and deliberately not files" {
    run stage '
        f=$(mktemp); d=$(mktemp)
        printf "%s\n" "./" "./Rel.One-GRP/" "./Rel.One-GRP/movie.mkv" "./notes.nfo" > "$f"
        printf "%s\t%s\n" 1.0K ./notes.nfo 1.0K ./Rel.One-GRP/movie.mkv \
                          2.0K ./Rel.One-GRP 3.0K . > "$d"
        tui_rec_parse_find "$f" "$d" /data/TV | tr "\037" "\t"'
    [ "${lines[0]}" = $'D\t/data/TV\t\t1\t3.0K\t' ]
    [ "${lines[1]}" = $'D\t/data/TV/Rel.One-GRP\t\t1\t2.0K\t' ]
    [ "${lines[2]}" = $'E\t/data/TV\tRel.One-GRP\t1\t2.0K\t' ]
    # du rounds a file up to a block, and a file size is what the completeness
    # check compares against what is on disk: an 11 byte file reported as 1.0K
    # would read as "downloaded but short" for ever. So files get no size here.
    [ "${lines[3]}" = $'E\t/data/TV/Rel.One-GRP\tmovie.mkv\t0\t\t' ]
    [ "${lines[4]}" = $'E\t/data/TV\tnotes.nfo\t0\t\t' ]
}

# The tree the picker has, plus a walk of the data behind it already cached.
# data_dir/dirname is what link_data_path falls back to for an entry with no
# parsed symlink target, which is every entry here.
rec () {
    cat <<'SNIP'
    data_dir=/data/; dirname=TV; remote_dl_dir=/complete/TV
    order () { n=""; for v in "${TUI_ORDER[@]}"; do n="$n ${TUI_NAME[v]}"; done; echo "[${n# }]"; }
    depths () { d=""; for v in "${TUI_ORDER[@]}"; do d="$d${TUI_DEPTH[v]}"; done; echo "$d"; }
    tui_rec_store < <(tr '\t' '\037' <<'RECS'
D	/data/TV		1	158
D	/data/TV/Rel.One-GRP		1	24
D	/data/TV/Rel.One-GRP/CD1		1	9
E	/data/TV	Rel.One-GRP	1	24	2026-08-26 12:13
E	/data/TV	Rel.Two-GRP	1	0	2026-08-26 12:13
E	/data/TV	notes.nfo	0	11	2026-08-26 12:13
E	/data/TV/Rel.One-GRP	CD1	1	9	2026-08-26 12:13
E	/data/TV/Rel.One-GRP	movie.mkv	0	15	2026-08-26 12:13
E	/data/TV/Rel.One-GRP/CD1	part1.bin	0	9	2026-08-26 12:13
RECS
)
SNIP
}

@test "the cache is read back by absolute data path, empty directories and all" {
    run stage "$(rec)"'
        echo "${#TUI_RECKIDS[@]} ${TUI_RECSIZE[/data/TV/Rel.One-GRP]}"
        echo "${TUI_RECKIDS[/data/TV]//$'"'"'\n'"'"'/ }"
        # Rel.Two-GRP was listed as a directory but no block describes it, so
        # it is not covered and is still worth a login.
        echo "kids=[${TUI_RECKIDS[/data/TV/Rel.One-GRP/CD1]}] two=${TUI_RECKIDS[/data/TV/Rel.Two-GRP]:-<none>}"'
    [ "${lines[0]}" = "3 24" ]
    [ "${lines[1]}" = "Rel.One-GRP Rel.Two-GRP notes.nfo" ]
    [ "${lines[2]}" = "kids=[part1.bin] two=<none>" ]
}

@test "the walk fills in the tree, and Tab then costs no login at all" {
    run stage "$(tree)"$'\n'"$(rec)"'
        # The tree helper opens Rel.One-GRP by hand; start again with nothing
        # loaded, which is what the picker has when the walk comes back.
        TUI_LOADED[0]=0; TUI_OPEN[0]=0
        TUI_ORDER=(0 1 2); tui_reindex; tui_rebuild_vis
        tui_rec_expand; tui_rec_sizes
        echo "$(order)"; echo "$(depths)"
        echo "loaded=${TUI_LOADED[0]}${TUI_LOADED[6]} open=${TUI_OPEN[0]}"
        # A subtree has to stay one contiguous run of TUI_ORDER.
        tui_subtree "${TUI_POS[0]}"; echo "run=$tui_r0-$tui_r1"
        # And opening it now goes nowhere near a login.
        LOGINS=0; lftp () { LOGINS=$(( LOGINS + 1 )); return 1; }
        tui_cur=0; tui_toggle_open; echo "logins=$LOGINS $(names)"'
    # The whole walked tree is there, each directory directly behind its parent.
    [ "${lines[0]}" = "[Rel.One-GRP@ CD1/ part1.bin movie.mkv Rel.Two-GRP@ notes.nfo]" ]
    [ "${lines[1]}" = "012100" ]
    [ "${lines[2]}" = "loaded=11 open=0" ]
    [ "${lines[3]}" = "run=1-4" ]
    [ "${lines[4]}" = "logins=0 [Rel.One-GRP@ CD1/ movie.mkv Rel.Two-GRP@ notes.nfo]" ]
}

@test "a directory already opened keeps what it has" {
    run stage "$(tree)"$'\n'"$(rec)"'
        tui_rec_expand
        echo "$(order)"'
    # Rel.One-GRP was open before the walk landed, so it keeps exactly what it
    # had -- movie.nfo, which the walk does not know about, is neither lost nor
    # listed twice. CD1 underneath it was never opened, so it is filled in.
    # Rel.Two-GRP the walk never reached, and notes.nfo is not a directory.
    [ "$output" = "[Rel.One-GRP@ CD1/ part1.bin movie.mkv movie.nfo Rel.Two-GRP@ notes.nfo]" ]
}

@test "a directory finally has a real size, and a file keeps the one it had" {
    run stage "$(tree)"$'\n'"$(rec)"'
        echo "before=${TUI_SIZE[0]} ${TUI_SIZE[4]} ${TUI_DUSIZE[Rel.One-GRP]:-<none>}"
        TUI_LOADED[0]=0; TUI_OPEN[0]=0; TUI_ORDER=(0 1 2)
        tui_reindex; tui_rec_expand; tui_rec_sizes
        echo "after=${TUI_SIZE[0]} ${TUI_DUSIZE[Rel.One-GRP]}"
        # The top-level file keeps the figure $listfile5 gave it, and the file
        # inside the release keeps the exact one the walk gave it.
        echo "files=${TUI_SIZE[2]} ${TUI_SIZE[7]}"
        # A real total is what tui_has_du was waiting for.
        tui_has_du 0; echo "hasdu=$?"'
    # 4.1G is the length of the symlink dressed up as a size: it is the
    # completed directory's own listing and says nothing about the release.
    [ "${lines[0]}" = "before=4.1G 4.0G <none>" ]
    [ "${lines[1]}" = "after=24 24" ]
    [ "${lines[2]}" = "files=2.1K 15" ]
    [ "${lines[3]}" = "hasdu=0" ]
}

@test "the expansion stops at its budget rather than blocking the tick" {
    run stage "$(tree)"$'\n'"$(rec)"'
        TUI_LOADED[0]=0; TUI_OPEN[0]=0; TUI_ORDER=(0 1 2); tui_reindex
        tui_rec_budget=1; tui_rec_expand
        echo "$(order)"; echo "added=$tui_rec_added loaded=${TUI_LOADED[0]}"'
    # One directory's worth of children is over the budget, so CD1 is left for
    # tui_fetch to serve out of the same cache when the user opens it.
    [ "${lines[0]}" = "[Rel.One-GRP@ CD1/ movie.mkv Rel.Two-GRP@ notes.nfo]" ]
    [ "${lines[1]}" = "added=2 loaded=1" ]
}

@test "a root is walked once, and srcs mode waits for the src to be opened" {
    run stage '
        data_dir=/data/; dirname=TV
        tui_rec_want /data/TV; tui_rec_want /data/TV; tui_rec_want /data/films
        echo "${#tui_rec_queue[@]} ${tui_rec_queue[0]} ${tui_rec_queue[1]}"
        tui_rec_queue=(); TUI_RECDONE=()
        srcs_mode=True; tui_rec_kick; echo "srcs=${#tui_rec_queue[@]}"
        tui_rec_kicked=0; srcs_mode=""; tui_rec_kick
        echo "plain=${#tui_rec_queue[@]} ${tui_rec_queue[0]}"
        # Kicking twice is one walk: the queue is the record of what was asked
        # for, not of what has finished.
        tui_rec_kicked=0; tui_rec_kick; echo "again=${#tui_rec_queue[@]}"
        tui_rec_kicked=0; recursive_listing=False; TUI_RECDONE=()
        tui_rec_queue=(); tui_rec_kick; echo "off=${#tui_rec_queue[@]}"'
    [ "${lines[0]}" = "2 /data/TV /data/films" ]
    [ "${lines[1]}" = "srcs=0" ]
    [ "${lines[2]}" = "plain=1 /data/TV" ]
    [ "${lines[3]}" = "again=1" ]
    [ "${lines[4]}" = "off=0" ]
}

@test "recursive_listing=False leaves the picker exactly as it was" {
    run stage "$(tree)"$'\n'"$(rec)"'
        recursive_listing=False
        TUI_LOADED[0]=0; TUI_OPEN[0]=0; TUI_ORDER=(0 1 2); tui_reindex
        tui_rec_expand; echo "$(order) loaded=${TUI_LOADED[0]}"
        tui_rec_fill 0 0; echo "fill=$?"'
    [ "${lines[0]}" = "[Rel.One-GRP@ Rel.Two-GRP@ notes.nfo] loaded=0" ]
    [ "${lines[1]}" = "fill=1" ]
}

@test "the title bar turns while the walk is running, and closing stops it" {
    run stage "$(tree)"'
        TUI_OUT=1; tui_rec_pid=999; tui_spin=1; tui_draw; echo
        d=$(mktemp -d)
        tui_rec_out="$d/out"; tui_rec_du="$d/du"
        tui_rec_log="$d/log"; tui_rec_script="$d/script"
        touch "$d/out" "$d/du" "$d/log" "$d/script"
        tui_rec_pid=""; tui_rec_queue=(/data/TV)
        tui_rec_stop; tui_rec_clean
        echo "CLEANED left=$(ls -A "$d" | wc -l) queued=${#tui_rec_queue[@]}"
        tui_rec_clean; echo "AGAIN=$?"
        rm -rf "$d"'
    # tui_draw writes a whole screen, so the checks below name what they want
    # rather than counting lines.
    [[ "$output" == *'[\]'* ]]
    [[ "$output" == *"CLEANED left=0 queued=0"* ]]
    [[ "$output" == *"AGAIN=0"* ]]
}

@test "a walk that came back with nothing changes nothing" {
    run stage "$(tree)"'
        order () { n=""; for v in "${TUI_ORDER[@]}"; do n="$n ${TUI_NAME[v]}"; done; echo "[${n# }]"; }
        tui_rec_out=$(mktemp); tui_rec_log=$(mktemp); : > "$tui_rec_out"
        tui_rec_mode=lsr; tui_rec_pid=$$
        # wait on a pid that is not a child of this shell is a no-op failure,
        # which is exactly the "the login went wrong" case.
        tui_rec_reap
        echo "$(order) pid=[$tui_rec_pid] cached=${#TUI_RECKIDS[@]}"'
    [ "$output" = "[Rel.One-GRP@ CD1/ movie.mkv movie.nfo Rel.Two-GRP@ notes.nfo] pid=[] cached=0" ]
}

@test "an ls -R the server ignored starts the find/du pair for the same root" {
    run stage '
        tui_rec_root=/data/TV; tui_rec_mode=lsr; tui_rec_pid=$$
        tui_rec_out=$(mktemp); tui_rec_log=$(mktemp)
        printf "%s\n" ".:" "drwxr-xr-x 2 u g 60 Aug 26 12:13 Sub" > "$tui_rec_out"
        # The walk is not really run: its script is all this needs to see.
        tui_rec_start () { echo "restarted as $1"; tui_rec_mode=$1; }
        tui_rec_reap'
    [ "$output" = "restarted as find" ]
}

@test "the generated walk asks the server for one command, or for the pair" {
    run stage '
        server=example.com; username=u; password=pw; port=21
        tui_rec_root="/data/T V"
        lftp () { :; }
        tui_rec_start lsr; grep -E "^(cd|ls|find|du|set cmd)" "$tui_rec_script"
        echo "--"
        tui_rec_pid=""; tui_rec_start find
        grep -E "^(find|du)" "$tui_rec_script"'
    [ "${lines[0]}" = "set cmd:fail-exit yes" ]
    [ "${lines[1]}" = 'cd "/data/T V"' ]
    [[ "${lines[2]}" == "ls -R > "* ]]
    [ "${lines[3]}" = "--" ]
    [[ "${lines[4]}" == "find > "* ]]
    [[ "${lines[5]}" == "du -a -h > "* ]]
}

@test "SIZE, DATE and STATUS are pinned to the right-hand edge" {
    run stage "$(tree)"'
        TUI_COLS=80; tui_statusw=0; tui_widths; tui_name_field
        echo "$(( tui_gutw + 2 + tui_namefld + tui_metaw )) $tui_metaw"
        TUI_COLS=120; tui_name_field
        echo "$(( tui_gutw + 2 + tui_namefld + tui_metaw )) $tui_metaw"'
    # The row reaches the right-hand edge exactly, at either width: the
    # metadata block keeps its size and the name column takes up the slack.
    # (The 2 is the mark gutter; tui_gutw is the line numbers to the left of
    # it, which take their width off the name column like any other.)
    [ "${lines[0]}" = "80 ${lines[0]#* }" ]
    [ "${lines[1]}" = "120 ${lines[1]#* }" ]
    # ... and the block itself did not change size between the two.
    [ "${lines[0]#* }" = "${lines[1]#* }" ]
}

# A name longer than the room there is used to be given its full width anyway,
# which made the row longer than the terminal -- and tui_fit then cut it at the
# right-hand edge, which is the end SIZE, DATE and STATUS are pinned to. The
# moment a transfer started and the STATUS column appeared, the columns were
# pushed off the screen: sizes and statuses that "looked fine until I started
# downloading".
@test "a name too long for the row is cut, and the columns are not" {
    run stage "$(tree)"'
        N=Some.Long.Release.Name.2026.1080p.WEB-DL.DDP5.1.H.264-GROUPNAME
        TUI_NAME[0]="$N@"; TUI_SIZE[0]=4.1G; TUI_DATE[0]="2026-08-23 17:10"
        TUI_COLS=80; TUI_LINES=10; tui_rows_calc; tui_widths
        tui_cur=0; tui_top=0
        TUI_STATUS[0]="42%"; tui_status_width
        tui_name_field
        echo "row=$(( tui_gutw + 2 + tui_namefld + tui_metaw )) namew=$tui_namew"
        exec {TUI_OUT}>&1
        tui_draw' 
    # The row still ends exactly at the edge, even though the longest name on
    # its own is wider than the space left for it.
    [ "${lines[0]}" = "row=80 namew=64" ]
    # The heading and the row both keep every column, STATUS included.
    [[ "$output" == *"SIZE"*"DATE"*"STATUS"* ]]
    [[ "$output" == *"4.1G"*"2026-08-23 17:10"*"42%"* ]]
    # ... and the name is what gave way.
    [[ "$output" != *"264-GROUPNAME"* ]]
}

@test "the name column has a floor, so it never disappears entirely" {
    run stage "$(tree)"'
        TUI_COLS=30; tui_statusw=0; tui_widths; tui_name_field
        echo "$tui_namefld"
        TUI_COLS=10; tui_name_field; echo "$tui_namefld"'
    # 30 columns leaves the name nothing once the metadata has its share, and
    # a name cut to nothing says less than a cut-off date does.
    [ "${lines[0]}" = "12" ]
    [ "${lines[1]}" = "12" ]
}

@test "a column is never narrower than its own heading" {
    run stage "$(tree)"'
        TUI_COLS=80
        TUI_SIZE=([0]=1 [1]=2 [2]=3 [3]=4 [4]=5 [5]=6)
        TUI_STATUS=([0]=c)
        tui_widths; tui_status_width; tui_name_field
        echo "size=$tui_sizew/$tui_sizedw status=$tui_statusw/$tui_statusdw"'
    # One-character sizes and a one-character status would otherwise leave the
    # "SIZE" and "STATUS" headings hanging off the right-hand edge.
    [ "$output" = "size=1/4 status=1/6" ]
}

@test "a name too long for its field is cut, not allowed to shove the columns off" {
    run stage "$(tree)"'
        TUI_COLS=40; tui_widths; tui_name_field
        TUI_NAME[0]="a.very.long.release.name.that.will.not.fit-GRP"
        tui_draw > /dev/null 2>&1
        tui_fit "${TUI_NAME[0]}" "$tui_namefld"; echo "${#tui_fitted} <= $tui_namefld"'
    [ "${lines[0]}" = "$(echo "${lines[0]}" | awk -F" <= " "{print (\$1 <= \$2) ? \$0 : \"OVERFLOW\"}")" ]
}

@test "byte counts are written the way the listing writes them" {
    run stage 'for b in 11 999 1500 2048 4000000 4123456789 45000000000; do
                   tui_human "$b"; printf "%s " "$tui_hsz"
               done; echo'
    # One decimal below ten of a unit and none above, matching "cls -h", so a
    # size the walk counted exactly sits in the SIZE column looking like every
    # other size rather than like a raw number.
    [ "$output" = "11 999 1.4K 2.0K 3.8M 3.8G 41G " ]
}

@test "a directory's total is shown humanised but compared exactly" {
    run stage "$(tree)"'
        remote_dl_dir=/complete/TV; data_dir=/data/; dirname=TV
        TUI_RECKIDS[/data/TV/Rel.One-GRP]="CD1"
        TUI_RECSIZE[/data/TV/Rel.One-GRP]=4000000
        tui_rec_sizes
        echo "shown=${TUI_SIZE[0]} exact=${TUI_DUSIZE[Rel.One-GRP]}"'
    # The SIZE column gets 3.8M; the arithmetic keeps every byte, because the
    # completeness check and the download percentage both divide by it.
    [ "$output" = "shown=3.8M exact=4000000" ]
}

@test "a nested directory gets a percentage, not a byte count" {
    run stage "$(tree)"'
        remote_dl_dir=/complete/TV; data_dir=/data/; dirname=TV
        # node 3 is CD1/, one level down, which has no du entry of its own.
        TUI_RECSIZE[/data/TV/Rel.One-GRP/CD1]=4000000
        tui_dl_expected 3; echo "nested=$tui_dl_exp"
        unset "TUI_RECSIZE[/data/TV/Rel.One-GRP/CD1]"
        tui_dl_expected 3; echo "without=$tui_dl_exp"'
    # With the walk's figure it can show a percentage; without it, -1 means
    # "show the bytes transferred instead", which is the old behaviour.
    [ "${lines[0]}" = "nested=4000000" ]
    [ "${lines[1]}" = "without=-1" ]
}

@test "progress counts what is on disk, not the size a sparse file claims" {
    # pget -n 5 writes five chunks at their own offsets, so until the last one
    # lands the file is full of holes and its apparent size is nearly the whole
    # figure. Measured against a range-serving HTTP server, three seconds into a
    # 120 MB transfer, --apparent-size said 81% and the blocks on disk said 5%.
    # A file with 4 KiB written at the far end reproduces that shape exactly.
    dl=$(mktemp -d)
    dd if=/dev/zero of="$dl/Rel.Two-GRP" bs=4096 count=1 seek=255 \
        > /dev/null 2>&1
    apparent=$(du -sb "$dl/Rel.Two-GRP" | cut -f1)
    allocated=$(du -s --block-size=1 "$dl/Rel.Two-GRP" | cut -f1)
    if (( allocated >= apparent )); then
        rm -rf "$dl"
        skip "this filesystem does not make sparse files"
    fi
    run stage "$(tree)"$'\n'"$(fakerun)"$'\n'"$(picked)"'
        local_dl_dir="'"$dl"'"
        tui_dl_enqueue
        TUI_DLEXP[1]=1048576
        tui_dl_progress
        echo "${TUI_STATUS[1]}"'
    rm -rf "$dl"
    # 4 KiB of 1 MiB is 0%, not the 99% the apparent size would have claimed.
    [ "${lines[0]}" = "0%" ]
}

@test "a sparse part-download is not mistaken for a complete one" {
    # The other half of the chunked-download problem: an interrupted pget -n
    # leaves a file whose apparent size is already the full figure, so comparing
    # that against the remote size called it complete -- and "t" would then hide
    # it. What is allocated decides.
    dl=$(mktemp -d)
    dd if=/dev/zero of="$dl/notes.nfo" bs=4096 count=1 seek=255 > /dev/null 2>&1
    if (( $(du -s --block-size=1 "$dl/notes.nfo" | cut -f1) >= \
          $(du -sb "$dl/notes.nfo" | cut -f1) )); then
        rm -rf "$dl"
        skip "this filesystem does not make sparse files"
    fi
    lf=$(mktemp); lf2=$(mktemp); lf5=$(mktemp)
    printf '%s\n' 'notes.nfo   1.0M  2026-08-23 14:42' > "$lf"
    printf '%s\n' 'notes.nfo' > "$lf2"
    printf '%s\n' '     1.0M 2026-08-23 14:42 notes.nfo' > "$lf5"
    run stage 'exec {TUI_OUT}>/dev/null
               listfile="'"$lf"'"; listfile2="'"$lf2"'"; listfile5="'"$lf5"'"
               local_dl_dir="'"$dl"'"
               tui_load; tui_status_scan; echo "sparse=${TUI_LSTAT[0]}"
               head -c 1048576 /dev/zero > "'"$dl"'/notes.nfo"
               tui_status_scan; echo "solid=${TUI_LSTAT[0]}"'
    rm -rf "$dl" "$lf" "$lf2" "$lf5"
    [ "${lines[0]}" = "sparse=i" ]
    # ... and a file that really is there is still complete.
    [ "${lines[1]}" = "solid=c" ]
}

@test "the status bar is the second line from the bottom, messages below it" {
    out=$(mktemp)
    run stage "$(tree)"'
        exec {TUI_OUT}>"'"$out"'"
        TUI_LINES=12; TUI_COLS=70; tui_rows_calc
        tui_msg="something happened"
        tui_draw'
    mapfile -t screen < "$out"
    rm -f "$out"
    # One line per row of the terminal: header, TUI_ROWS of list, bar, message.
    [ "${#screen[@]}" -eq 12 ]
    # The top line is the column header, not the bar.
    [[ "${screen[0]}" == *"NAME"* ]]
    [[ "${screen[0]}" == *"SIZE"* ]]
    [[ "${screen[0]}" != *"selected"* ]]
    # The bar is second from the bottom ...
    [[ "${screen[10]}" == *"alftp"* ]]
    [[ "${screen[10]}" == *"0 selected"* ]]
    # ... and the message is the last line, below it.
    [[ "${screen[11]}" == *"something happened"* ]]
}

@test "a prompt replaces the message line and leaves the bar alone" {
    out=$(mktemp)
    run stage "$(tree)"'
        exec {TUI_OUT}>"'"$out"'"
        TUI_LINES=12; TUI_COLS=70; tui_rows_calc
        tui_prompt="really? (Y/n)"
        tui_draw'
    mapfile -t screen < "$out"
    rm -f "$out"
    [ "${#screen[@]}" -eq 12 ]
    [[ "${screen[10]}" == *"0 selected"* ]]
    [[ "${screen[11]}" == *"really? (Y/n)"* ]]
}

@test "quitting only offers to save when saving would do something" {
    # Nothing marked: there is nothing to save and nothing to abandon, so the
    # three-way dialog has no question in it. "q" confirms.
    run stage "$(tree)"$'\n'"$(keys)"'
        KEYS=(q); tui_quit_prompt
        echo "simple=$tui_quit_simple answer=$tui_answer"'
    [ "$output" = "simple=1 answer=save" ]

    # Something marked and not downloaded: the choice is real again, and "q"
    # keeps its old meaning of leaving without downloading.
    run stage "$(tree)"$'\n'"$(keys)"'
        tui_cur=0; tui_toggle
        KEYS=(q); tui_quit_prompt
        echo "simple=$tui_quit_simple answer=$tui_answer"'
    [ "$output" = "simple=0 answer=exit" ]
}

@test "confirm_quit=False quits without asking when there is nothing to ask" {
    # No keys at all: reaching tui_read_key would end the loop with "exit", so
    # an answer of "save" is proof that nothing was read.
    run stage "$(tree)"$'\n'"$(keys)"'
        confirm_quit=False
        KEYS=(); tui_quit_prompt
        echo "answer=$tui_answer prompt=[$tui_prompt] simple=$tui_quit_simple"'
    [ "$output" = "answer=save prompt=[] simple=1" ]
}

# The dangerous direction, and the one the option deliberately does not cover:
# with something still to carry out, quitting throws it away and still asks.
@test "confirm_quit=False still asks when there is something to lose" {
    run stage "$(tree)"$'\n'"$(keys)"'
        confirm_quit=False
        tui_cur=0; tui_toggle
        KEYS=(q); tui_quit_prompt
        echo "answer=$tui_answer simple=$tui_quit_simple"'
    [ "$output" = "answer=exit simple=0" ]

    # An unlink or a delete is something to carry out as much as a download is.
    run stage "$(tree)"$'\n'"$(keys)"'
        confirm_quit=False
        tui_cur=0; tui_mark_remove
        KEYS=(c); tui_quit_prompt
        echo "answer=$tui_answer simple=$tui_quit_simple"'
    [ "$output" = "answer=cancel simple=0" ]
}

# A transfer that is still going keeps its node marked and unfinished, so
# tui_pending is true and the question -- which says what will be stopped --
# is asked whatever confirm_quit says.
@test "confirm_quit=False still asks with a transfer in flight" {
    run stage "$(tree)"$'\n'"$(keys)"$'\n'"$(fakerun)"$'\n'"$(picked)"'
        confirm_quit=False
        tui_dl_enqueue
        tui_dl_busy && echo busy || echo idle
        KEYS=(c); tui_quit_prompt
        echo "answer=$tui_answer simple=$tui_quit_simple"'
    [ "${lines[0]}" = "busy" ]
    [ "${lines[1]}" = "answer=cancel simple=0" ]
}

@test "confirm_quit is only turned off by a plain False" {
    # tui_select validates it the way it validates every other picker setting:
    # a typo leaves the confirmation on rather than quietly taking it away.
    run stage 'confirm_quit=no
        listfile=$(mktemp); listfile2=$(mktemp); tui_dev_tty=0
        tui_select > /dev/null 2>&1 || true
        echo "$confirm_quit"'
    [ "$output" = "True" ]
}

@test "an entry already downloaded does not count as something to save" {
    run stage "$(tree)"$'\n'"$(fakerun)"$'\n'"$(picked)"'
        tui_dl_enqueue
        tui_pending && echo "pending-before" || echo "nothing-before"
        # Mark every queued transfer finished, the way tui_dl_reap would.
        for (( j = 0; j < tui_dl_n; j++ )); do
            TUI_DLSTATE[j]=done; TUI_STATUS[${TUI_DLID[j]}]=done
        done
        tui_pending && echo "pending-after" || echo "nothing-after"'
    # Marked and unfinished is something to save; marked and finished is not.
    [ "${lines[0]}" = "pending-before" ]
    [ "${lines[1]}" = "nothing-after" ]
}

@test "an empty listing still opens, and its keys do nothing rather than break" {
    listfile=$(mktemp); listfile2=$(mktemp)
    : > "$listfile"; : > "$listfile2"
    run stage 'exec {TUI_OUT}>/dev/null
        listfile="'"$listfile"'"; listfile2="'"$listfile2"'"; listfile5=""
        tui_load
        TUI_LINES=10; TUI_COLS=60; tui_rows_calc; remote_dl_dir=/remote
        KI=0
        tui_read_key () {
            if (( KI >= ${#KEYS[@]} )); then return 1; fi
            TUI_KEY=${KEYS[KI]}; KI=$(( KI + 1 )); return 0
        }
        printf -v TAB "\t"
        # Every key that wants the entry under the cursor, with no cursor.
        KEYS=(j k " " "$TAB" d x r G 0 q q); tui_loop
        echo "N=$TUI_N cur=$tui_cur result=$tui_result"'
    rm -f "$listfile" "$listfile2"
    [ "$status" -eq 0 ]
    # It ran to the quit rather than falling over on an empty array.
    [ "$output" = "N=0 cur=0 result=save" ]
}

@test "an = entry is post-processed but not transferred again" {
    listfile=$(mktemp); listfile2=$(mktemp)
    printf '%s\n' '=Rel.One-GRP@          4.1G  2026-08-23 17:10' \
                  '+notes.nfo             2.1K  2026-08-22 09:03' > "$listfile"
    printf '%s\n' 'Rel.One-GRP/' 'notes.nfo' > "$listfile2"
    run stage 'listfile="'"$listfile"'"; listfile2="'"$listfile2"'"; TYPE
               echo "D=[$LINESD]"; echo "F=[$LINESF]"
               echo "O=[$(printf "%s" "$LINESO" | tr "\t" "|")]"'
    rm -f "$listfile" "$listfile2"
    # POST_PROCESS walks LINESD/LINESF, so the finished entry has to be there:
    # that is what unrars it, sets its permissions and records it.
    [ "${lines[0]}" = "D=[Rel.One-GRP]" ]
    [ "${lines[1]}" = "F=[notes.nfo]" ]
    # LINESO is what emits transfers, and it has only the entry still wanted.
    [ "${lines[2]}" = "O=[file|notes.nfo]" ]
}

@test "nothing left to transfer emits nothing, but a hand-filled list still works" {
    # TYPE ran and found nothing to fetch: emitting from LINESD would fetch
    # everything a second time.
    run stage 'LINESO_BUILT=1; LINESO=""; LINESD="Rel.One-GRP"; LINESF="notes.nfo"
               local_dl_dir=/dl; DLXFER; echo "[end]"'
    [ "$output" = "[end]" ]
    # TYPE never ran, so LINESD/LINESF are all there is -- POST_PROCESS and
    # several tests rely on this.
    run stage 'LINESO=""; LINESD=""; LINESF="notes.nfo"
               local_dl_dir=/dl; DLXFER'
    [[ "$output" == *'pget -c -n 5 "notes.nfo"'* ]]
}

@test "-c does not carry a finished transfer into the next run" {
    old=$(mktemp)
    printf '%s\n' '=Rel.One-GRP@   4.1G  2026-08-23 17:10' \
                  '+notes.nfo      2.1K  2026-08-22 09:03' \
                  '-Rel.Two-GRP@   2.7G  2026-08-22 09:03' > "$old"
    run stage 'marked_entries "'"$old"'"'
    rm -f "$old"
    # The "=" was this tool's own bookkeeping, not a mark the user made;
    # carrying it over would post-process the same download twice.
    [ "${#lines[@]}" -eq 2 ]
    [[ "$output" != *"Rel.One-GRP"* ]]
    [[ "$output" == *"notes.nfo"* ]]
    [[ "$output" == *"Rel.Two-GRP"* ]]
}
