# Trainers Let You Choose Lead Pokemon

Gen 1 sends out party slot 1 and gives you no say. The usual answer is to park
your strongest Pokémon there permanently, which quietly removes the matchup
decision from the game.

This asks which Pokémon to send out **once the opposing one is on screen**, so
the choice is made with the information a trainer would actually have.

## Try it

1. Copy the `choose_lead` folder into the game's `mods/` directory.
2. Launch the game, press **F10**, enable **Trainers Let You Choose Lead Pokemon**.
3. Walk into a trainer.

## Options

| Row | Values | Default |
| --- | --- | --- |
| `CHOOSE LEAD` | ON / OFF | ON |
| `ASK BEFORE` | TRAINERS / ALL BATTLES | TRAINERS |

Wild encounters are frequent and mostly one-sided, so asking every time turns a
decision into a chore. Trainer battles are where the matchup matters, so they
are the default; `ALL BATTLES` adds wild encounters.

## Where it slots in

`BattleState:enter` builds the whole intro as a queue of rows and only then
emits `battle.started` — the rows exist but none has run yet. So a listener can
insert a row into that queue before a single frame of the intro is drawn, which
is the seam this mod uses. No hook, no wrapping, and the engine's own
sequencing is left intact.

The row goes in at the `BATTLE_START_SENDOUT` wait, which `core.asm` pays
between the opponent appearing and the player's send-out. That puts the picker
exactly where the decision belongs: the foe is on screen, Red has not thrown
yet. Both that wait and the greeting row are located by content rather than by
a counted offset, so an extra row added to the intro by the engine or another
mod cannot shift the insert onto the wrong step — and an intro it does not
recognise is left alone rather than guessed at.

## What the pick changes

Only which battler is active. The party is **not** reordered, matching a
mid-battle switch — slot 1 stays slot 1, nothing about the save changes, and
the mod can be removed at any time.

`Go! X!` is baked into a queue row when `enter` builds it, so picking a
different Pokémon rewrites that row in place. `markParticipant` is re-run too, and the outgoing lead is struck off
first: that function only ever adds to `self.participants`, and `enter` already
ran it while building the intro, so marking the new one on top would leave both
in the set and hand a free level to the Pokémon that never came out.

`battle.battler_switched` is deliberately not emitted: this is the initial
send-out, which vanilla does not emit either, and a mod listening for switch-ins
should not see a switch that did not happen.

## Where it stays out

**Link battles.** Both sides send out together, and seeing the opponent before
choosing would be neither fair nor in step with the other client.

**The Safari Zone** has no player battler at all, and **the old man's demo**
drives its own menu.

**Fewer than two healthy Pokémon.** There is nothing to decide, so no prompt —
an empty question every time you leave town with one Pokémon would be worse
than no mod.

## Declining

**B** closes the picker and sends out the vanilla lead, and so does picking that
lead deliberately. Either way there is no dead end.

Picking a **fainted** Pokémon gets the same refusal as trying to switch to one
mid-battle — `There's no will to fight!` — and then the picker back.
`forceSwitch` does not guard fainted picks itself: `PartyMenu` pops and calls
back for whatever the cursor is on, and the engine's own `ChooseNextMon` caller
filters exactly the same way.

That caller can stop at the message, because the menu-phase guard reopens the
menu for a player with nothing out. Here the vanilla lead is alive and no guard
fires, so the reopen is explicit: `nextInsert` is zeroed first (only `fn` rows
reset it, and this is a `ui` row), and since the queue is consumed from the
front the message lands next and the picker right behind it.

## Tests

```
lua tests/choose_lead_test.lua
```
