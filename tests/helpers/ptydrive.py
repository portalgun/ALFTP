#!/usr/bin/env python3
"""Drive a command under a pty and print what it painted.

The parts of the picker that need a real terminal -- tput, stty, the alternate
screen, the escape sequences real arrow keys send -- cannot be checked by
redefining tui_read_key, so the tests that care about them run the script here
instead and look at the bytes that came back.

    tests/helpers/ptydrive.py --keys 'jj \\x1b[B \\r' -- ./alftp -a TV

Keys are sent one whitespace-separated chunk at a time, with --delay seconds in
between, so the script has a moment to redraw. \\xNN, \\e, \\t, \\r and \\n are
understood; use \\s for a literal space. Output comes back with the escape
sequences stripped (--raw keeps them), and --screen prints only the last frame,
which is the one the user would have been looking at.
"""
import argparse
import os
import pty
import re
import select
import sys
import time

ESC = re.compile(rb'\x1b\[[0-9;?]*[A-Za-z]|\x1b[()][A-Z0-9]|\x1b[=>]|\x1b\][^\x07]*\x07|\x1b[78MND]|\r')


def decode_keys(spec):
    out = []
    for chunk in spec.split():
        chunk = chunk.replace('\\s', ' ')
        out.append(chunk.encode().decode('unicode_escape').encode('latin-1'))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--keys', default='')
    ap.add_argument('--delay', type=float, default=0.35)
    ap.add_argument('--timeout', type=float, default=25.0)
    ap.add_argument('--cols', type=int, default=80)
    ap.add_argument('--rows', type=int, default=24)
    ap.add_argument('--raw', action='store_true')
    ap.add_argument('--screen', action='store_true')
    ap.add_argument('cmd', nargs=argparse.REMAINDER)
    args = ap.parse_args()
    cmd = args.cmd[1:] if args.cmd and args.cmd[0] == '--' else args.cmd
    if not cmd:
        ap.error('no command given')

    pid, fd = pty.fork()
    if pid == 0:
        os.environ.setdefault('TERM', 'xterm-256color')
        os.environ['LINES'] = str(args.rows)
        os.environ['COLUMNS'] = str(args.cols)
        os.execvp(cmd[0], cmd)

    import fcntl, struct, termios
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', args.rows, args.cols, 0, 0))

    buf = bytearray()
    keys = decode_keys(args.keys)
    deadline = time.time() + args.timeout
    next_key = time.time() + args.delay

    def drain(until):
        while time.time() < until:
            r, _, _ = select.select([fd], [], [], 0.05)
            if not r:
                continue
            try:
                data = os.read(fd, 65536)
            except OSError:
                return False
            if not data:
                return False
            buf.extend(data)
        return True

    alive = True
    while alive and time.time() < deadline:
        if not drain(min(next_key, deadline)):
            alive = False
            break
        if keys:
            try:
                os.write(fd, keys.pop(0))
            except OSError:
                alive = False
                break
            next_key = time.time() + args.delay
        else:
            # Nothing left to send: read until the child goes away.
            if not drain(deadline):
                alive = False
            break
    try:
        os.close(fd)
    except OSError:
        pass
    try:
        _, status = os.waitpid(pid, 0)
        rc = os.waitstatus_to_exitcode(status)
    except (ChildProcessError, ValueError):
        rc = 0

    out = bytes(buf)
    if not args.raw:
        out = ESC.sub(b'', out)
    text = out.decode('utf-8', 'replace')
    if args.screen:
        lines = [ln for ln in text.split('\n')]
        text = '\n'.join(lines[-(args.rows + 1):])
    sys.stdout.write(text)
    sys.stdout.flush()
    return rc


if __name__ == '__main__':
    sys.exit(main())
