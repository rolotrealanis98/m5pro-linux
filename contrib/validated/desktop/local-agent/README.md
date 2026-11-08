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

## Codex on the same machine

Codex uses the same repository-owned `SKILL.md` and `BRIEF.md` as Claude. Install its global instructions and user skill links with:

```sh
python3 contrib/validated/desktop/local-agent/install-codex-agent.py --dry-run
python3 contrib/validated/desktop/local-agent/install-codex-agent.py
```

This maintains a marked block from `CODEX-AGENTS.md` in `~/.codex/AGENTS.md`, preserves unrelated instructions, and links `m5pro` in both `~/.agents/skills/` and `~/.codex/skills/` directly to this directory. Existing unrelated skill directories are never replaced. Re-run after changes to the global instruction template; changes to the shared skill and brief are available through the links immediately. Start a fresh Codex session to load global instructions. Already running sessions must be told to read them explicitly.

The global instructions require reporting all machine work, including agent setup and diagnostic findings, to m5pro-linux and the contributor tracker following the brief. Installing this setup does not change any hardware feature state. To remove it, remove the two `m5pro` symlinks and only the marked `m5pro-codex-local-agent` block from `~/.codex/AGENTS.md`; retain unrelated instructions.
