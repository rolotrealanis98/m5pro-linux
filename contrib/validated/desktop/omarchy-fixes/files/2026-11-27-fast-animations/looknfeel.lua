-- Change the default Omarchy look'n'feel.

-- Opt another application in to Omarchy's standard transparency.
-- Find its class with: hyprctl clients
-- o.transparent_window("my-app")
-- o.transparent_window("my-app", "0.9 0.85") -- Custom active/inactive opacity.

-- https://wiki.hypr.land/Configuring/Basics/Variables/#general
-- hl.config({
--   general = {
--     -- No gaps between windows or borders.
--     gaps_in = 0,
--     gaps_out = 0,
--     border_size = 0,
--
--     -- Change to niri-like side-scrolling layout.
--     layout = "scrolling",
--   },
-- })

-- https://wiki.hypr.land/Configuring/Basics/Variables/#decoration
-- hl.config({
--   decoration = {
--     -- Use round window corners.
--     rounding = 8,
--
--     -- Dim unfocused windows (0.0 = no dim, 1.0 = fully dimmed).
--     dim_inactive = true,
--     dim_strength = 0.15,
--   },
-- })

-- https://wiki.hypr.land/Configuring/Basics/Variables/#animations
-- hl.config({
--   animations = {
--     -- Disable all animations.
--     enabled = false,
--   },
-- })

-- https://wiki.hypr.land/Configuring/Basics/Variables/#layout
-- hl.config({
--   layout = {
--     -- Avoid overly wide single-window layouts on wide screens.
--     single_window_aspect_ratio = { 1, 1 },
--   },
-- })

-- https://wiki.hypr.land/Configuring/Layouts/Scrolling-Layout/
-- hl.config({
--   scrolling = {
--     -- See only one column per screen instead of two.
--     column_width = 0.97,
--   },
-- })

-- Mission Control draws its own open and close animation.
hl.layer_rule({ match = { namespace = "^mission-control(-bar)?$" }, no_anim = true, animation = "none" })

-- Workspaces slide (Omarchy switches them instantly). Without this a workspace
-- swipe follows the fingers and then jumps the rest of the way on release.
-- Remove the line to get the instant switch back.
hl.animation({ leaf = "workspaces", enabled = true, speed = 1.5, bezier = "easeOutQuint", style = "slide" })

-- Faster motion than Omarchy's defaults (speed is in tenths of a second).
hl.animation({ leaf = "windows", enabled = true, speed = 2.5, bezier = "easeOutQuint" })
hl.animation({ leaf = "windowsIn", enabled = true, speed = 2.5, bezier = "easeOutQuint", style = "popin 87%" })
hl.animation({ leaf = "layersIn", enabled = true, speed = 2, bezier = "easeOutQuint", style = "fade" })
hl.animation({ leaf = "fadeLayersIn", enabled = true, speed = 1.5, bezier = "almostLinear" })
hl.animation({ leaf = "specialWorkspaceIn", enabled = true, speed = 2, bezier = "easeOutQuint", style = "slide top" })
hl.animation({ leaf = "specialWorkspaceOut", enabled = true, speed = 1.5, bezier = "easeInOutCubic", style = "slide bottom" })
hl.animation({ leaf = "border", enabled = true, speed = 3, bezier = "easeOutQuint" })
