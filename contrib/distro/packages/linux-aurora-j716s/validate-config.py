#!/usr/bin/env python3
"""Reject requested capabilities that Kconfig silently dropped.

Same check as omarchy-pkgs linux-aurora/validate-config.py, over a stack of fragments: later fragments override earlier
ones (asahi.config sets HID_APPLE_MTP_HAPTIC=m, j716s.config makes it =y), so only the last word on a symbol is checked.
usage: validate-config.py RESOLVED_CONFIG FRAGMENT...
"""
from pathlib import Path
import sys


def values(path):
    result = {}
    for line in Path(path).read_text().splitlines():
        if line.startswith('CONFIG_') and '=' in line:
            key, value = line.split('=', 1)
            result[key] = value
        elif line.startswith('# CONFIG_') and line.endswith(' is not set'):
            result[line.split()[1]] = 'n'
    return result


def validate(resolved, fragments):
    wanted = {}
    for fragment in fragments:
        wanted.update(values(fragment))
    actual = values(resolved)
    missing = [f'{name}: wanted {value}, got {actual.get(name, "absent")}'
               for name, value in wanted.items() if actual.get(name, 'n') != value]
    if missing:
        raise ValueError('Kernel capabilities disabled by Kconfig:\n' + '\n'.join(missing))


if __name__ == '__main__':
    try:
        validate(sys.argv[1], sys.argv[2:])
    except (ValueError, OSError, IndexError) as error:
        sys.exit(str(error))
