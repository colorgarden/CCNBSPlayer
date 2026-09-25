-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 colorgarden
-- Part of CCNBSPlayer. Licensed under GPL-2.0; see LICENSE.
--
-- ccnbsplayer.lua
--
-- THE ROOT-LEVEL PROGRAM A USER RUNS.
--
-- The hand-written terminal UI (the old player/tui.lua) has been RETIRED.  The
-- interactive experience is now the Basalt 2 screen in ui/basalt_app.lua, and
-- this file exists only to be the stable entry point that hands over to it and
-- reports the resulting exit code.
--
--   ccnbsplayer           -- run from CC:Tweaked (or `lua ccnbsplayer.lua`)
--
-- Basalt's run() blocks in its own event loop, so the whole screen -- the song
-- list, the detail/attribution panel, the transport and the progress bar --
-- lives in ui/basalt_app.lua, which is the ONLY view required here.
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt.  No integer division, no bitwise
-- operators, no utf8.*, no collectgarbage, no string.dump, no os.exit.

local app = require("ui.basalt_app")

local result = app.run({})

local exit_code = 0
if type(result) == "table" and type(result.exit_code) == "number" then
  exit_code = result.exit_code
end

return exit_code
