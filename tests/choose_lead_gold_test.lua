-- Headless contract test for Choose Lead's Pokemon Gold backend.
-- It models the current (2026-08-11 dev) Gold shapes that matter to this mod:
-- Battle.new has already chosen a provisional player and participant before
-- battle.started; Gen2BattleState later owns the intro queue and Gen2PartyMenu.

package.path = "./?.lua;./?/init.lua;" .. package.path
local modPath = os.getenv("CHOOSE_LEAD_MAIN") or "mods/choose_lead/main.lua"

-- Gold must never load the Gen 1-only internals.
package.loaded["src.battle.BattleState"] = nil
package.loaded["src.core.Timing"] = nil
package.preload["src.battle.BattleState"] = function()
  error("Gold backend touched Gen 1 BattleState")
end
package.preload["src.core.Timing"] = function()
  error("Gold backend touched Gen 1 Timing")
end
package.loaded["src.core.GameVersion"] = {
  get = function() return "gold" end,
  generation = function() return 2 end,
}

local pushedScreens = {}
package.loaded["src.ui.Screens"] = {
  push = function(game, id, opts)
    local picker = { screenId = id, id = id, opts = opts, game = game }
    pushedScreens[#pushedScreens + 1] = picker
    game.stack:push(picker)
    return picker
  end,
}

local options = { enabled = true, when = "trainers" }
local listeners = {}
local warnings = {}
local observedSwitchEvents = 0
listeners["battle.battler_switched"] = { function()
  observedSwitchEvents = observedSwitchEvents + 1
end }
local mod = {
  options = {
    define = function() end,
    get = function(_, key) return options[key] end,
  },
  events = {
    on = function(_, name, fn)
      listeners[name] = listeners[name] or {}
      table.insert(listeners[name], fn)
    end,
  },
  exports = {},
  log = {
    info = function() end,
    warn = function(_, message) warnings[#warnings + 1] = tostring(message) end,
  },
}

assert(loadfile(modPath), "cannot load " .. modPath)()(mod)

local function emit(name, payload)
  for _, fn in ipairs(listeners[name] or {}) do fn(payload) end
end

local function setOption(key, value)
  options[key] = value
  emit("mod.options_changed", { mod = "choose_lead", key = key, value = value })
end

local failures = 0
local function check(label, got, want)
  local ok = got == want
  if not ok then failures = failures + 1 end
  print(("%-70s %s  (got %s, want %s)")
    :format(label, ok and "PASS" or "FAIL", tostring(got), tostring(want)))
end

local function truth(label, value) check(label, value and true or false, true) end

local function stackNew()
  local stack = { states = {} }
  function stack:push(state) table.insert(self.states, state) end
  function stack:pop() return table.remove(self.states) end
  function stack:top() return self.states[#self.states] end
  return stack
end

local function mon(name, hp, opts)
  opts = opts or {}
  return {
    name = name,
    nickname = opts.nickname,
    species = opts.species or name,
    hp = hp,
    level = opts.level or 10,
    experience = opts.experience or 1000,
    item = opts.item,
    isEgg = opts.isEgg,
  }
end

local function firstLegal(party)
  for i, p in ipairs(party) do
    if not p.isEgg and (p.hp or 0) > 0 then return i end
  end
  return 1
end

local function makeBattle(party, fields)
  fields = fields or {}
  local index = fields.playerIndex or firstLegal(party)
  local battle = {
    party = party,
    playerIndex = index,
    player = party[index],
    participants = { [index] = true },
    wild = fields.wild == true,
    kind = fields.kind,
    link = fields.link,
    battleType = fields.battleType,
    turn = fields.turn or 0,
    synced = 0,
    switchCalls = 0,
    amuletCoin = false,
  }
  function battle:syncSides()
    self.synced = self.synced + 1
    self.sides = self.sides or {
      { battlers = {} }, { battlers = {} },
    }
    self.sides[1].battlers[1] = self.player
  end
  function battle:checkAmuletCoin(p)
    if p and p.item == "AMULET_COIN" then self.amuletCoin = true end
  end
  function battle:switch(_)
    self.switchCalls = self.switchCalls + 1
    error("ordinary switch must never be used for initial lead")
  end
  battle:checkAmuletCoin(battle.player) -- Battle.new provisional latch
  battle:syncSides()
  battle.synced = 0
  return battle
end

local function makeScreen(battle, fields)
  fields = fields or {}
  local game = { stack = stackNew(), save = { party = battle.party } }
  local enemy = mon("RATTATA", 20, { level = 4 })
  local queue
  if fields.noSendout then
    queue = { { kind = "message", text = "something else" } }
  elseif battle.wild then
    queue = {
      { kind = "message", intro = true, text = "Wild RATTATA appeared!" },
      { kind = "sendout", text = "Go! " .. (battle.player.nickname or battle.player.name) .. "!" },
    }
  else
    queue = {
      { kind = "message", text = "YOUNGSTER wants to battle!" },
      { kind = "send", side = "enemy", mon = enemy, text = "YOUNGSTER sent out RATTATA!" },
      { kind = "sendout", text = "Go! " .. (battle.player.nickname or battle.player.name) .. "!" },
    }
  end
  local screen = {
    screenId = fields.screenId or "Gen2BattleState",
    game = game,
    battle = battle,
    queue = queue,
    phase = fields.phase or "intro",
    tutorial = fields.tutorial,
    contest = fields.contest,
    shownMon = { player = battle.player, enemy = enemy },
    shownHp = { player = battle.player.hp, enemy = enemy.hp },
    shownLevel = battle.player.level,
    shownExp = -999, -- obvious stale sentinel, selection must replace it
    hpAnim = { side = "player", to = battle.player.hp },
    expAnim = { stale = true },
    processed = {},
    sendoutCount = 0,
    switchEvents = 0,
  }
  function screen:name(p)
    return p.nickname or p.name or p.species or "?"
  end
  function screen:expPixels(p, level, exp)
    return (level or 0) * 100000 + (exp or 0) + (#(p.name or ""))
  end
  function screen:advanceQueue()
    local event = table.remove(self.queue, 1)
    if not event then return nil end
    self.processed[#self.processed + 1] = event
    if event.kind == "message" then self.message = event.text end
    if event.kind == "sendout" then
      self.sendoutCount = self.sendoutCount + 1
      self.sentMon = self.battle.player
      self.sentText = event.text
    end
    return event
  end
  game.stack:push(screen) -- StateStack does this before screen.pushed is emitted.
  return screen, game
end

local function markerCount(screen)
  local n = 0
  for _, row in ipairs(screen.queue or {}) do
    if row.kind == "choose-lead" and row.owner == "choose_lead" then n = n + 1 end
  end
  return n
end

local function startAndPush(battle, screen, kind, extra)
  local payload = {
    battle = battle,
    kind = kind or (battle.wild and "wild" or "trainer"),
    battleType = battle.battleType,
  }
  for k, v in pairs(extra or {}) do payload[k] = v end
  emit("battle.started", payload)
  emit("screen.pushed", { state = screen })
end

local function runToPicker(screen)
  local guard = 20
  while guard > 0 do
    guard = guard - 1
    local top = screen.game.stack:top()
    if top and top ~= screen then return top end
    local row = screen.queue[1]
    if not row then return nil end
    screen:advanceQueue()
  end
  error("picker guard exhausted")
end

local A = mon("CYNDAQUIL", 31, { level = 12, experience = 1728 })
local B = mon("PIDGEY", 26, { level = 9, experience = 900, nickname = "BIRDY" })
local C = mon("MAREEP", 28, { level = 10, experience = 1100 })
local FAINTED = mon("SENTRET", 0, { level = 8 })
local EGG = mon("EGG", 1, { isEgg = true, level = 5 })

-- ---------------------------------------------------------------- intro seam
local battle = makeBattle({ A, B })
local screen = makeScreen(battle)
startAndPush(battle, screen, "trainer")
check("Gold marker inserted exactly once", markerCount(screen), 1)
check("marker sits immediately before native player sendout",
  screen.queue[#screen.queue - 1].kind, "choose-lead")
check("native sendout remains the final intro row", screen.queue[#screen.queue].kind, "sendout")
emit("screen.pushed", { state = screen })
check("duplicate screen.pushed cannot add a second marker", markerCount(screen), 1)

-- A compatible UI replacement may carry its own screen id.  Matching battle
-- identity plus the queue/advance capabilities are the stable seam.
local replacementBattle = makeBattle({ A, B })
local replacementScreen = makeScreen(replacementBattle, { screenId = "ModernGoldBattleUI" })
startAndPush(replacementBattle, replacementScreen, "trainer")
check("compatible replacement battle screen is accepted by capability",
  markerCount(replacementScreen), 1)

local picker = runToPicker(screen)
check("opponent intro was processed before picker", screen.processed[2].kind, "send")
check("player sendout has not happened before picker", screen.sendoutCount, 0)
check("Gold picker uses Gen2PartyMenu", picker and picker.id, "Gen2PartyMenu")
check("Gold picker is direct-select (no field submenu)", picker.opts.submenu, nil)
check("Gold picker is direct-select (no battle submenu)", picker.opts.battleSubmenu, nil)
check("Gold picker receives the real party table", picker.opts.party, battle.party)

-- ----------------------------------------------------------- valid selection
local partyBefore1, partyBefore2 = battle.party[1], battle.party[2]
picker.opts.onChoose(2, B)
check("selected Gold mon becomes battle.player", battle.player, B)
check("selected Gold slot becomes playerIndex", battle.playerIndex, 2)
check("old provisional participant is removed", battle.participants[1], nil)
check("selected participant is present", battle.participants[2], true)
check("Gold sides are resynced once", battle.synced, 1)
check("party slot 1 is not reordered", battle.party[1], partyBefore1)
check("party slot 2 is not reordered", battle.party[2], partyBefore2)
check("ordinary Battle:switch was never called", battle.switchCalls, 0)
check("initial lead emits no battle.battler_switched event", observedSwitchEvents, 0)
check("no ordinary switch side-effect path ran", battle.switchCalls, 0)
check("exactly one native initial sendout ran", screen.sendoutCount, 1)
check("native sendout used selected mon", screen.sentMon, B)
check("Go! text uses Gold native nickname/name helper", screen.sentText, "Go! BIRDY!")
check("shownMon cache follows selected lead", screen.shownMon.player, B)
check("shownHp cache follows selected lead", screen.shownHp.player, B.hp)
check("shownLevel cache follows selected lead", screen.shownLevel, B.level)
check("shownExp cache is recalculated through expPixels", screen.shownExp,
  screen:expPixels(B, B.level, B.experience))
check("stale player HP animation is cleared", screen.hpAnim, nil)
check("stale EXP animation is cleared", screen.expAnim, nil)

-- --------------------------------------------------------------- B cancel
battle = makeBattle({ A, B })
screen = makeScreen(battle)
startAndPush(battle, screen, "trainer")
picker = runToPicker(screen)
local beforeParticipants = battle.participants[1]
picker.opts.onCancel()
check("B cancel keeps provisional Gold player", battle.player, A)
check("B cancel keeps playerIndex", battle.playerIndex, 1)
check("B cancel keeps participants", battle.participants[1], beforeParticipants)
check("B cancel keeps native Go! text", screen.sentText, "Go! CYNDAQUIL!")
check("B cancel still produces exactly one sendout", screen.sendoutCount, 1)
check("B cancel does not call ordinary switch", battle.switchCalls, 0)

-- ------------------------------------------------------- same lead is no-op
battle = makeBattle({ A, B })
screen = makeScreen(battle)
startAndPush(battle, screen, "trainer")
picker = runToPicker(screen)
picker.opts.onChoose(1, A)
check("choosing current Gold lead keeps identity", battle.player, A)
check("same lead keeps original participant", battle.participants[1], true)
check("same lead creates one native sendout", screen.sendoutCount, 1)
check("same lead does not resync unnecessarily", battle.synced, 0)

-- ------------------------------------------------------- fainted -> reprompt
battle = makeBattle({ A, B, FAINTED })
screen = makeScreen(battle)
startAndPush(battle, screen, "trainer")
picker = runToPicker(screen)
picker.opts.onChoose(3, FAINTED)
check("fainted Gold pick does not change player", battle.player, A)
check("fainted Gold pick shows native Gold refusal", screen.message, "There's no will to battle!")
check("fainted Gold pick does not send out yet", screen.sendoutCount, 0)
picker = runToPicker(screen)
truth("fainted Gold pick reopens picker", picker and picker.id == "Gen2PartyMenu")
picker.opts.onChoose(2, B)
check("valid pick after fainted refusal commits", battle.player, B)
check("valid pick after refusal still sends exactly once", screen.sendoutCount, 1)

-- ------------------------------------------------------------ Egg -> reprompt
battle = makeBattle({ A, B, EGG })
screen = makeScreen(battle)
startAndPush(battle, screen, "trainer")
picker = runToPicker(screen)
picker.opts.onChoose(3, EGG)
check("Egg pick does not change player", battle.player, A)
check("Egg pick shows native Gold refusal", screen.message, "An EGG can't battle!")
picker = runToPicker(screen)
truth("Egg pick reopens picker", picker and picker.id == "Gen2PartyMenu")
picker.opts.onCancel()
check("B after Egg refusal still keeps vanilla lead", battle.player, A)
check("B after Egg refusal sends vanilla lead once", screen.sendoutCount, 1)

-- ------------------------------------------------ legal count excludes Eggs
battle = makeBattle({ A, EGG, FAINTED })
screen = makeScreen(battle)
startAndPush(battle, screen, "trainer")
check("one legal battler + Egg + fainted gets no marker", markerCount(screen), 0)

-- ------------------------------------------------------ option policy is live
battle = makeBattle({ A, B }, { wild = true })
screen = makeScreen(battle)
startAndPush(battle, screen, "wild")
check("Gold wild is skipped by default TRAINERS", markerCount(screen), 0)
setOption("when", "always")
battle = makeBattle({ A, B }, { wild = true })
screen = makeScreen(battle)
startAndPush(battle, screen, "wild")
check("Gold ALL BATTLES includes ordinary wild", markerCount(screen), 1)

-- Special wild construction paths still use the normal player sendout in the
-- current Gold engine.  Headless eligibility stays permissive for those paths;
-- tutorial and Contest are screen-only contexts and are separately excluded.
for _, special in ipairs({
  { label = "fishing", battleType = "fish" },
  { label = "roamer", battleType = "roaming" },
  { label = "FORCESHINY / Red Gyarados", battleType = 7 },
  { label = "TRAP encounter", battleType = 9 },
  { label = "scripted wild", battleType = "scripted" },
}) do
  local sb = makeBattle({ A, B }, { wild = true, battleType = special.battleType })
  local ss = makeScreen(sb)
  startAndPush(sb, ss, "wild")
  check("Gold ALL BATTLES headless includes " .. special.label, markerCount(ss), 1)
end

setOption("when", "trainers")
setOption("enabled", false)
battle = makeBattle({ A, B })
screen = makeScreen(battle)
startAndPush(battle, screen, "trainer")
check("Gold disabled option inserts no marker", markerCount(screen), 0)
setOption("enabled", true)

-- ------------------------------------------------------------ exclusions
battle = makeBattle({ A, B }, { kind = "link", link = true })
screen = makeScreen(battle)
startAndPush(battle, screen, "link")
check("Gold link context is excluded", markerCount(screen), 0)

setOption("when", "always")
battle = makeBattle({ A, B }, { wild = true })
screen = makeScreen(battle, { tutorial = true })
startAndPush(battle, screen, "wild")
check("Gold catching tutorial is excluded at screen seam", markerCount(screen), 0)
check("tutorial skip reason is diagnostic", mod.exports.diagnostics().lastSkipReason, "tutorial")

battle = makeBattle({ A, B }, { wild = true })
screen = makeScreen(battle, { contest = true })
startAndPush(battle, screen, "wild")
check("Gold Bug Catching Contest is fail-closed", markerCount(screen), 0)
check("contest skip reason is diagnostic", mod.exports.diagnostics().lastSkipReason, "bug_contest")
setOption("when", "trainers")

-- -------------------------------------------------------- fail-closed seams
battle = makeBattle({ A, B })
screen = makeScreen(battle, { noSendout = true })
local originalAdvance = screen.advanceQueue
startAndPush(battle, screen, "trainer")
check("unknown Gold intro is not modified", markerCount(screen), 0)
check("unknown Gold intro leaves advanceQueue untouched", screen.advanceQueue, originalAdvance)
check("unknown Gold intro reports seam_not_found", mod.exports.diagnostics().lastSkipReason, "seam_not_found")

battle = makeBattle({ A, B }, { turn = 1 })
screen = makeScreen(battle)
startAndPush(battle, screen, "trainer")
check("late Gold screen fails closed", markerCount(screen), 0)
check("late Gold screen reports battle_already_started", mod.exports.diagnostics().lastSkipReason,
  "battle_already_started")

-- --------------------------------------------------------- Amulet Coin A/B/C
local COIN = mon("MEOWTH", 25, { item = "AMULET_COIN", level = 10 })
local NOCOIN = mon("HOOTHOOT", 25, { level = 10 })

battle = makeBattle({ COIN, NOCOIN })
screen = makeScreen(battle)
startAndPush(battle, screen, "trainer")
picker = runToPicker(screen)
picker.opts.onChoose(2, NOCOIN)
check("slot1 Coin -> choose no Coin clears provisional latch", battle.amuletCoin, false)

battle = makeBattle({ NOCOIN, COIN })
screen = makeScreen(battle)
startAndPush(battle, screen, "trainer")
picker = runToPicker(screen)
picker.opts.onChoose(2, COIN)
check("slot1 no Coin -> choose Coin sets initial latch", battle.amuletCoin, true)

battle = makeBattle({ COIN, NOCOIN })
screen = makeScreen(battle)
startAndPush(battle, screen, "trainer")
picker = runToPicker(screen)
picker.opts.onCancel()
check("slot1 Coin -> cancel preserves vanilla latch", battle.amuletCoin, true)

battle = makeBattle({ NOCOIN, B, COIN })
screen = makeScreen(battle)
startAndPush(battle, screen, "trainer")
picker = runToPicker(screen)
picker.opts.onChoose(2, B)
check("chosen no-Coin lead begins with latch false", battle.amuletCoin, false)
battle:checkAmuletCoin(COIN) -- stand-in for a later genuine Gold send-out
check("later native Coin send-out can latch true", battle.amuletCoin, true)
battle:checkAmuletCoin(NOCOIN)
check("later no-Coin send-out never clears established latch", battle.amuletCoin, true)

-- ------------------------------------------------ free participant EXP guard
battle = makeBattle({ A, B })
screen = makeScreen(battle)
startAndPush(battle, screen, "trainer")
picker = runToPicker(screen)
picker.opts.onChoose(2, B)
check("selected slot is the only initial participant", battle.participants[2], true)
check("provisional slot gets no participant credit", battle.participants[1], nil)

-- ------------------------------------------------- no stale battle leakage
battle = makeBattle({ A, B })
screen = makeScreen(battle)
emit("battle.started", { battle = battle, kind = "trainer" })
emit("battle.ended", { battle = battle, result = "run" })
emit("screen.pushed", { state = screen })
check("battle.ended clears pending Gold eligibility", markerCount(screen), 0)

local battle1 = makeBattle({ A, B })
local screen1 = makeScreen(battle1)
startAndPush(battle1, screen1, "trainer")
check("first eligible battle attaches", markerCount(screen1), 1)
emit("battle.ended", { battle = battle1, result = "win" })
local battle2 = makeBattle({ A, B }, { wild = true })
local screen2 = makeScreen(battle2)
startAndPush(battle2, screen2, "wild")
check("following ineligible wild battle inherits nothing", markerCount(screen2), 0)
local battle3 = makeBattle({ A, B })
local screen3 = makeScreen(battle3)
startAndPush(battle3, screen3, "trainer")
check("third eligible battle starts cleanly", markerCount(screen3), 1)

-- --------------------------------------------------------- diagnostics/exports
local d = mod.exports.diagnostics()
check("diagnostics identify Gold backend", d.lastBackend, "gold")
check("diagnostics generation is 2", d.generation, 2)
truth("legacy applies export remains present on Gold", type(mod.exports.applies) == "function")
truth("legacy openPicker export remains present on Gold", type(mod.exports.openPicker) == "function")
truth("legacy findSeam export remains present on Gold", type(mod.exports.findSeam) == "function")
truth("Gold seam export is present", type(mod.exports.findGoldSeam) == "function")
truth("Gold legal-lead export is present", type(mod.exports.goldLegalLead) == "function")
check("Gold legal-lead rejects Egg", mod.exports.goldLegalLead(EGG), false)
check("Gold legal-lead rejects fainted", mod.exports.goldLegalLead(FAINTED), false)
check("Gold legal-lead accepts healthy mon", mod.exports.goldLegalLead(A), true)

print(failures == 0 and "\nall Gold checks passed"
                    or ("\n" .. failures .. " Gold check(s) failed"))
os.exit(failures == 0 and 0 or 1)
