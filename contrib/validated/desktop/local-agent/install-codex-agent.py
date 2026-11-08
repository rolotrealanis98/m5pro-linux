#!/usr/bin/env python3
"""Install shared J716s instructions for Codex; no packages or network operations."""
import argparse
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--home', type=Path, default=Path.home(), help='Target home (also useful for isolated verification)')
parser.add_argument('--dry-run', action='store_true')
args = parser.parse_args()
source = Path(__file__).resolve().parent
home = args.home.expanduser().resolve()
block = (source / 'CODEX-AGENTS.md').read_text().strip()
begin = '<!-- BEGIN m5pro-codex-local-agent -->'
end = '<!-- END m5pro-codex-local-agent -->'
target = home / '.codex/AGENTS.md'
if target.is_symlink():
    raise SystemExit(f'Refusing instruction symlink: {target}')
old = target.read_text() if target.exists() else ''
if old.count(begin) != old.count(end) or old.count(begin) > 1:
    raise SystemExit('Unbalanced or duplicate Codex instruction markers')
if begin in old:
    start = old.index(begin)
    stop = old.index(end) + len(end)
    if stop < start:
        raise SystemExit('Codex instruction markers are out of order')
    new = old[:start] + block + old[stop:]
else:
    new = old.rstrip() + ('\n\n' if old.strip() else '') + block + '\n'
links = [home / '.agents/skills/m5pro', home / '.codex/skills/m5pro']
for link in links:
    if link.is_symlink():
        if link.resolve() != source:
            raise SystemExit(f'Refusing unrelated skill symlink: {link}')
    elif link.exists():
        raise SystemExit(f'Refusing existing skill directory: {link}')
if args.dry_run:
    print(f'Would update {target} and link the shared skill into both user skill directories')
else:
    target.parent.mkdir(parents=True, exist_ok=True)
    if old != new:
        backup = target.with_name('AGENTS.md.pre-m5pro')
        if target.exists() and not backup.exists():
            backup.write_text(old)
        target.write_text(new)
    for link in links:
        link.parent.mkdir(parents=True, exist_ok=True)
        if not link.is_symlink():
            link.symlink_to(source, target_is_directory=True)
    print(f'Installed {target}; shared m5pro skill: {source}')
