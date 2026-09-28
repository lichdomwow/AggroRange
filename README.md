# AggroRange

Estimates how many yards you are outside a hostile NPC's body-pull aggro range in **World of Warcraft Classic Era and Hardcore**.

**[Download the official addon on CurseForge](https://www.curseforge.com/wow/addons/aggrorange)** · **[Report a bug](https://github.com/lichdomwow/AggroRange/issues)**

CurseForge is the main download page. This repository provides the released source and an issue tracker.

## Supported version

- AggroRange **1.0.0**
- WoW **Classic Era / Hardcore 1.15.9** (`Interface: 11509`)
- No additional addon libraries are required by this release.

Retail, other Classic branches, and World of Warcraft: Forever are not supported by this release.

## What it does

- Estimates proximity aggro using player and NPC levels, available range measurements, and exception handling.
- Displays estimated clearance beside your current target's frame and visible nameplate.
- Shows a separate readout when you mouse over another eligible hostile NPC with a visible nameplate, including while you are in combat.
- Accounts for detected Mind Soothe debuffs.
- Briefly displays `AGGRO` when the selected NPC engages you, then hides that target's proximity readout.

## Installation

Install AggroRange through CurseForge, or download its official ZIP from the [project page](https://www.curseforge.com/wow/addons/aggrorange).

For manual installation, extract the `AggroRange` folder into your Classic Era installation's `Interface/AddOns/` directory. The final path should contain `Interface/AddOns/AggroRange/AggroRange.toc`, with both Lua files beside it. Enable AggroRange on the character-selection AddOns screen.

GitHub's automatically generated source archives are for source inspection; use the CurseForge package for normal installation.

## Usage

Select a living hostile NPC, or hover over its visible nameplate. Neutral NPCs and player characters do not receive proximity-aggro estimates.

| Display | Meaning |
| --- | --- |
| `+6 yd` | Estimated to be about six yards outside the modeled aggro boundary. |
| `0 yd` or a negative number | At or inside the modeled boundary. |
| `>+6 yd` | The available measurement gives a lower bound rather than an exact clearance estimate. |
| `~` prefix | A provisional built-in exception is being used. Ordinary readings are estimates too. |
| `?` | The available information is insufficient for a usable estimate. |
| `AGGRO` | The NPC is detected as engaged with you. |

Green, yellow, and red describe how the measured distance band relates to the modeled boundary. Green is not a guarantee of safety.

| Command | Action |
| --- | --- |
| `/ar` | Show help. `/aggrorange` is an equivalent command prefix. |
| `/ar plate on` / `/ar plate off` | Enable or disable target, nameplate, and mouseover indicators. |
| `/ar distance` | Show the current nameplate distance. |
| `/ar distance max` | Request this release's recommended nameplate distance of 41 yards. |
| `/ar reset` | Reset AggroRange's settings. |
| `/ar advanced` | List diagnostic and experimental commands. |

Enable enemy nameplates to use the nameplate and mouseover displays. The target-frame display can remain visible when the selected target's nameplate is off-screen.

## Limitations

**AggroRange estimates a boundary; it does not guarantee a safe pull or safe passage. This matters especially in Hardcore.**

Range probes return bands rather than precise distances. Finite-band numbers use a midpoint estimate, and some NPC exception values remain provisional. Social aggro, scripted encounters, unusual NPC behavior, stealth/detection effects, and other special mechanics can differ from the model. Unknown levels and unavailable range information can also prevent a useful reading.

Exception research draws on [CMaNGOS/ClassicDB](https://github.com/cmangos/classic-db) and [VMaNGOS](https://github.com/vmangos/core), supplemented by selected live Classic Era observations. Emulator values are research inputs, not authoritative Blizzard measurements. Source and policy annotations remain in `Exceptions.lua`. See [research sources and third-party notices](THIRD_PARTY_NOTICES.md).

## Bug reports

Please [open an issue](https://github.com/lichdomwow/AggroRange/issues) with your addon and game versions, player class/level, NPC name and level, zone, what happened, and what you expected. Include reproduction steps, a screenshot, or the exact Lua error if available. For aggro discrepancies, note Mind Soothe, pets, attacks, nearby mobs, and whether the display had a `~` prefix.

Use `/ar debug on` only if additional diagnostics are needed, and `/ar debug off` afterward. Do not risk a Hardcore character to reproduce a report. Review logs and screenshots before sharing; do not upload your entire `WTF` folder or account data.

## Author and license

Created by **Lichdom**.

Copyright (c) 2026 Lichdom. All rights reserved. AggroRange is source-available proprietary software under the [AggroRange License](LICENSE). Source visibility is not an open-source license. The license preserves permissions granted through GitHub and applicable third-party rights. See the license for permitted use and restrictions.

World of Warcraft and related Blizzard names and intellectual property belong to Blizzard Entertainment and its licensors. AggroRange is an unofficial addon.
