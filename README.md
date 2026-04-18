# TSO — Tank Status Overview

A 12-slot dashboard for a Stationeers IC chip that displays gas and liquid tank readings at a glance, with optional automatic back-pressure-regulator control for each configured tank. Runs on the Orbital Foundry StationeersLua runtime, rendered via ScriptedScreens on a Console (2×2).

## Features

- **Up to 12 Pipe Analyzers** tracked per console, each with a custom label (e.g. "Oxygen", "Fuel", "Waste").
- **Dynamic overview grid** — only configured tanks are rendered; the grid reflows to fill the available console space (1×1 at 1 PA, 2×3 at 6 PAs, 3×4 at 12 PAs) with larger boxes when fewer tanks are configured.
- **Per-tank readouts** — temperature, pressure (with coloured bar + percent of user-defined max), liquid volume (with bar), and network-fault leak detection.
- **Per-tank back-pressure regulator control** — pair each tank with a Back Pressure Regulator (gas) *or* a Liquid Back Volume Regulator. The script holds them `Off` during normal operation (power save), flips them `On` when tank level approaches the configured maximum, and the regulator's own logic handles the actual bleed.
- **Hysteresis** — a shared Safety Margin % setting (default 10%) controls the ON threshold; a hardcoded 20-point gap below the ON threshold defines the OFF threshold to prevent flapping.
- **Dual-cadence loop** — safety-critical reads (pressure, regulator state, leak detection) and regulator control run every game tick (~0.5s); temperature/volume reads and UI refresh run every `LIVE_REFRESH_TICKS` (default 6 ticks = ~3s) to keep instruction cost manageable.
- **Three status sub-tabs in Settings** — LABELS (rename each box), PA (assign Pipe Analyzers, set pressure/volume maxes, set refresh cadence), BPR (assign regulators, set Safety Margin).
- **Leak indicator** in the header cycles through any PA reporting a network fault.

## Required mods

This script depends on three Steam Workshop mods. Subscribe to all three and enable them before loading your save:

- [Stationeers IC10 Editor](https://steamcommunity.com/sharedfiles/filedetails/?id=3592775931) — provides the in-game Lua editor and runtime environment; also exposes the "disable code limits" setting this script needs.
- [StationeersLua Runtime](https://steamcommunity.com/sharedfiles/filedetails/?id=3659911735) — the Lua interpreter and `ic.*` / `mem_*` API globals the script calls.
- [ScriptedScreens](https://steamcommunity.com/sharedfiles/filedetails/?id=3681145650) — the UI layer (`ss.ui.*`) that renders the dashboard on a Console.

Without all three mods the script will fail to load.

## Setup

1. In the IC10 Editor mod settings, **disable code limits** (or at minimum raise them above 2000 lines). The script is ~1800 lines.
2. In StationeersLua settings, make sure the runtime is enabled.
3. Place a **Console (2×2)** and insert an IC chip with an **Integrated Circuit (IC10)** motherboard or the appropriate ScriptedScreens housing.
4. Paste the contents of [`LUA - TSO - Tank Status Overview.lua`](./LUA%20-%20TSO%20-%20Tank%20Status%20Overview.lua) into the chip via the IC10 editor and **Export to Chip**.
5. If Steam Workshop truncates the script on paste (it sometimes caps at ~2000 lines), copy the file contents directly from this repository instead.

## Usage

### First-time configuration

1. Open the console in-game and click **SETTINGS** at the top.
2. **LABELS** sub-tab — give each of your tanks a descriptive name (up to 24 characters per label). Only the boxes you want to display need labels; unconfigured boxes won't render on the overview.
3. **PA** sub-tab —
   - Set **Press Max (kPa)** to your target maximum pressure (e.g. 55,000 for a 5 MPa buffer below the 60 MPa tank failure limit).
   - Set **Volume Max (L)** if you're tracking liquid tanks.
   - Set **Ref. Ticks** for the UI refresh cadence (lower = more responsive, higher = lower script cost).
   - Tap **Change** on any row to pick the Pipe Analyzer that monitors that tank. The list shows every PA on the same data network as the console.
4. **BPR** sub-tab (optional — only if you want automatic bleed control) —
   - Set **Safety Margin %** (default 10%). This is how far below max pressure the regulator activates. The hint beside the input shows the resulting ON and OFF thresholds.
   - Tap **Change** on any row to pair that tank with a back-pressure regulator. Both gas (`Back Pressure Regulator` + Mirrored) and liquid (`Liquid Back Volume Regulator` + Mirrored) variants are listed.
5. Return to **OVERVIEW**. You'll see a grid of your configured tanks with live readings and a **BPR** status row on each box (`No BPR` / `Off` / `On` / `Venting` / `Error`).

### Important: regulator naming

Each regulator on your data network **must have a unique display name** (e.g. "BPR - Waste", "BPR - Fuel"). Stationeers logic-batch APIs address devices by `(prefab, name hash)`. If multiple regulators share the same name (including the default "Back Pressure Regulator"), the script cannot distinguish them — all writes broadcast to every regulator with that shared name, and reads return the average across them.

Rename each regulator in-game with a unique identifier before assigning it in the BPR sub-tab.

## How the regulator control works

For each assigned regulator, the script:

1. **Pins the regulator's `Setting`** — gas regs get `pa_pressure_max_range` (clamped to the 60,795 kPa hardware ceiling); liquid regs get `100 − safety_margin_pct` as the volume-ratio %.
2. **Monitors the paired PA's pressure (gas) or volume (liquid) every fast tick.**
3. **Toggles `On`** — turns the regulator `On` when pressure reaches `(1 − margin)` of max; turns it `Off` when pressure falls below `(1 − margin − hysteresis_gap)` of max. Between those thresholds the regulator keeps its current state.
4. **The regulator's own internal logic** handles the actual bleed (input pressure ≥ `Setting` → gas flows out). The script never tries to force-bleed; it only arms the regulator when the tank is close to the limit.

## Troubleshooting

- **"Instruction limit exceeded" error on boot or UI reload:** usually clears when you restart the console screen. If it persists, raise `LIVE_REFRESH_TICKS` in the PA sub-tab to reduce UI refresh frequency.
- **Regulator shows "Venting" but shouldn't:** check that the regulator's `Setting` matches your pressure max. If not, edit the Pressure Max field in the PA sub-tab (even setting it to the same value re-pushes Setting to every assigned regulator). If only one regulator is wrong, reassign it via the BPR picker.
- **Regulator changes affect multiple regulators at once:** two or more regulators share the same name. Rename them so each is unique.
- **Tanks disappear from the overview:** the overview only shows boxes with an assigned PA. If a PA was deleted or renamed, the box treats it as unassigned. Reassign via Settings → PA.
- **Settings values revert after editing:** the script writes to chip memory on every change. If values don't stick, the chip may have run out of memory (unlikely — the script uses 172/512 slots) or the on_change handler threw; check the chip for a runtime error via the IC editor.

## Credits

Dynamic grid, regulator control, dual-cadence loop, scrolling device picker, and this README contributed by [derrickmehaffy](https://github.com/derrickmehaffy).
