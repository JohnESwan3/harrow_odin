# HARROW

Open-world survival sim / action FPS prototype. Tactical encounters, horror,
intensity; farming, crafting and base-building on the roadmap, with hostile
factions (not just the dead). Odin + sokol (D3D11) + SDL3 (gamepad).

## Build & run

```powershell
.\build.ps1          # optimized build -> harrow.exe (default)
.\build.ps1 -Dbg     # debug build
.\build.ps1 -Run     # build then launch
```

Dev quick-start flags:

```
harrow -solo                      straight into a solo session
harrow -host "My Server" -pass x  host immediately
harrow -join 192.168.1.10 -pass x join immediately
```

> First host: allow harrow.exe through Windows Firewall (private networks)
> or LAN discovery/joining won't reach you.

## Controls

| Action          | KB/M          | Gamepad   |
|-----------------|---------------|-----------|
| Move / Look     | WASD / mouse  | L / R stick (Halo-style response + turn accel) |
| Sprint          | Shift (hold)  | L3        |
| Aim down sights | RMB (hold)    | LT (hold) |
| Fire            | LMB           | RT        |
| Jump            | Space         | A         |
| Crouch          | Ctrl          | B         |
| Reload / Active | R             | X         |
| Switch weapon   | Q / wheel /1-6| Y         |
| Grenade         | G             | RB        |
| Melee           | V             | R3        |
| Roster          | Tab (hold)    | Back      |
| Menu            | Esc           | Start     |

The pause menu shows the control reference for whichever device you used last.
Active reload: second reload press in the bright window = instant reload with
a quiet damage bonus for that mag; the grey window finishes early; missing
jams the weapon.

## World tech (the perf foundation)

- **Micro-voxels**: 0.25 m voxels (4x Minecraft linear density), 32^3 chunks.
- **Procedural base, sparse edits**: terrain + structures are pure functions —
  untouched world costs zero memory at any world size (currently 2 x 2 km
  playable). Only edited chunks materialize into dense arrays.
- **Destruction**: explosions crater terrain, bullets chip surfaces. Every
  edit is a 16-byte op — replicated to peers, streamed to late joiners, and
  persisted to `world.sav` as an append-only log replayed on load.
- **Greedy meshing** keeps triangle counts low; chunks stream in around the
  player inside a 5 ms/frame time box, with frustum culling and eviction.

## Multiplayer

Listen-server over UDP 27499. Server name + optional password; LAN broadcast
discovery or direct IP. Snapshots 20 Hz, client states 30 Hz, shots/hits and
world-edit ops relayed through the host. 8 players.

## Roadmap

- Renderer: PBR, shadow maps, contact shadows, SSR, screen-space shadows,
  froxel volumetric fog (real light shafts), resolution scaling (Steam Deck)
- Voxel: async meshing thread, LOD rings, region-file chunk persistence
- Survival systems: farming, crafting, base building, enemy factions, AI
- Audio, netcode hardening (sequencing, delta snapshots, interest management)
