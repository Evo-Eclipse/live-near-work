# Live Near Work

Surviving Mars mod that auto-relocates colonists closer to their workplace.

## Overview

- *Inter-dome relocation* — colonist works in Dome B but lives in Dome A? Moves to B
- *Intra-dome optimization* — moves colonists closer to their workplace within dome
- *Cross-relocation handling* — correctly handles A: X→Y and B: Y→X simultaneously
- *Comfort-aware* — won't move to significantly worse housing
- *Smart filtering* — respects children-only, tourist-only, and exclusive residences
- *Dome connectivity check* — only moves between connected domes (passages/shuttles)
- *Auto-trigger* — runs at shift changes (6:00, 14:00, 22:00)

## Installation

1. Copy `live-near-work` folder to `%AppData%\Surviving Mars Relaunched\Mods\`
2. Enable in Mod Manager
3. Start or load your game

## Usage

### Console Commands

```other
LiveNearWork.Run()          -- manual run
LiveNearWork.Enable()       -- enable
LiveNearWork.Disable()      -- disable
LiveNearWork.DebugEnable()  -- enable debug logs
LiveNearWork.DebugDisable() -- disable debug logs
```

### Log Output

```lua
Status  Colonist                  Dome Transfer               Residence Transfer                Reason
------  ------------------------  --------------------------  --------------------------------  --------------------
SKIP    Hope Bruno [-]            Lange #1 -> Buisson #1      Apartments -> ???                 no_space
SKIP    Bang Kwok [Sec]           Lange #1 -> Buisson #1      Apartments -> ???                 plan_full
OK      Larissa Schultz [Sci]     Lange #1 -> Buisson #1      Apartments -> Living Complex      workplace
OK      Zhuang Wei [Sci]          Buisson #1 -> Lange #1      Living Complex -> Apartments      workplace

[LNW] Done: 26 relocated (26 inter-dome, 0 intra-dome)
```

### Status Codes

- `OK` — successfully relocated
- `SKIP` — could not relocate (see Reason)

### Reason Codes

- `workplace` — moved to workplace dome (inter-dome)
- `distance` — moved closer to workplace (intra-dome)
- `no_space` — no free beds in target dome

## Settings

Edit in `Code/Script.lua` → `LiveNearWork.Settings`:

```lua
LiveNearWork = {
    Settings = {
        enabled = true,               -- Enable/disable mod
        debug = false,                -- Debug logging
        -- Triggers
        trigger_hours = {6, 14, 22}, -- Hours when relocation runs
        scan_delay = 500,             -- Delay after shift start (ms)
        -- Rules
        allow_intra_dome = true,      -- Enable intra-dome optimization
        max_comfort_loss = -10,       -- Max comfort drop allowed
        min_intra_score = 10,         -- Min improvement for intra-dome
        -- Scoring
        dist_score_max = 50,          -- Max proximity bonus points
        dist_score_step = 1000        -- Distance scale (game units)
    }
}
```

| Setting          | Default     | Description                                 |
| ---------------- | ----------- | ------------------------------------------- |
| enabled          | true        | Master switch for mod                       |
| debug            | false       | Enable detailed console logs                |
| trigger_hours    | {6, 14, 22} | Game hours when relocation runs             |
| scan_delay       | 500         | Milliseconds to wait after shift start      |
| allow_intra_dome | true        | Move colonists within same dome             |
| max_comfort_loss | \-10        | Don't move if comfort drops >10             |
| min_intra_score  | 10          | Intra-dome moves need +10 score improvement |
| dist_score_max   | 50          | Max bonus points for being close            |
| dist_score_step  | 1000        | Distance divisor (lower = more sensitive)   |

## Technical Details

### How It Works

#### Scoring

Each residence gets a score based on:

1. *Base comfort* — residence service comfort value
2. *Proximity bonus* — closer to workplace = higher score (0-50 points)
3. *Comfort penalty* — -1000 points if comfort drops too much

Best scoring residence wins!

#### Relocation

1. *Filter* — Skip tourists, dying, in-transport, user-assigned colonists
2. *Collect* — Find colonists whose workplace dome ≠ residence dome
3. *Sort* — Inter-dome moves first (priority 2), then intra-dome (priority 1)
4. *Plan* — Reserve spaces, handle cross-relocations
5. *Execute* — Apply moves if space still available

### Exclusions

The mod automatically skips:

- *Tourists* — they use own hotel-specific logic
- *User-assigned residences* — respects manual assignments
- *Children* — only move to/from Nurseries
- *Colonists in transport* — to avoid game engine issues
- *Dying/leaving colonists* — too late
- *Unconnected domes* — no passage or shuttle available

### Compatibility

- ✅ Works with all residence types (Living Complex, Apartments, Arcology, etc.)
- ✅ Respects children-only buildings (Nursery, School)
- ✅ Respects exclusive residences (Senior Residence, Hotels)
- ✅ Compatible with passage/shuttle mods
- ⚠️ May conflict with other auto-assignment mods
- ⚠️ May conflict with modded hotels or nurseries

## Changelog

### Version 1.0

- Initial release
- Inter-dome and intra-dome relocation
- Comfort-aware residence selection
- Automated execution at shift changes

---

Created with 💜 and Lua by Evo-Eclipse
