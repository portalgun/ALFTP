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
