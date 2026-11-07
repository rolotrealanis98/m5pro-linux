Thanks for the T6050 CIO reset. I had a smaller version of it for the J716s (M5 Pro 16-inch): the same register at +0x60 of the PMGR page and the t8142 bit layout, but it read the odd bit as busy (write the request, then wait for that bit to clear). Your sequence (done flag, then wait for request and done to clear before the CPU wrapper is touched) explains why mine could return early, so I'm dropping mine in favour of this one.

What I can say from the J716s: we have been booting it on integration/aurora with cio_reconfig0 enabled and bound through a t6050 match (my version), with no problems at probe. Nothing ever deasserted a reset, though. No consumer is enabled on the J716s, so that tells you nothing about the sequence itself.

Two questions:

1. Do you want a Tested-by from the J716s? I can boot it with your reset-apple-cio.c change and cio_reconfig0 enabled and confirm it probes, but without a consumer I can't run a reconfig request, so it would only cover probe. If you'd rather wait until the J716s right port (ATC2) is wired up like the J716c's, I'll test then.

2. Is usb4_3_acio in t6050-die0.dtsi (cio@389ac0000, resets = <&cio_reconfig0 3>) expected to work on T6050? Your router is named acio@ because the boot loader disables a cio@ node whose first register isn't the ADT one, so I'm not sure whether usb4_3_acio is a placeholder that should be renamed the same way or dropped. On the J716s it doesn't matter (the ADT has no usb-drd3, so we disable ATC3), but I'd like to know which way the shared dtsi is going.
