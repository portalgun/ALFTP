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
``` 
$ alftp -i docs
``` 
to download individual files, or
``` 
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
