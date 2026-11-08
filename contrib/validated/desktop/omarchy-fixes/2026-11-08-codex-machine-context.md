# Shared machine context and reporting for Codex (2026-11-08)

Tracker: https://github.com/rolotrealanis98/m4-m5-linux/issues/39
Kernel: `7.3.0-g36845aa5f650` (observed; no payload or hardware status claim)

## What broke

Codex discovered generic Omarchy skills but had no global machine instructions or m5pro skill. Claude already had a global instruction block and the machine-specific skill and brief. The missing routing meant Codex did not automatically know the J716s constraints or reporting workflow.

## Cause

The existing local-agent installer configured Claude only. Codex user instruction and skill discovery locations lacked this setup. Both clones were clean and up to date before changes. The Studio busy marker was absent.

## Fix

Added a Codex global instruction template and a narrow installer in `contrib/validated/desktop/local-agent/`. Ran:

```sh
python3 contrib/validated/desktop/local-agent/install-codex-agent.py --dry-run
python3 contrib/validated/desktop/local-agent/install-codex-agent.py
```

The installer writes a marked block into `~/.codex/AGENTS.md` and links `m5pro` from both user skill directories directly to the repository-owned local-agent directory. No package installation, system configuration or hardware changes. Global instructions require machine work and diagnostic findings to be documented here, with issues and evidence in the public tracker; feature status updates still require actual testing.

## Files changed

The exact new template and installer are committed alongside this report:

- `contrib/validated/desktop/local-agent/CODEX-AGENTS.md`: complete installed global instruction block.
- `contrib/validated/desktop/local-agent/install-codex-agent.py`: complete installer, including backup and conflict refusal behavior.
- `contrib/validated/desktop/local-agent/README.md`: installation, refresh, session-loading and rollback instructions.
- `contrib/validated/desktop/local-agent/SKILL.md`: changed the brief lookup to resolve the sibling file, allowing both agent families to use the same source:

```diff
-Read `~/.claude/skills/m5pro/BRIEF.md` in full (it sits next to this file). Its **HARD RULES** and "One owner at a time"
+Read `BRIEF.md` in full from the same directory as this skill (resolve the skill symlink to find it). Its **HARD RULES** and "One owner at a time"
```

Installed user files (new; none existed at these paths):

- `~/.codex/AGENTS.md`: content from `CODEX-AGENTS.md`.
- `~/.agents/skills/m5pro` and `~/.codex/skills/m5pro`: symlinks to `~/Work/m5pro-linux/contrib/validated/desktop/local-agent/`.

The existing Claude installation and machine brief were left intact. Its installed skill/brief matched the repository before this change; future Claude installer runs receive the portable brief lookup too.

## Verified

- Dry run completed before installation.
- Isolated temporary-home checks passed: preserves unrelated instructions, repeat installation produces one marked block, creates backup of prior instructions, resolves the linked brief, refuses unbalanced markers.
- Skill frontmatter validation passed.
- Real user installation succeeded.
- Codex delivered the installed global instruction block into the active conversation after installation, demonstrating instruction loading in this session.
- Separate fresh-session loading and future agent compliance were not independently tested. No hardware feature state changed; the status matrix was not edited.

## Rollback

Remove only these skill symlinks:

```sh
unlink ~/.agents/skills/m5pro
unlink ~/.codex/skills/m5pro
```

Remove the block between `<!-- BEGIN m5pro-codex-local-agent -->` and `<!-- END m5pro-codex-local-agent -->` from `~/.codex/AGENTS.md`, preserving any other instructions. If it contains only this block, remove that file. For existing installations the installer preserves the original as `AGENTS.md.pre-m5pro`; this installation created a new file. Repository changes can be reverted with a normal revert commit after checking for subsequent edits.
