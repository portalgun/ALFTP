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

When using the -i flag, a list of available files to download will be displayed as commented lines.
``` 
#file1
#file2
#directory1\
``` 
To download '''file1''' and '''directory1\''', simply uncomment them:
``` 
file1
directory1\
#file2
``` 

## DRY RUN
To see what a profile would transfer without downloading anything, add `--dry-run` (or `-dr`):
``` bash
$ alftp -a docs --dry-run
```
Directories are listed via `lftp mirror --dry-run`, files are printed rather than fetched, nothing
is removed from the remote, and no post-processing (unrar, permissions) runs.

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
