-- Drives the queue insertion and the pick against a stand-in BattleState
-- shaped like the real intro queue.
-- Run from the game root:  lua tests/choose_lead_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local modPath = os.getenv("CHOOSE_LEAD_MAIN") or "mods/choose_lead/main.lua"

package.loaded["src.core.GameVersion"] = { generation = function() return 1 end }
package.loaded["src.core.Timing"] = { BATTLE_START_SENDOUT = 40 }

local madeBattlers = {}
package.loaded["src.battle.BattleState"] = {
  makeBattler = function(_, mon)
    madeBattlers[#madeBattlers + 1] = mon
    return { mon = mon, name = mon.name }
  end,
}

local options = { enabled = true, when = "trainers" }
local listeners = {}

local mod = {
  options = { define = function() end, get = function(_, k) return options[k] end },
  events = { on = function(_, name, fn)
    listeners[name] = listeners[name] or {}
    table.insert(listeners[name], fn)
  end },
  hooks = { wrap = function() end },
  exports = {},
  log = { info = function() end, warn = function() end },
}

assert(loadfile(modPath), "cannot load " .. modPath)()(mod)

local function emit(name, payload)
  for _, fn in ipairs(listeners[name] or {}) do fn(payload) end
end

local function setOption(key, value)
  options[key] = value
  emit("mod.options_changed", { mod = "choose_lead", key = key, value = value })
end

local CHARMANDER = { name = "CHARMANDER", hp = 20 }
local MAGNETON = { name = "MAGNETON", hp = 30 }
local FAINTED = { name = "PIDGEY", hp = 0 }

-- A stand-in shaped like BattleState after enter() has built the intro but
-- before any row has run.
local function makeBattle(fields)
  local party = (fields or {}).party or { CHARMANDER, MAGNETON }
  local battle = {
    kind = (fields or {}).kind or "trainer",
    safari = (fields or {}).safari,
    demo = (fields or {}).demo,
    data = {},
    game = { save = { party = party } },
    player = { mon = party[1], name = party[1].name },
    synced = 0, marked = 0,
  }
  function battle:sendOutText(name) return "Go! " .. name .. "!" end
  function battle:syncSides() self.synced = self.synced + 1 end
  function battle:markParticipant()
    self.marked = self.marked + 1
    self.participants = self.participants or {}
    self.participants[self.player.mon] = true
  end
  function battle:buildScreen(id, opts)
    return { id = id, opts = opts }
  end
  function battle:romText(_, fallback) return fallback end
  -- the engine inserts relative to nextInsert and consumes from the front
  function battle:sayNext(text)
    self.nextInsert = (self.nextInsert or 0) + 1
    table.insert(self.queue, self.nextInsert, { text = text })
  end
  function battle:uiNext(factory)
    self.nextInsert = (self.nextInsert or 0) + 1
    table.insert(self.queue, self.nextInsert, { ui = factory })
  end
  -- the intro as enter() leaves it
  battle.queue = {
    { text = "TRAINER wants to fight!" },
    { fn = function() end },
    { text = "TRAINER sent out STARMIE!" },
    { wait = 40 },                                  -- BATTLE_START_SENDOUT
    { fn = function() end },                        -- Red slides off
    { wait = 18 },
    { fn = function() end },
    { text = battle:sendOutText(battle.player.name) },
    { anim = "POOF_ANIM" },
    { fn = function() end },
  }
  -- enter() marks the vanilla lead while building the intro
  battle:markParticipant()
  battle.marked = 0
  return battle
end

local failures = 0
local function check(label, got, want)
  local ok = got == want
  if not ok then failures = failures + 1 end
  print(("%-58s %s  (got %s, want %s)")
    :format(label, ok and "PASS" or "FAIL", tostring(got), tostring(want)))
end

-- the picker is inserted at the send-out wait, after the foe is on screen
local battle = makeBattle()
local before = #battle.queue
emit("battle.started", { battle = battle })
check("a row is inserted", #battle.queue, before + 1)
check("it is a ui row", battle.queue[4].ui ~= nil, true)
check("it lands on the send-out wait", battle.queue[5].wait, 40)
check("the foe is already on screen by then",
      battle.queue[3].text, "TRAINER sent out STARMIE!")
check("and Red has not thrown yet",
      battle.queue[9].text, "Go! CHARMANDER!")

-- the screen it builds is the party picker in ChooseNextMon's shape
local screen = battle.queue[4].ui()
check("it builds the party menu", screen.id, "PartyMenu")
check("with no submenu to get stuck in", screen.opts.forceSwitch, true)

-- picking another Pokémon swaps the active battler and fixes the greeting
screen.opts.onSwitch(MAGNETON)
check("the chosen mon is now active", battle.player.mon, MAGNETON)
check("the greeting is rewritten", battle.queue[9].text, "Go! MAGNETON!")
check("the sides are resynced", battle.synced, 1)
check("the exp share follows it", battle.marked, 1)
check("the new lead collects exp", battle.participants[MAGNETON], true)
-- markParticipant only ever adds, and enter() already marked the vanilla
-- lead: leaving it in would hand exp to a mon that never came out
check("the mon that stayed in the ball does not",
      battle.participants[CHARMANDER], nil)
check("the party is not reordered", battle.game.save.party[1], CHARMANDER)

-- picking the current lead is how you decline
battle = makeBattle()
emit("battle.started", { battle = battle })
battle.queue[4].ui().opts.onSwitch(CHARMANDER)
check("picking the lead changes nothing", battle.player.mon, CHARMANDER)
check("and leaves the greeting alone", battle.queue[9].text, "Go! CHARMANDER!")

-- PartyMenu's forceSwitch does not guard fainted picks, so the refusal has
-- to happen here -- with the engine's own message and the picker back
battle = makeBattle{ party = { CHARMANDER, MAGNETON, FAINTED } }
emit("battle.started", { battle = battle })
-- the engine removes the ui row from the front before running it
local picker = table.remove(battle.queue, 4)
for _ = 1, 3 do table.remove(battle.queue, 1) end
picker.ui().opts.onSwitch(FAINTED)
check("a fainted pick is refused", battle.player.mon, CHARMANDER)
check("and nothing is resynced for it", battle.synced, 0)
check("the engine's own refusal is shown",
      battle.queue[1].text, "There's no will\nto fight!")
check("and the picker comes straight back", battle.queue[2].ui ~= nil, true)

-- and the reopened picker still works
battle.queue[2].ui().opts.onSwitch(MAGNETON)
check("the second pick goes through", battle.player.mon, MAGNETON)
check("and the greeting is rewritten",
      battle.queue[#battle.queue - 2].text, "Go! MAGNETON!")

-- where it stays out
local function inserts(fields)
  local b = makeBattle(fields)
  local n = #b.queue
  emit("battle.started", { battle = b })
  return #b.queue > n
end

check("link battles are left alone", inserts{ kind = "link" }, false)
check("the safari zone is left alone", inserts{ safari = true }, false)
check("the old man demo is left alone", inserts{ demo = true }, false)

-- nothing to decide
check("a single Pokémon gets no prompt",
      inserts{ party = { CHARMANDER } }, false)
check("one healthy and one fainted gets no prompt",
      inserts{ party = { CHARMANDER, FAINTED } }, false)

-- wild battles follow the option
check("wild battles are skipped by default", inserts{ kind = "wild" }, false)
setOption("when", "always")
check("ALL BATTLES includes wild", inserts{ kind = "wild" }, true)
check("and still not link", inserts{ kind = "link" }, false)
setOption("when", "trainers")

setOption("enabled", false)
check("disabled mod inserts nothing", inserts{}, false)
setOption("enabled", true)
check("re-enabling restores it", inserts{}, true)

-- Consecutive battles do not carry any queue/picker state between instances.
local consecutive1 = makeBattle()
local consecutive1Before = #consecutive1.queue
emit("battle.started", { battle = consecutive1 })
check("first consecutive trainer gets one picker", #consecutive1.queue, consecutive1Before + 1)
local consecutive2 = makeBattle{ kind = "wild" }
local consecutive2Before = #consecutive2.queue
emit("battle.started", { battle = consecutive2 })
check("following default wild inherits no picker", #consecutive2.queue, consecutive2Before)
local consecutive3 = makeBattle()
local consecutive3Before = #consecutive3.queue
emit("battle.started", { battle = consecutive3 })
check("next trainer starts cleanly", #consecutive3.queue, consecutive3Before + 1)

-- In the v1.0.1 direct PartyMenu contract, B is handled by PartyMenu itself:
-- no onSwitch callback fires, so the provisional lead and greeting remain.
battle = makeBattle()
emit("battle.started", { battle = battle })
local cancelScreen = battle.queue[4].ui()
check("Gen 1 picker delegates B cancel to PartyMenu", cancelScreen.opts.onCancel, nil)
check("simulated B cancel leaves active mon untouched", battle.player.mon, CHARMANDER)
check("simulated B cancel leaves greeting untouched", battle.queue[9].text, "Go! CHARMANDER!")

-- an intro that does not look like the engine's is left untouched rather
-- than guessed at
battle = makeBattle()
battle.queue = { { text = "something else" } }
emit("battle.started", { battle = battle })
check("an unrecognised intro is not modified", #battle.queue, 1)

print(failures == 0 and "\nall checks passed"
                    or ("\n" .. failures .. " check(s) failed"))
os.exit(failures == 0 and 0 or 1)
