# HARROW — Progress

Working log of major changes. One entry per commit-worthy milestone.

## 2026-06-11

- **Toolchain**: Odin dev-2026-06 installed (old install backed up), sokol-odin
  bindings + static libs built into `sokol/`, sokol-shdc in `tools/`,
  `build.ps1` (release by default, `-Dbg` for debug, `-Run` to launch).
- **Game scaffold (as VIBEFALL)**: sokol D3D11 renderer, immediate-mode UI +
  menus, FPS controller (Halo-style stick feel), 6 greybox weapons with
  Gears-style active reload, UDP listen-server multiplayer (host/join with
  server name + password, LAN discovery), settings persistence. Verified
  host+client on localhost.
- **Rebrand to HARROW** + mature desaturated UI, device-aware control hints,
  random callsigns, squad colors, video settings (display/resolution/vsync).
- **Combat sim v2**: all guns fire ballistic projectiles, per-gun recoil
  (40% permanent / 60% recovering), ADS on everything (sniper scope), faster
  per-gun reloads, sprint + stamina, auto step-up.
- **Voxel world v1**: 0.25 m blocky voxels, procedural-base + sparse-edit
  chunks, greedy meshing, streaming + frustum culling, destruction ops
  replicated over the net and persisted to world.sav (op log).
- **Voxel world v2**: terrain became a signed density field at 0.125 m meshed
  with surface nets in 4 m column tiles (round hills, smooth craters); render
  mesh samples at 0.25 m for 4x fewer tris (~90 FPS @ ~900K tris). Structures
  stay blocky. Material toughness vs op power; proportional damage so every
  gun marks everything except bedrock. Material-aware particles (shards,
  splinters, sparks) + soft blended dust/smoke, muzzle smoke. Pause fixed
  (input edge consumption; solo pause freezes sim). More vivid materials.

## 2026-06-12

- **Repo**: git initialized, progress.md started. Workflow from here: commit
  per major change, compile + test each step.
