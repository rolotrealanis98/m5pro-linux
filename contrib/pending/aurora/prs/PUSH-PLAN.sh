#!/usr/bin/env bash
# Push plan for Rolando's first aurora-silicon/linux PRs (J716s). NOT RUN by the agent.
# Assumes the fork rolotrealanis98/linux exists and is the remote `fork` in /Volumes/linux-cs/linux:
#   git -C /Volumes/linux-cs/linux remote add fork https://github.com/rolotrealanis98/linux.git
# Branches are based on aurora integration/aurora 7aee01a89865. Re-check that tip first:
#   git -C /Volumes/linux-cs/linux fetch aurora integration/aurora
#   git -C /Volumes/linux-cs/linux log --oneline -1 refs/remotes/aurora/integration/aurora
# Each PR-<topic>.md: line 1 = title, line 3 onward = body (fed with tail -n +3).
set -euo pipefail
REPO=/Volumes/linux-cs/linux
DIR=$HOME/Work/agents/aurora-prs
GH="env GH_ACCOUNT=rolotrealanis98 gh"

send() {   # send <topic> <title>
	git -C "$REPO" push -u fork "pr/$1"
	$GH pr create -R aurora-silicon/linux --base integration/aurora \
		--head "rolotrealanis98:pr/$1" --title "$2" \
		--body-file <(tail -n +3 "$DIR/PR-$1.md")
}

# 1-3: standalone fixes, send now
send rtkit-handshake-10s           "soc: apple: rtkit: wait up to 10 s for a handshake reply"
send dockchannel-afe-settle        "HID: dockchannel-hid: settle 50 ms after releasing the AFE reset"
send macsmc-hwmon-optional-fan-keys "hwmon: (macsmc) keep a fan whose optional keys are missing"

# 4: HOLD. Superseded by #946 (35c0d1d6bc96, T6050 done-flag sequence). Prefer commenting on #946.
#    Delete the "[Note for Rolando ...]" block from PR-t6050-cio-reset.md before sending.
# send t6050-cio-reset             "reset: apple-cio: Add the T6050 reconfiguration register"

# 5: HOLD. Ask on #481 (t6050/cpufreq) first: single-const binding vs. T8112 fallback.
#    Delete the "[Note for Rolando ...]" block from PR-t6050-cpufreq-binding.md before sending.
# send t6050-cpufreq-binding       "dt-bindings: cpufreq: apple,cluster-cpufreq: Add T6050"

# 6: ONLY if #941 (j716c/t6050-smc) is far off. Delete the note block first.
# send t6050-smc-match             "mfd: macsmc: Match the T6050 SMC"

# 7: board PR, last. HOLD until REPORT.md "Before sending the board PR" is done
#    (fpwm binding, cpufreq route, dtbs_check).
# send j716s-board                 "arm64: dts: apple: Add J716s (MacBook Pro 16-inch, M5 Pro)"
