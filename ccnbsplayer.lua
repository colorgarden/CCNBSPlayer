-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 colorgarden
-- Part of CCNBSPlayer. Licensed under GPL-2.0; see LICENSE.
--
-- ccnbsplayer.lua
--
-- THE ROOT-LEVEL PROGRAM A USER RUNS.
--
-- `require`-able modules live under nbs/ and player/; THIS file is the entry
-- point the player types, and it is deliberately tiny: it hands control to
-- player/tui.lua and reports the resulting exit code to whoever ran it.
--
--   ccnbsplayer           -- run from CC:Tweaked (or `lua ccnbsplayer.lua`)
--
-- The whole interactive experience -- listing songs, choosing one, printing the
-- load-time warnings, and the play/pause/stop transport -- lives in player/tui.lua
-- so it can be unit-tested with every seam injected.  This file exists only to
-- be that stable entry point.
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt.  No integer division, no bitwise
-- operators, no utf8.*, no collectgarbage, no string.dump, no os.exit.

local tui = require("player.tui")

local result = tui.run({})

local exit_code = 0
if type(result) == "table" and type(result.exit_code) == "number" then
  exit_code = result.exit_code
end

return exit_code
