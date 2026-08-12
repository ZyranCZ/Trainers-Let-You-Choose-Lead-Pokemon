-- Choose Lead for Gen1Recomp
--
-- Red / Blue / Yellow keep the v1.0.1 backend and its original intro seam.
-- Pokemon Gold has a different battle architecture: its pure Battle object
-- emits battle.started before the BattleState screen and intro queue exist.
-- Gold therefore uses a two-stage adapter: battle.started only marks an
-- eligible battle, then screen.pushed attaches a per-instance queue marker
-- immediately before the native player send-out.
--
-- Choosing a lead is an INITIAL SEND-OUT, not a switch.  Neither backend
-- reorders the party or emits battle.battler_switched.

local TRAINERS, ALWAYS = "trainers", "always"

local WHEN_CHOICES = {
  { "TRAINERS", TRAINERS },
  { "ALL BATTLES", ALWAYS },
}

return function(mod)
  local GameVersion = require("src.core.GameVersion")
  local generation = GameVersion.generation()

  mod.options:define({
    { key = "enabled", label = "CHOOSE LEAD", type = "toggle", default = true },
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

  -- Deliberately scalar-only diagnostics: useful in bug reports without
  -- retaining or publishing entire battle / screen objects.
  local diag = {
    version = "2.0.0",
    generation = generation,
    enabled = enabled,
    when = when,
    lastContext = nil,
    lastEligible = nil,
    lastSkipReason = nil,
    lastBackend = generation == 2 and "gold" or "gen1",
    lastSeam = nil,
    lastSelectedIndex = nil,
  }

  local function updateDiag(fields)
    diag.enabled = enabled
    diag.when = when
    for key, value in pairs(fields or {}) do diag[key] = value end
  end

  mod.exports.diagnostics = function()
    local copy = {}
    for key, value in pairs(diag) do copy[key] = value end
    return copy
  end

  ---------------------------------------------------------------------- Gen 1
  -- Keep v1.0.1's backend isolated behind the generation branch.  Gold never
  -- requires BattleState.makeBattler or Timing.BATTLE_START_SENDOUT.
  local function installGen1()
    local BattleState = require("src.battle.BattleState")
    local Timing = require("src.core.Timing")

    local function healthy(mon)
      return mon and (mon.hp or 0) > 0
    end

    -- v1.0.1 contract: intentionally unchanged.
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

    -- v1.0.1 semantic seam: locate the native Go! row, then the nearest
    -- BATTLE_START_SENDOUT wait preceding it.  No fixed queue index.
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

    local function refuseFainted(battle, goRow)
      battle.nextInsert = 0
      battle:sayNext(battle:romText("_NoWillText", "There's no will\nto fight!"))
      battle:uiNext(function() return openPicker(battle, goRow) end)
    end

    local function sendOut(battle, mon, goRow)
      if not healthy(mon) then return refuseFainted(battle, goRow) end
      if mon == battle.player.mon then return end

      local vanillaLead = battle.player.mon
      if battle.participants then battle.participants[vanillaLead] = nil end

      battle.player = BattleState.makeBattler(battle.data, mon, true,
                                              battle.game.save)
      battle:syncSides()
      battle:markParticipant()
      goRow.text = battle:sendOutText(battle.player.name)
    end

    openPicker = function(battle, goRow)
      return battle:buildScreen("PartyMenu", {
        battle = battle,
        forceSwitch = true,
        onSwitch = function(mon) sendOut(battle, mon, goRow) end,
      })
    end

    mod.events:on("battle.started", function(payload)
      local battle = payload and payload.battle
      local eligible = applies(battle)
      updateDiag({
        lastContext = payload and payload.kind or (battle and battle.kind),
        lastEligible = eligible,
        lastSkipReason = eligible and nil or "ineligible",
        lastBackend = "gen1",
      })
      if not eligible then return end

      local insertAt, goRow = findSeam(battle)
      if not insertAt then
        updateDiag({ lastSkipReason = "seam_not_found", lastSeam = nil })
        mod.log:warn("could not find the send-out seam; leaving the intro alone")
        return
      end

      updateDiag({ lastSeam = "gen1_sendout_wait", lastSkipReason = nil })
      table.insert(battle.queue, insertAt,
                   { ui = function() return openPicker(battle, goRow) end })
    end)

    mod.exports.applies = applies
    mod.exports.openPicker = function(battle, goRow)
      return openPicker(battle, goRow)
    end
    mod.exports.findSeam = findSeam
  end

  ----------------------------------------------------------------------- Gold
  local function installGold()
    local Screens = require("src.ui.Screens")

    -- Weak keys ensure an interrupted screen construction cannot retain a
    -- battle forever.  battle.ended still clears eagerly on the normal path.
    local pending = setmetatable({}, { __mode = "k" })
    local attached = setmetatable({}, { __mode = "k" })

    local MARKER_KIND = "choose-lead"
    local MARKER_OWNER = "choose_lead"
    local TEXT_NO_WILL = "There's no will to battle!"
    local TEXT_EGG = "An EGG can't battle!"

    local function legalLead(mon)
      return mon and not mon.isEgg and (mon.hp or 0) > 0
    end

    local function countLegal(party)
      local count = 0
      for _, mon in ipairs(party or {}) do
        if legalLead(mon) then count = count + 1 end
      end
      return count
    end

    local function kindOf(payload, battle)
      if payload and payload.kind then return payload.kind end
      if battle and battle.wild ~= nil then
        return battle.wild and "wild" or "trainer"
      end
      return battle and battle.kind or nil
    end

    -- battle.started can classify policy and party legality, but tutorial and
    -- Bug Contest flags are presentation context in current Gold and only
    -- become visible on the matching Gen2BattleState.  Those are re-checked
    -- at screen.pushed before any queue mutation.
    local function goldAppliesPayload(payload)
      local battle = payload and payload.battle
      if not enabled then return false, "disabled" end
      if not battle then return false, "battle_missing" end
      local kind = kindOf(payload, battle)
      if kind == "link" or battle.link then return false, "link" end
      if kind ~= "trainer" and when ~= ALWAYS then return false, "wild_default" end
      if type(battle.party) ~= "table" then return false, "party_missing" end
      if countLegal(battle.party) < 2 then return false, "single_usable" end
      return true, nil
    end

    local function makeMarker()
      return { kind = MARKER_KIND, owner = MARKER_OWNER,
               chooseLeadMarker = true }
    end

    local function isMarker(row)
      return type(row) == "table"
        and row.kind == MARKER_KIND
        and row.owner == MARKER_OWNER
        and row.chooseLeadMarker == true
    end

    local function findGoldSeam(screen)
      local queue = screen and screen.queue
      if type(queue) ~= "table" then return nil end
      for index, row in ipairs(queue) do
        if type(row) == "table" and row.kind == "sendout" then
          return index, row
        end
      end
      return nil
    end

    local function indexOf(party, mon)
      for index, candidate in ipairs(party or {}) do
        if candidate == mon then return index end
      end
      return nil
    end

    local function preflightCommit(screen, index, mon, sendoutRow)
      local battle = screen and screen.battle
      if not (battle and type(battle.party) == "table") then
        return false, "battle_missing"
      end
      if battle.party[index] ~= mon then return false, "party_identity_changed" end
      if type(battle.syncSides) ~= "function" then return false, "sync_sides_missing" end
      if type(battle.checkAmuletCoin) ~= "function" then
        return false, "amulet_helper_missing"
      end
      if type(screen.name) ~= "function" then return false, "name_helper_missing" end
      if type(screen.expPixels) ~= "function" then return false, "exp_helper_missing" end
      if type(sendoutRow) ~= "table" or sendoutRow.kind ~= "sendout" then
        return false, "sendout_changed"
      end
      local oldIndex = battle.playerIndex or indexOf(battle.party, battle.player)
      if not oldIndex then return false, "old_index_missing" end
      return true, oldIndex
    end

    -- Rebind only the provisional pre-sendout identity.  Do NOT use
    -- Battle:switch(): that would clear volatiles/stages, trigger switch hooks,
    -- hazards/traps and create an ordinary send event.
    local function commitInitialLead(screen, ctx, index, mon)
      local battle = screen.battle
      local sendoutRow = ctx.sendoutRow
      if battle.player == mon and battle.playerIndex == index then
        updateDiag({ lastSelectedIndex = index })
        return true
      end

      local ok, oldIndexOrReason = preflightCommit(screen, index, mon, sendoutRow)
      if not ok then
        updateDiag({ lastSkipReason = oldIndexOrReason })
        mod.log:warn("Gold lead selection left unchanged: " .. tostring(oldIndexOrReason))
        return false
      end
      local oldIndex = oldIndexOrReason

      -- Nothing should have advanced a turn before the initial send-out.  A
      -- nonzero turn means the seam moved and guessing here would be unsafe.
      if battle.turn and battle.turn ~= 0 then
        updateDiag({ lastSkipReason = "late_commit" })
        mod.log:warn("Gold lead selection arrived after turn start; keeping vanilla lead")
        return false
      end

      battle.participants = battle.participants or {}
      battle.participants[oldIndex] = nil
      battle.playerIndex = index
      battle.player = mon
      battle.participants[index] = true
      battle:syncSides()

      -- Battle.new already checked the provisional leader.  Before the FIRST
      -- real send-out it is safe and necessary to replace only that provisional
      -- latch.  Future genuine send-outs use Gold's native one-way latch.
      battle.amuletCoin = false
      battle:checkAmuletCoin(mon)

      screen.shownMon = screen.shownMon or {}
      screen.shownMon.player = mon
      screen.shownHp = screen.shownHp or {}
      screen.shownHp.player = mon.hp or 0
      screen.shownLevel = mon.level or 1
      screen.shownExp = screen:expPixels(mon, mon.level, mon.experience)
      if screen.hpAnim and screen.hpAnim.side == "player" then screen.hpAnim = nil end
      screen.expAnim = nil

      -- Reuse Gold's own naming helper; do not invent a nickname formatter.
      sendoutRow.text = "Go! " .. screen:name(mon) .. "!"
      updateDiag({ lastSelectedIndex = index, lastSkipReason = nil })
      return true
    end

    local openGoldPicker

    local function resumeAfterPicker(screen, ctx)
      screen.phase = ctx.resumePhase or "intro"
      return screen:advanceQueue()
    end

    local function closePicker(ctx)
      local stack = ctx.game and ctx.game.stack
      if not stack then return end
      if type(stack.top) == "function" and stack:top() ~= ctx.picker then return end
      if type(stack.pop) == "function" then stack:pop() end
    end

    local function repromptInvalid(screen, ctx, text)
      closePicker(ctx)
      -- Native-style queue flow: message first, then our marker, then the
      -- untouched native player sendout that was already behind it.
      table.insert(screen.queue, 1, makeMarker())
      table.insert(screen.queue, 1, { kind = "message", text = text })
      screen.phase = ctx.resumePhase or "intro"
      return screen:advanceQueue()
    end

    openGoldPicker = function(screen, ctx)
      local battle = screen and screen.battle
      local game = (screen and screen.game) or mod.game
      local stack = game and game.stack
      if not (battle and game and stack) then
        updateDiag({ lastSkipReason = "picker_stack_missing" })
        mod.log:warn("Gold party picker could not open; keeping vanilla lead")
        return resumeAfterPicker(screen, ctx)
      end

      ctx.game = game
      ctx.resumePhase = screen.phase or ctx.resumePhase or "intro"
      screen.phase = "submenu"

      local picker
      picker = Screens.push(game, "Gen2PartyMenu", {
        party = battle.party,
        prompt = "choose",
        -- submenu/battleSubmenu intentionally omitted: A answers directly.
        onCancel = function()
          ctx.picker = picker
          closePicker(ctx)
          updateDiag({ lastSelectedIndex = nil, lastSkipReason = nil })
          return resumeAfterPicker(screen, ctx)
        end,
        onChoose = function(index, mon)
          ctx.picker = picker
          if not mon or battle.party[index] ~= mon then
            closePicker(ctx)
            updateDiag({ lastSkipReason = "invalid_party_slot" })
            return resumeAfterPicker(screen, ctx)
          end
          if mon.isEgg then
            return repromptInvalid(screen, ctx, TEXT_EGG)
          end
          if (mon.hp or 0) <= 0 then
            return repromptInvalid(screen, ctx, TEXT_NO_WILL)
          end

          local committed = commitInitialLead(screen, ctx, index, mon)
          closePicker(ctx)
          if not committed then
            -- Fail closed: the native provisional leader and sendout survive.
            return resumeAfterPicker(screen, ctx)
          end
          return resumeAfterPicker(screen, ctx)
        end,
      })
      ctx.picker = picker
      return picker
    end

    local function attachGoldScreen(screen, ctx)
      if attached[screen] or screen.__chooseLeadAttached then return true end
      if screen.tutorial then return false, "tutorial" end
      if screen.contest then return false, "bug_contest" end
      if screen.battle ~= ctx.battle then return false, "battle_mismatch" end
      if screen.phase and screen.phase ~= "intro" then return false, "screen_not_intro" end
      if ctx.battle.turn and ctx.battle.turn ~= 0 then return false, "battle_already_started" end

      local index, sendoutRow = findGoldSeam(screen)
      if not index then return false, "seam_not_found" end

      local originalAdvance = screen.advanceQueue
      if type(originalAdvance) ~= "function" then return false, "advance_missing" end

      ctx.screen = screen
      ctx.sendoutRow = sendoutRow
      ctx.originalAdvance = originalAdvance
      table.insert(screen.queue, index, makeMarker())

      -- Patch this one eligible screen only.  Peeking avoids teaching the
      -- engine's global advanceQueue about a mod-owned event kind.
      screen.advanceQueue = function(self, ...)
        local row = self.queue and self.queue[1]
        if isMarker(row) then
          table.remove(self.queue, 1)
          return openGoldPicker(self, ctx)
        end
        return originalAdvance(self, ...)
      end

      attached[screen] = true
      screen.__chooseLeadAttached = true
      updateDiag({ lastSeam = "gold_sendout_marker", lastSkipReason = nil })
      return true
    end

    mod.events:on("battle.started", function(payload)
      local battle = payload and payload.battle
      local eligible, reason = goldAppliesPayload(payload)
      updateDiag({
        lastContext = kindOf(payload, battle),
        lastEligible = eligible,
        lastSkipReason = reason,
        lastBackend = "gold",
        lastSeam = nil,
        lastSelectedIndex = nil,
      })
      if not eligible then return end
      pending[battle] = {
        battle = battle,
        kind = kindOf(payload, battle),
        battleType = payload and payload.battleType,
      }
    end)

    mod.events:on("screen.pushed", function(payload)
      local screen = payload and payload.state
      local battle = screen and screen.battle
      local ctx = battle and pending[battle]
      if not ctx then return end

      -- The matching battle identity is the authoritative screen seam.  Do not
      -- reject a compatible mod-owned replacement merely because it carries a
      -- different screenId; attachGoldScreen validates the actual capabilities
      -- (intro phase, queue, sendout row and advanceQueue) and fails closed.
      if screen.battle ~= battle then return end

      if screen.tutorial then
        pending[battle] = nil
        updateDiag({ lastEligible = false, lastSkipReason = "tutorial" })
        return
      end
      if screen.contest then
        pending[battle] = nil
        updateDiag({ lastEligible = false, lastSkipReason = "bug_contest" })
        return
      end

      local ok, reason = attachGoldScreen(screen, ctx)
      pending[battle] = nil
      if not ok then
        updateDiag({ lastSkipReason = reason, lastSeam = nil })
        mod.log:warn("Gold choose-lead seam unavailable (" .. tostring(reason)
          .. "); leaving vanilla lead untouched")
      end
    end)

    mod.events:on("battle.ended", function(payload)
      local battle = payload and payload.battle
      if battle then pending[battle] = nil end
    end)

    -- Keep legacy export names present.  Their Gen 1 signatures remain exactly
    -- the v1.0.1 contract on Gen 1; Gold exposes explicit peers instead of
    -- pretending Timing/makeBattler have a Gold meaning.
    mod.exports.applies = function(battle)
      local payload = { battle = battle,
        kind = battle and (battle.wild and "wild" or "trainer") }
      return goldAppliesPayload(payload)
    end
    mod.exports.findSeam = function() return nil end
    mod.exports.openPicker = function() return nil end
    mod.exports.findGoldSeam = findGoldSeam
    mod.exports.openPickerGold = function(screen)
      if not screen or not screen.battle then return nil end
      local index, sendoutRow = findGoldSeam(screen)
      if not index then return nil end
      local ctx = { battle = screen.battle, screen = screen, sendoutRow = sendoutRow }
      return openGoldPicker(screen, ctx)
    end
    mod.exports.goldLegalLead = legalLead
  end

  if generation == 2 then
    installGold()
  else
    installGen1()
  end
end
