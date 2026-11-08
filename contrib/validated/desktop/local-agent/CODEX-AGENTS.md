<!-- BEGIN m5pro-codex-local-agent -->
# This machine: J716s M5 Pro Linux

This machine is Rolando's MacBook Pro 16-inch M5 Pro (J716s), running Omarchy on Arch Linux ARM with a custom boot chain. These instructions apply to every Codex session on this machine, regardless of working directory, and to any delegated agents.

Before any machine work, read `~/Work/m5pro-linux/contrib/validated/desktop/local-agent/BRIEF.md` in full and follow its HARD RULES and ownership coordination. Use the `m5pro` skill at `~/.agents/skills/m5pro/SKILL.md` alongside `omarchy` for desktop/config tasks and `diagnose-crash` for crashes. The brief and skill in the repository are the shared source for Claude and Codex; do not rely on stock Omarchy assumptions or stale machine facts. Verify the running kernel and relevant live state. If the brief cannot be read, stop machine changes and report the missing context.

Protect the custom boot chain, kernel, firmware, GPU/session plumbing, speaker safety chain, watchdog and package guards. The brief lists the exact protected paths and actions requiring Rolando's explicit approval. Do not reboot, disrupt the session/network, upgrade the system or test speakers without following those rules. Check the Studio busy marker as directed. For crashes, check the known GPU recovery signature before blaming configuration.

## Required reporting for work on this machine

All machine work, including configuration, applications, diagnostics, fixes, regressions and agent setup, must be recorded in `~/Work/m5pro-linux` (https://github.com/rolotrealanis98/m5pro-linux). Follow the brief's write-up format: symptom, evidence/cause, commands and exact file changes, verification, unverified items and rollback. Record meaningful diagnostic findings and unsuccessful attempts too; do not describe untested work as validated.

Use `~/Work/m4-m5-linux` (https://github.com/rolotrealanis98/m4-m5-linux) as the public contributor tracker. Search existing issues first; update a matching issue or create one for a new fix/bug, use the machine and workflow labels, and link the m5pro-linux commit permalink. Update feature results and the status matrix only when a feature was actually tested and its status changed; follow CONTRIBUTING.md and run the required checks.

Follow the brief's privacy scan, commit identity, no-trailer convention, pull/rebase, commit and push workflow for both repos. Stage only this task's files and preserve others' work. No force pushes. Report conflicts or unavailable publishing access clearly, retaining the local report and stating what remains unpublished. Do not publish to other repositories or contact upstream contributors unless Rolando explicitly asks. Pass these instructions and the shared brief path to any delegated agent.
<!-- END m5pro-codex-local-agent -->
