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
    [[ "$output" == *'cls -1 > "/tmp/alftp-test-list"'* ]]
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
    printf '%s\n' 'file1  4.0K  2026-08-23 17:10' 'file2   753  2026-08-23 14:42' > "$listfile"
    run stage 'listfile="'"$listfile"'"; ind_files=True; picker=editor
               editor="printf %s\n >> '"$log"' --"
               pick_list; cat "$listfile"'
    rm -f "$log"
    # -i hands the editor a fully commented list for the user to uncomment.
    [ "${lines[0]}" = "#file1  4.0K  2026-08-23 17:10" ]
    [ "${lines[1]}" = "#file2   753  2026-08-23 14:42" ]
    rm -f "$listfile"
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
    [ "${lines[0]}" = "[++++ +]" ]
    [ "${lines[1]}" = "2/1" ]
    [ "${lines[2]}" = "[     -]" ]
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
    printf '%s\n' '*Rel.One-GRP@          4.1G  2026-08-23 17:10' \
                  '+Rel.One-GRP/CD1/            2026-08-23 17:10' \
                  '+Rel.One-GRP/movie.mkv 4.0G  2026-08-23 17:10' \
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
    [ "${lines[0]}" = "[+ +   ]" ]
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
               UNRAR_FUN () { echo "unrar $1"; }
               LINESD="Rel.One-GRP"; POST_PROCESS'
    [ "$output" = "" ]
    run stage 'local_dl_dir="'"$dl"'"; record=""; errors=""; verify=""
               autoUncompress=True; UNRAR_FUN () { echo "unrar $1"; }
               LINESD="Rel.One-GRP"; POST_PROCESS'
    [ "$output" = "unrar $dl/Rel.One-GRP" ]
    # -nu turns it off again even where the config asked for it.
    run stage 'local_dl_dir="'"$dl"'"; record=""; errors=""; verify=""
               autoUncompress=True; nounrar=True; UNRAR_FUN () { echo "unrar $1"; }
               LINESD="Rel.One-GRP"; POST_PROCESS'
    [ "$output" = "" ]
    rm -rf "$dl"
}
