# Trainers Let You Choose Lead Pokemon

Normally the game sends out your first usable party Pokemon automatically. This
mod waits until the opponent is visible, then lets you choose which healthy
Pokemon should make the **initial** send-out.

The resulting flow is:

> **Opponent appears first -> choose your lead -> selected Pokemon is sent out normally.**

Your party is never reordered.

## Supported games

- **Pokemon Red**
- **Pokemon Blue**
- **Pokemon Yellow**
- **Pokemon Gold (Gen 2)**

Version **2.0.0** is the first stable release line with Gen 2 support. The original
Red / Blue / Yellow behavior is preserved while Gold uses its dedicated Gen 2
battle backend.

## Options

| Row | Values | Default |
| --- | --- | --- |
| `CHOOSE LEAD` | ON / OFF | ON |
| `ASK BEFORE` | TRAINERS / ALL BATTLES | TRAINERS |

`TRAINERS` prompts only for trainer battles. `ALL BATTLES` also enables the
prompt for compatible wild encounters.

Options are live and do not require restarting the game.

## How it behaves

The opponent is shown before the picker opens. Selecting a Pokemon immediately
uses it as the initial lead; there is no SWITCH / STATS submenu.

- **B** cancels the picker and keeps the normal vanilla lead.
- Selecting the already-provisional lead is a no-op.
- Fainted Pokemon are rejected and the picker reopens.
- In Gold, Eggs are also rejected with Gold's native-style message.
- If fewer than two legal battlers are available, no picker is shown.
- Party order and save data are not changed.
- The initial choice is **not treated as a mid-battle switch** and does not emit
  `battle.battler_switched`.

## Generation-specific implementation

### Red / Blue / Yellow

The original v1.0.1 queue seam is retained: the mod locates the native `Go!`
row and the matching `BATTLE_START_SENDOUT` wait immediately before the
player's initial send-out. Unknown intro layouts fail closed and use the
vanilla lead.

### Pokemon Gold

Gold has a separate battle engine and UI. `battle.started` happens before the
battle screen exists, so the mod first marks an eligible battle as pending.
When the matching Gold battle screen is pushed, it finds the native initial
player `sendout` event semantically and inserts one mod-owned marker directly
before it.

Choosing a different lead rebinds only the **provisional initial battle
identity**. It does **not** call Gold's ordinary `Battle:switch()` path. The mod
updates `player`, `playerIndex`, participant bookkeeping, side references,
Gold's battle-screen caches, the pending `Go!` text, and the provisional Amulet
Coin state before allowing the one native send-out to continue.

## Exclusions

- Link battles are excluded.
- Red / Blue / Yellow Safari and demo battles keep their original exclusions.
- Gold's catching tutorial is excluded.
- Gold's Bug Catching Contest is excluded; the contest masks the party down to
  one battling Pokemon, so there is no lead decision to make.
- Unknown or changed intro queue layouts fail closed to the vanilla lead.

## Gold notes

Gold uses a separate battle engine, so its implementation is intentionally kept
separate from the Red / Blue / Yellow backend. The normal trainer flow remains:

1. Opponent appears first.
2. The party picker opens.
3. Choose the Pokemon that should make the initial send-out.
4. The selected Pokemon is sent out through Gold's native send-out sequence.

`ASK BEFORE = ALL BATTLES` also enables the prompt for compatible wild battles.
The catching tutorial and Bug Catching Contest remain intentionally excluded.

## Automated tests

From the mod directory:

```sh
CHOOSE_LEAD_MAIN="$PWD/main.lua" texlua tests/choose_lead_test.lua
CHOOSE_LEAD_MAIN="$PWD/main.lua" texlua tests/choose_lead_gold_test.lua
```

The first suite locks the Red/Blue/Yellow v1.0.1 contract. The second models
the current Gold battle constructor, battle-screen intro queue and direct party
picker contract and verifies lead rebinding, participant correction, no
ordinary switch path, exactly one initial send-out, UI cache synchronization,
Amulet Coin correction, Egg/fainted refusal, exclusions and state cleanup.
