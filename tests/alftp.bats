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

@test "tui_load starts everything deselected and drops the comment markers" {
    listfile=$(mktemp)
    printf '%s\n' 'file1  4.0K  2026-08-23 17:10' '#file2   753  2026-08-23 14:42' '' \
                  'dir1/   24K  2026-08-22 09:03' > "$listfile"
    run stage 'listfile="'"$listfile"'"; tui_load
               echo "$TUI_N ${TUI_SEL[*]} [${TUI_RAW[1]}]"'
    rm -f "$listfile"
    [ "$output" = "3 0 0 0 [file2   753  2026-08-23 14:42]" ]
}

@test "tui_save comments out everything that was not selected" {
    listfile=$(mktemp)
    printf '%s\n' 'file1  4.0K  2026-08-23 17:10' 'file2   753  2026-08-23 14:42' > "$listfile"
    run stage 'listfile="'"$listfile"'"; tui_load; TUI_SEL[1]=1; tui_save; cat "$listfile"'
    rm -f "$listfile"
    [ "${lines[0]}" = "#file1  4.0K  2026-08-23 17:10" ]
    [ "${lines[1]}" = "file2   753  2026-08-23 14:42" ]
}

@test "tui_widths measures the columns for the header" {
    listfile=$(mktemp)
    printf '%s\n' 'a.file.with.a.long.name  4.0K  2026-08-23 17:10' \
                  '#dir/                          2026-08-22 09:03' > "$listfile"
    run stage 'listfile="'"$listfile"'"; tui_widths; echo "$tui_namew $tui_sizew"'
    rm -f "$listfile"
    [ "$output" = "23 4" ]
}

@test "tui_key_action maps letters and escape sequences to the same actions" {
    run stage 'for k in j "$(printf "\e[B")" k "$(printf "\e[A")" 0 "$(printf "\e[1~")" \
                        G "$(printf "\e[F")" "$(printf "\e[5~")" "$(printf "\e[6~")" \
                        " " "$(printf "\r")" a A q "$(printf "\e")" x; do
                   tui_key_action "$k"; printf "%s " "$tui_action"
               done'
    [ "$output" = "down down up up top top bottom bottom pgup pgdn toggle toggle all none quit quit ignore " ]
}

@test "tui_move clamps at both ends and scrolls to keep the cursor visible" {
    run stage 'TUI_N=20; TUI_ROWS=5; tui_cur=0; tui_top=0
               tui_action=up; tui_move; printf "%s/%s " "$tui_cur" "$tui_top"
               for i in 1 2 3 4 5 6; do tui_action=down; tui_move; done
               printf "%s/%s " "$tui_cur" "$tui_top"
               tui_action=pgdn; tui_move; printf "%s/%s " "$tui_cur" "$tui_top"
               tui_action=pgup; tui_move; printf "%s/%s " "$tui_cur" "$tui_top"
               tui_action=bottom; tui_move; printf "%s/%s " "$tui_cur" "$tui_top"
               tui_action=down; tui_move; printf "%s/%s " "$tui_cur" "$tui_top"
               tui_action=top; tui_move; printf "%s/%s" "$tui_cur" "$tui_top"'
    [ "$output" = "0/0 6/2 11/7 6/6 19/15 19/15 0/0" ]
}

@test "tui_move never scrolls a list that fits on the screen" {
    run stage 'TUI_N=3; TUI_ROWS=5; tui_cur=0; tui_top=0
               tui_action=bottom; tui_move; echo "$tui_cur/$tui_top"'
    [ "$output" = "2/0" ]
}

# The event loop, driven by a scripted key source instead of a terminal: the
# draw goes to /dev/null and tui_read_key pops a key off an array.
keys () {
    cat <<'SNIP'
    exec {TUI_OUT}>/dev/null
    TUI_RAW=(one two three four five); TUI_N=5
    TUI_LINES=10; TUI_COLS=40; TUI_ROWS=5; remote_dl_dir=/remote
    tui_cur=0; tui_top=0; tui_nsel=0; tui_prompt=""; tui_resized=0
    TUI_SEL=(0 0 0 0 0); KI=0
    tui_read_key () {
        if (( KI >= ${#KEYS[@]} )); then return 1; fi
        TUI_KEY=${KEYS[KI]}; KI=$(( KI + 1 )); return 0
    }
SNIP
}

@test "space and enter toggle the item under the cursor, q then s saves" {
    run stage "$(keys)"'
               printf -v NL "\n"
               KEYS=(" " j "$NL" q s); tui_loop
               echo "${TUI_SEL[*]} $tui_nsel $tui_result"'
    [ "$output" = "1 1 0 0 0 2 save" ]
}

@test "a selects everything and A clears it again" {
    run stage "$(keys)"'
               KEYS=(a q s); tui_loop; echo "${TUI_SEL[*]} $tui_nsel"
               KI=0; KEYS=(a A q s); tui_loop; echo "${TUI_SEL[*]} $tui_nsel"'
    [ "${lines[0]}" = "1 1 1 1 1 5" ]
    [ "${lines[1]}" = "0 0 0 0 0 0" ]
}

@test "the quit dialog cancels back to the list, saves, or exits" {
    run stage "$(keys)"'
               KEYS=(" " q c j " " q s); tui_loop
               echo "cancel-then-save: ${TUI_SEL[*]} $tui_result"'
    [ "$output" = "cancel-then-save: 1 1 0 0 0 save" ]
    run stage "$(keys)"'
               KEYS=(" " q e); tui_loop; echo "exit: $tui_result"'
    [ "$output" = "exit: exit" ]
}

@test "G jumps to the last item and the arrow keys move too" {
    run stage "$(keys)"'
               KEYS=(G " " q s); tui_loop; echo "${TUI_SEL[*]}"
               KI=0; TUI_SEL=(0 0 0 0 0); tui_cur=0; tui_top=0; tui_nsel=0
               KEYS=("$(printf "\e[B")" "$(printf "\e[B")" " " q s); tui_loop; echo "${TUI_SEL[*]}"'
    [ "${lines[0]}" = "0 0 0 0 1" ]
    [ "${lines[1]}" = "0 0 1 0 0" ]
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
