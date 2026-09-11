# BEACON PROTOCOL — Master Operator Games

Original tactical FPS for Roblox (Rojo + Knit). Build contract:
`/home/team/shared/gdd/tactical-fps-mvp-gdd.md` (team hypothesis, not owner-ratified).

100% original IP. Stylized blocky violence. Server-authoritative hit detection.

## Layout

- `default.project.json` — Rojo project (maps `src/` + `packages/knit/Knit.rbxm`)
- `src/shared/` — Constants, Enums, Config (Weapons/Economy/Combat)
- `src/server/Logic/` — pure-Luau logic: HitDetectionCore, DamageModel,
  MatchStateMachine, EconomyLedger, PlayerHealth, Signal
- `src/server/Services/` — Knit services: Combat, Economy, Match, PlayerState
- `src/client/` — Knit controllers + UI EventBus seam (UI itself is Phase 2)
- `packages/knit/` — Knit framework sources + prebuilt `Knit.rbxm`

## Checks

```sh
rojo build -o build/beacon-protocol.rbxl   # must succeed
selene src                                  # 0 errors (2 _G.task shim warnings, by design)
stylua --check src                          # clean
```

Phase 1 scope: netcode core (server hitscan + ≤200 ms lag compensation),
round/match state machine, buy-economy ledger, damage model. BEACON objective
logic, buy menu/HUD, map art, and monetization are Phase 2.
