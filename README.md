# An strace-based Docker minimizer

[![CircleCI](https://circleci.com/gh/toknapp/strace-based-docker-minimizer.svg?style=svg&circle-token=04bda322f34125fa142c17814bc10b7baf7b50fb)](https://circleci.com/gh/toknapp/strace-based-docker-minimizer)

# How it works
This minimizer works in two phases:
1. collect which files are actually being used by the application by tracing all
   file-related syscalls using [strace](http://man7.org/linux/man-pages/man1/strace.1.html)
    * [strace-docker.sh](bin/strace-docker.sh)
2. squash layers and filter out unused files using the white-list created by the
   first phase.
    * [minimize.sh](bin/minimize.sh)
