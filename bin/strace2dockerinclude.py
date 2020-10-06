#!/usr/bin/env python3


import fileinput
import re


reject_line_re = re.compile("^(--- SIG.*---|\+\+\+ killed by SIGKILL \+\+\+)$|<unfinished \.\.\.>")
split_re = re.compile("^(?P<syscall>[0-9a-zA-Z_]+)\((?P<args>.*)$")
stat_re = re.compile("stat$")
filename_1st_arg_re = re.compile('^"(?P<filename>[^"]*)"')
filename_2nd_arg_re = re.compile('^[^,]+,\s*"(?P<filename>[^"]+)"')
reject_filename_re = re.compile("^/(dev|sys|proc|tmp)|__pycache__")


def process(line):
    if reject_line_re.search(line) is not None:
        return None

    syscall, args = split_re.search(line).group("syscall", "args")

    if stat_re.search(syscall) is not None and "S_IFDIR" in args:
        return None

    filename = None
    if syscall in ("execve", "open", "access", "readlink", "stat", "lstat"):
        filename = filename_1st_arg_re.search(args).group("filename")
    elif syscall in ("openat",):
        filename = filename_2nd_arg_re.search(args).group("filename")
    elif syscall in ("getcwd", "mkdir", "statfs", "chown", "unlink", "rename", "chdir"):
        return None
    else:
        raise ValueError(f"unhandled syscall {syscall}")

    return filename if filename and reject_filename_re.search(filename) is None else None


filenames = set()
[filenames.add(process(line)) for line in fileinput.input()]
filenames.discard(None)
[print(f"f\t{fn}") for fn in sorted(filenames)]
