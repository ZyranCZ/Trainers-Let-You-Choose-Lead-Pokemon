# Changelog

## 2.0.1 — Gen1Recomp v0.1.86 migration

- Replaced entry-time `GameVersion.generation()` routing with capability-based
  dispatch from the live `battle.started` payload.
- Fixed the v0.1.86 SDK/Gold case where the mod loaded with zero errors but
  silently installed the Gen 1 backend.
- Removed the Gold-visible `BattleState.makeBattler` require; the Gen 1 backend
  now resolves that capability only from a proven live Gen 1 battle instance.
- Added fail-closed handling if the Gen 1 battler constructor capability is not
  available.
- Corrected diagnostic-field clearing so a successful battle no longer retains
  an earlier skip reason.
- Preserved option keys/defaults, Gen 1 behavior, Gold behavior, link exclusions,
  party order, participant bookkeeping and all existing public exports.
- Added a real v0.1.86 sandbox/loader SDK suite for both declared generations.

## 2.0.0 — Gen 2 support

- Removed the engine-version gate; a version string alone no longer prevents the mod from loading.
- Preserved the Red / Blue / Yellow v1.0.1 behavior and isolated its Gen 1-only BattleState / Timing backend.
- Added a separate Pokemon Gold backend using `battle.started` eligibility plus a matching `screen.pushed` battle-screen seam.
- Added a semantic marker immediately before Gold's native initial player send-out.
- Added direct Gold party selection with B cancel, fainted refusal and Egg refusal.
- Added pre-sendout Gold lead rebinding without `Battle:switch()`, party reordering or `battle.battler_switched`.
- Corrected Gold participant bookkeeping, side references, pending `Go!` text, battle UI caches and provisional Amulet Coin state.
- Added Gold fail-closed behavior for unknown intro layouts and explicit catching-tutorial / Bug Catching Contest exclusions.
- Added a dedicated Gold headless contract suite and expanded special-wild eligibility coverage.
- Declared both `gen1` and `gen2` in `manifest.games`, so the launcher loads the mod normally in Pokemon Gold.
- Promoted the Gen 2 implementation to the stable 2.x release line.
