-- J716s (M5 Pro): Hyprland on simpledrm with Mesa llvmpipe (no GPU driver).
-- Install: ~/.config/hypr/m5-softrender.lua, then add
--   require("hypr.m5-softrender")
-- to ~/.config/hypr/hyprland.lua right after require("hypr.looknfeel").
--
-- Omarchy 4 already detects llvmpipe at session start
-- (omarchy-hyprland-software-rendering + default/hypr/software-rendering.lua)
-- and turns animations, blur and shadows off. This file states the same
-- explicitly, so the first frames are already light, and adds what Omarchy
-- does not know about this machine: simpledrm has no cursor plane, and the
-- boot framebuffer is a fixed 3456x2160 mode on a 16" Retina panel.

-- One output, the m1n1 framebuffer (simpledrm names it Unknown-1). Its single
-- mode is whatever iBoot set; scale 2 gives a 1728x1080 logical desktop.
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 2 })

hl.config({
  -- simpledrm exposes only a primary plane; draw the pointer in the frame.
  cursor = {
    no_hardware_cursors = true,
  },

  -- Render only when something changed (Hyprland's default, pinned here).
  misc = {
    vfr = true,
  },

  -- Every pixel is drawn by the CPU: nothing just for show.
  animations = {
    enabled = false,
  },

  decoration = {
    blur = {
      enabled = false,
    },
    shadow = {
      enabled = false,
    },
    dim_inactive = false,
  },
})
