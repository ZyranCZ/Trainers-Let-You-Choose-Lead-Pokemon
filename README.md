# Trainers Let You Choose Lead Pokemon

A mod for [gen1recomp](https://github.com/bryanthaboi/gen1recomp).

Gen 1 sends out party slot 1 and gives you no say. This asks which Pokémon to send out **after the opposing one is on screen** and removes the moment of feeling dumb that your trainer sent out Pidgeot against Raichu etc. 

It certainly removes a certain risk from the game, but that's anyone's decision. 

<img width="2008" height="800" alt="image" src="https://github.com/user-attachments/assets/920e6a5f-4753-4183-b42f-96b6a73987fe" />

## Install

Unzip the latest release into your game's `mods/` folder, press <kbd>F10</kbd>,
enable **Trainers Let You Choose Lead Pokemon**.

## Options

| Setting | Values | Default |
| --- | --- | --- |
| `CHOOSE LEAD` | ON / OFF | ON |
| `ASK BEFORE` | TRAINERS / ALL BATTLES | TRAINERS |

Wild encounters are frequent and mostly one-sided, so asking every time turns a
decision into a chore. `ALL BATTLES` adds them if you want it.

## Notes

**Your party is not reordered.** It behaves like a mid-battle switch — slot 1
stays slot 1, the save is untouched, and the mod can be removed at any time.

**B declines**, and so does picking your existing lead. Picking a fainted one
gets the game's own `There's no will to fight!` and the picker back.

**No free EXP.** The Pokémon that stayed in the ball is struck off the
participant list, so it doesn't collect from a fight it never entered.

**Link battles are excluded** — both sides send out together, and choosing
after seeing the opponent would be neither fair nor in step with the other
client. The Safari Zone and the old man's demo are out too.

The picker is inserted into the intro queue that `BattleState:enter` builds
before `battle.started` fires, at the wait the engine already pays between the
opponent appearing and your send-out. Both that wait and the `Go! X!` row are
found by content rather than position, so an intro this mod doesn't recognise
is left alone rather than guessed at.

Tests run headless: `lua tests/choose_lead_test.lua`

MIT.
