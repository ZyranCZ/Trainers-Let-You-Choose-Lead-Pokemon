-- Choose Lead for Gen1Recomp
--
-- Gen 1 sends out party slot 1 and gives you no say.  The usual answer is
-- to park your strongest Pokémon in slot 1 permanently, which quietly
-- removes the matchup decision from the game.  This asks which Pokémon to
-- send out once the opposing one is on screen, so the choice is made with
-- the information a trainer would actually have.
--
-- WHERE IT SLOTS IN
--
-- BattleState:enter builds the whole intro as a queue of rows and only
-- then emits battle.started -- the rows exist but none has run yet.  So a
-- listener can insert a row into that queue before a single frame of the
-- intro is drawn, which is the seam this mod uses.  No hook, no wrapping,
-- and the engine's own sequencing is left intact.
--
-- The row goes in at the BATTLE_START_SENDOUT wait, which core.asm pays
-- between the opponent appearing and the player's send-out.  That puts the
-- picker exactly where the decision belongs: the foe is on screen, Red has
-- not thrown yet.
--
-- WHAT THE PICKER CHANGES
--
-- Only which battler is active.  The party is NOT reordered, matching a
-- mid-battle switch -- slot 1 stays slot 1, so nothing about the save
-- changes and the mod can be removed at any time.
--
-- "Go! X!" is baked into a queue row when enter builds it, so picking a
-- different Pokémon has to rewrite that row.  It is captured up front by
-- matching the text the engine would have printed, and rewritten in place
-- after a pick.  markParticipant is re-run too, or the EXP share would
-- credit the mon that never came out.
--
-- battle.battler_switched is deliberately NOT emitted: this is the initial
-- send-out, which vanilla does not emit either, and a mod listening for
-- switch-ins (an Intimidate implementation, say) should not see a switch
-- that did not happen.
--
-- WHERE IT STAYS OUT
--
-- Link battles: both sides send out together, and seeing the opponent
-- before choosing would be neither fair nor in step with the other client.
-- The Safari Zone has no player battler at all, and the old man's demo
-- drives its own menu.
--
-- Fewer than two healthy Pokémon means there is nothing to decide, so the
-- prompt does not appear -- an empty question every time you leave town
-- with one Pokémon would be worse than no mod.

local TRAINERS, ALWAYS = "trainers", "always"

local WHEN_CHOICES = {
  { "TRAINERS", TRAINERS },
  { "ALL BATTLES", ALWAYS },
}

return function(mod)
  local BattleState = require("src.battle.BattleState")
  local Timing = require("src.core.Timing")

  mod.options:define({
    { key = "enabled", label = "CHOOSE LEAD", type = "toggle", default = true },
    -- Wild encounters are frequent and mostly one-sided, so asking every
    -- time turns a decision into a chore.  Trainer battles are where the
    -- matchup actually matters, and they are the default.
    { key = "when", label = "ASK BEFORE", type = "choice",
      default = TRAINERS, choices = WHEN_CHOICES },
  })

  local enabled, when

  local function readOptions()
    enabled = mod.options:get("enabled") and true or false
    when = mod.options:get("when") == ALWAYS and ALWAYS or TRAINERS
  end

  readOptions()
  mod.events:on("mod.options_changed", function(payload)
    if payload and payload.mod == "choose_lead" then readOptions() end
  end)

  local function healthy(mon)
    return mon and (mon.hp or 0) > 0
  end

  -- Whether this battle gets a picker at all.
  local function applies(battle)
    if not enabled or not battle then return false end
    if battle.safari or battle.demo then return false end
    if battle.kind == "link" then return false end
    if battle.kind ~= "trainer" and when ~= ALWAYS then return false end

    local party = battle.game and battle.game.save and battle.game.save.party
    if not party then return false end
    local usable = 0
    for _, mon in ipairs(party) do
      if healthy(mon) then usable = usable + 1 end
    end
    return usable >= 2
  end

  -- The queue row that prints "Go! X!", and the row the picker goes before.
  -- enter() appends the send-out block after a BATTLE_START_SENDOUT wait, so
  -- the wait nearest before that text is the seam.  Both are located by
  -- content rather than by a counted offset, so an extra row added to the
  -- intro by the engine or another mod does not shift the insert onto the
  -- wrong step.
  local function findSeam(battle)
    local queue = battle.queue
    if type(queue) ~= "table" then return nil end

    local goText = battle:sendOutText(battle.player.name)
    local goIndex
    for i = #queue, 1, -1 do
      if queue[i].text == goText then goIndex = i; break end
    end
    if not goIndex then return nil end

    local insertAt = goIndex
    for i = goIndex - 1, 1, -1 do
      if queue[i].wait == Timing.BATTLE_START_SENDOUT then
        insertAt = i
        break
      end
    end
    return insertAt, queue[goIndex]
  end

  local openPicker

  -- A fainted pick gets the refusal the engine gives for a mid-battle
  -- switch, then the picker back -- openReplacementMenu's own answer, minus
  -- its trailing `return`, because that relies on the menu-phase guard
  -- reopening the menu when the player has no mon out.  Here the vanilla
  -- lead is alive and no guard fires, so the reopen is explicit.
  --
  -- ui rows do not reset nextInsert (only fn rows do), so it is zeroed
  -- first, exactly as openReplacementMenu zeroes it.  The queue is consumed
  -- from the front, so the message lands at index 1 and the picker at 2 --
  -- immediately after the row that is running now.
  local function refuseFainted(battle, goRow)
    battle.nextInsert = 0
    battle:sayNext(battle:romText("_NoWillText", "There's no will\nto fight!"))
    battle:uiNext(function() return openPicker(battle, goRow) end)
  end

  local function sendOut(battle, mon, goRow)
    if not healthy(mon) then return refuseFainted(battle, goRow) end
    if mon == battle.player.mon then return end

    -- markParticipant ADDS to self.participants and never removes, and
    -- enter() already ran it for the vanilla lead while building the intro.
    -- Marking the new one on top would leave both in the set, so the mon
    -- that never came out would still collect exp from the kill -- a free
    -- level in every battle you switch at.  Nothing has happened yet, so
    -- the outgoing lead can simply be struck off.
    local vanillaLead = battle.player.mon
    if battle.participants then battle.participants[vanillaLead] = nil end

    battle.player = BattleState.makeBattler(battle.data, mon, true,
                                            battle.game.save)
    battle:syncSides()
    -- the exp share follows whoever actually came out
    battle:markParticipant()
    -- the greeting was written for the old lead
    goRow.text = battle:sendOutText(battle.player.name)
  end

  -- forceSwitch is ChooseNextMon's shape: A picks immediately, with no
  -- SWITCH/STATS submenu in the way.  B still closes the menu (PartyMenu's
  -- own b branch), which keeps the vanilla lead -- as does picking that
  -- lead deliberately, so there is no dead end either way.
  openPicker = function(battle, goRow)
    return battle:buildScreen("PartyMenu", {
      battle = battle,
      forceSwitch = true,
      onSwitch = function(mon) sendOut(battle, mon, goRow) end,
    })
  end

  mod.events:on("battle.started", function(payload)
    local battle = payload and payload.battle
    if not applies(battle) then return end

    local insertAt, goRow = findSeam(battle)
    if not insertAt then
      mod.log:warn("could not find the send-out seam; leaving the intro alone")
      return
    end

    table.insert(battle.queue, insertAt,
                 { ui = function() return openPicker(battle, goRow) end })
  end)

  mod.exports.applies = applies
  mod.exports.openPicker = function(battle, goRow)
    return openPicker(battle, goRow)
  end
  mod.exports.findSeam = findSeam
end
