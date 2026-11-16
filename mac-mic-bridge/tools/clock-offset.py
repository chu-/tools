#!/usr/bin/env python3
"""Estimate remote wall clock minus local wall clock using SSH round trips."""
import shlex
import subprocess
import sys
import time

if len(sys.argv) != 2:
    raise SystemExit('Usage: python3 clock-offset.py <ssh-user>@<host>')

remote_code = 'import sys,time; print("ready",flush=True); [(print(time.time_ns(),flush=True)) for _ in sys.stdin]'
command = [
    'ssh', '-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5',
    '-o', 'ControlMaster=no', '-o', 'ControlPath=none', '--', sys.argv[1],
    'python3', '-u', '-c', shlex.quote(remote_code),
]
samples = []
with subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True) as process:
    if process.stdout.readline().strip() != 'ready':
        raise SystemExit('Could not start remote clock probe')
    for _ in range(10):
        start = time.time_ns()
        process.stdin.write('ping\n')
        process.stdin.flush()
        remote = int(process.stdout.readline().strip())
        end = time.time_ns()
        samples.append((end - start, remote - (start + end) // 2))
    process.stdin.close()
    if process.wait() != 0:
        raise SystemExit('Remote clock probe failed')
rtt, offset = min(samples)
print(f'Remote clock minus local clock: {offset / 1e6:+.2f} ms')
print(f'Uncertainty bound from the best round trip: ±{rtt / 2e6:.2f} ms')
print('For markers: corrected remote time = remote time - reported offset.')
