--!strict
-- Boots the leaderboard logic that lives on this folder. Kept tiny on purpose:
-- all the behaviour is in the sibling LeaderboardService ModuleScript.
local Leaderboard = require(script.Parent:WaitForChild("LeaderboardService"))
Leaderboard.start(script.Parent)
