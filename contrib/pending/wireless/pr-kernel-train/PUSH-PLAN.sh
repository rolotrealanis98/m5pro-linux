#!/bin/sh
# Not run by the agent. Kernel repo /Volumes/linux-cs/linux, fork remote "fork" = rolotrealanis98/linux.
# Driver half: stacked on #937 (aurora-silicon j716c/t6050-pcie, a873be047e9a).
# git -C /Volumes/linux-cs/linux push fork n1-kernel-train
# gh pr create -R aurora-silicon/linux --base j716c/t6050-pcie --head rolotrealanis98:n1-kernel-train \
#   --title "$(head -1 PR-n1-kernel-train.md)" --body "$(tail -n +3 PR-n1-kernel-train.md)"
# DT half: on #1167 (rolotrealanis98:pr/j716s-board-v2, 674542cf2e22). Either add the two commits to #1167:
# git -C /Volumes/linux-cs/linux push fork n1-kernel-train-dt:pr/j716s-board-v2   (fast-forward of 674542cf2e22)
# or push n1-kernel-train-dt as its own branch and reference it from the PR.
