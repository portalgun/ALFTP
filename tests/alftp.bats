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

@test "space and enter toggle the entry under the cursor, q then s saves" {
    run stage "$(tree)"$'\n'"$(keys)"'
        printf -v NL "\n"
        KEYS=(" " j "$NL" q s); tui_loop
        marks; echo "$tui_nsel $tui_result"'
    [ "${lines[0]}" = "[* ++  ]" ]
    [ "${lines[1]}" = "2 save" ]
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
    [ "${lines[1]}" = "0 exit" ]
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
        KEYS=(" " r); tui_loop; marks; echo "$tui_nsel"
        KI=0; KEYS=(j j " " k k r); tui_loop; marks; echo "$tui_nsel"'
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
