# Local agents on the J716s MacBook

Claude Code agents can run on the MacBook itself (Omarchy, user `rolo`) for small desktop fixes and for the AI crash diagnosis
Omarchy offers after a "Process crashed" notification, while the Studio session keeps the big items: boots and loop tests,
kernel, loader and firmware work, upstream pull requests, anything that touches the boot chain or the GPU session files. A local
agent is briefed automatically by `BRIEF.md` (what the machine is, the hard rules, the privacy rules, how results land) through the
`m5pro` skill (`SKILL.md`, which also carries the crash checklist: the known "GPU work of a client failed" class first) and a
marked block that `install-local-agent.sh` keeps in `~/.claude/CLAUDE.md` (the only thing that reaches the Omarchy crash prompt,
which cannot be extended); both sides land their results in the same two repos: fix write-ups under
`contrib/validated/desktop/omarchy-fixes/` in `rolotrealanis98/m5pro-linux`, and issues, result files and status cells in
`rolotrealanis98/m4-m5-linux`. Install or refresh with `sudo ./install-local-agent.sh` (as root or via sudo; `--dry-run` first), then
start a new Claude Code session on the machine.
