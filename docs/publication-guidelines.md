# Publication guidelines

These rules apply to everything this project publishes: the README, the CHANGELOG, GitHub release notes, the Steam Workshop page and its images, the docs in the public repository, and the comments in the published mods. The script that builds this repository from the maintainer's workspace checks the parts that can be checked mechanically and refuses to finish when one fails.

## Courtesy towards the game and ACE

Stonehearth is a finished game that Radiant can no longer update, and ACE is a volunteer project that keeps it alive. Our findings exist because both made their code open to modding.

- Describe what the code does and when it costs, not who got it wrong. Write "each building plan copies every finished building in the world into its navigation grid", not "ACE's plan code is broken".
- Name the code (file and function) and the condition under which the cost appears. Say when a choice is reasonable at normal scale and only becomes expensive in large worlds.
- Attribute accurately. Several costs we fixed are in the base game, and some ACE code is a copy of base game code. Do not let "with ACE" read as "caused by ACE" when the code came from the base game.
- No judgement words about other people's code: bad, sloppy, careless, lazy, naive, wasteful, terrible, broken (as a verdict), mistake, fault. Technical terms that describe behaviour stay: a listener that outlives its view, a cache that is never read, a memory leak.
- Thank where thanks are due, and keep the "not affiliated" note on every public page.

## Big numbers and small numbers

Our benchmark is a stress test: 4 towns of 28 hearthlings (112 in total), 44 buildings of which 8 are under construction, raids, ridges and lakes, run under Wine on an Apple M4 Pro. Totals measured there are larger than what one player in one town sees, and stating them bare overstates the effect for most players.

- Every number carries its scale where it appears: the same sentence, bullet, table row or table header says where it was measured ("in our 4-town test", "in the 112-hearthling benchmark"), or the number is a rate or a mechanism that holds on any machine.
- Lead with the effect that carries over to a normal game (the mechanism, a per-event or per-day rate, a share of work), and give the stress-test total second, labelled as such.
- Say how the effect scales with the player's game when that is known: with the number of finished buildings, with session length, with the number of citizens, with the length of the load.
- Totals summed over a whole benchmark run are never the headline. A total of 13 minutes of pauses over a 4-town run is presented as "pauses of 10 to 25 s per building plan in our 4-town test, growing with every finished building", with the run total as the test result.
- Single runs and one run pair are said to be single runs. Save and load times come with the save size and the platform.
- Images follow the same rules: a number on an image carries its scale on the image itself.

## Checks in the public build

The build fails when a published file contains a judgement word aimed at the game, ACE or Radiant, or when a headline file (README, CHANGELOG, release notes, Workshop text) has a measured number on a line, bullet or table row without a scale cue. The build script lists the scale cues and the headline files. A number that needs no cue (a version, a date, a setting value) is written in a form the check does not count, or the line gets a cue.
