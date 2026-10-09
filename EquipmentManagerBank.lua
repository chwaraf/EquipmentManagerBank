--[[
    EquipmentManagerBank (WoW Forever / Camelot / Modern Addon)
    Adds Outfitter-style bank options (Deposit/Withdraw) to the default Equipment Manager on right click.
--]]

EquipmentManagerBank = EquipmentManagerBank or {}
local EMB = EquipmentManagerBank

EMB.Title = "Equipment Manager Bank"
EMB.Version = "1.0.0"

-- Outfitter-style string definitions
EMB.Strings = {
    Bank = "Bank",
    DepositAll = "Deposit all items to bank",
    DepositUnique = "Deposit unique items to bank",
    WithdrawAll = "Withdraw items from bank",
    DepositOthers = "Deposit other sets to bank",
    WithdrawOthers = "Withdraw other sets from bank",
    EquipSet = "Equip Set",
    QuickBank = "Bank Options",
    BankClosed = "Requires Bank to be open",
    DepositFullError = "Can't deposit %s because all bank bags are full",
    WithdrawFullError = "Can't withdraw %s because all bags are full",
    MustBeAtBank = "You must have your bank open to use bank options",
    NoItemsToDeposit = "No items in set '%s' to deposit (already in bank or missing).",
    NoUniqueItems = "No unique items in set '%s' to deposit (shared by other sets).",
    AllItemsInBags = "All items for set '%s' are already in your inventory or equipped.",
    NoOtherItemsToDeposit = "No items from other sets found in bags to deposit.",
    NoOtherItemsToWithdraw = "No items for other sets found in bank to withdraw.",
    Depositing = "Depositing %d %s for '%s' to bank...",
    Withdrawing = "Withdrawing %d items for '%s' from bank...",
    DepositingOthers = "Depositing %d items from other sets to bank (preserving '%s')...",
    WithdrawingOthers = "Withdrawing %d items for other sets from bank...",
    TransferInterruptedBankClosed = "Bank was closed. Item transfers stopped.",
    TransferInterruptedCombat = "Entered combat. Item transfers stopped.",
}

-- Logging helper
local function PrintMessage(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[EquipmentBank]|r " .. tostring(msg))
    end
end

-------------------------------------------------------------------------------
-- Compatibility Layer: Container APIs & Locations
-------------------------------------------------------------------------------

local Container = {}
do
    local c = C_Container
    Container.GetNumSlots = function(bag)
        if c and c.GetContainerNumSlots then return c.GetContainerNumSlots(bag) end
        if GetContainerNumSlots then return GetContainerNumSlots(bag) end
        return 0
    end
    Container.GetItemID = function(bag, slot)
        if c and c.GetContainerItemID then return c.GetContainerItemID(bag, slot) end
        if GetContainerItemID then return GetContainerItemID(bag, slot) end
        return nil
    end
    Container.GetItemLink = function(bag, slot)
        if c and c.GetContainerItemLink then return c.GetContainerItemLink(bag, slot) end
        if GetContainerItemLink then return GetContainerItemLink(bag, slot) end
        return nil
    end
    Container.GetItemInfo = function(bag, slot)
        if c and c.GetContainerItemInfo then return c.GetContainerItemInfo(bag, slot) end
        if GetContainerItemInfo then
            local icon, count, locked, quality, readable, lootable, link = GetContainerItemInfo(bag, slot)
            if icon then
                return { iconFileID = icon, stackCount = count, isLocked = locked, quality = quality, hyperlink = link }
            end
        end
        return nil
    end
    Container.PickupItem = function(bag, slot)
        if c and c.PickupContainerItem then return c.PickupContainerItem(bag, slot) end
        if PickupContainerItem then return PickupContainerItem(bag, slot) end
    end
    Container.GetNumFreeSlots = function(bag)
        if c and c.GetContainerNumFreeSlots then return c.GetContainerNumFreeSlots(bag) end
        if GetContainerNumFreeSlots then return GetContainerNumFreeSlots(bag) end
        return 0, 0
    end
end
EMB.Container = Container

-- Unpack packed item location from C_EquipmentSet.GetItemLocations()
local function UnpackLocation(location)
    if not location or location <= 1 then
        return false, false, false, 0, 0, 0
    end

    if EquipmentManager_GetLocationData then
        local data = EquipmentManager_GetLocationData(location)
        if data and not TableIsEmpty(data) then
            local bankBag = data.isBags and data.bag or (BANK_CONTAINER or -1)
            return data.isPlayer or false, data.isBank or false, data.isBags or false, data.slot or 0, data.bag or 0, bankBag
        end
    end

    if EquipmentManager_UnpackLocation then
        local player, bank, bags, _, slot, bag = EquipmentManager_UnpackLocation(location)
        local bankBag = bags and bag or (BANK_CONTAINER or -1)
        return player or false, bank or false, bags or false, slot or 0, bag or 0, bankBag
    end

    -- Bitwise mask fallback (standard WoW retail/mainline bitmask)
    local isPlayer = bit.band(location, 0x00010000) ~= 0
    local isBank = bit.band(location, 0x00020000) ~= 0
    local isBags = bit.band(location, 0x00040000) ~= 0

    local slot = location
    if isPlayer then slot = slot - 0x00010000
    elseif isBank then slot = slot - 0x00020000 end

    local bag = 0
    if isBags then
        slot = slot - 0x00040000
        bag = bit.rshift(slot, 8)
        slot = slot - bit.lshift(bag, 8)
        if isBank then
            bag = bag + (ITEM_INVENTORY_BANK_BAG_OFFSET or 5)
        end
    end

    local bankBag = isBags and bag or (BANK_CONTAINER or -1)
    return isPlayer, isBank, isBags, slot, bag, bankBag
end
EMB.UnpackLocation = UnpackLocation

-------------------------------------------------------------------------------
-- Bank State Tracking & Bag Enumeration
-------------------------------------------------------------------------------

local isBankFrameOpen = false

local function IsBankOpen()
    if BankFrame and BankFrame:IsShown() then return true end
    if AccountBankPanel and AccountBankPanel:IsShown() then return true end
    return isBankFrameOpen
end
EMB.IsBankOpen = IsBankOpen

local function GetPlayerBags()
    local bags = { 0 }
    local maxBag = NUM_BAG_SLOTS or 4
    for b = 1, maxBag do
        local slots = Container.GetNumSlots(b)
        if slots and slots > 0 then
            table.insert(bags, b)
        end
    end
    return bags
end
EMB.GetPlayerBags = GetPlayerBags

local function GetBankBags()
    local bankBags = {}
    local seen = {}

    -- 1. Query C_Bank purchased tabs (Forever / Camelot Character tabs 6..14)
    if C_Bank and C_Bank.FetchPurchasedBankTabData and Enum and Enum.BankType and Enum.BankType.Character then
        local ok, tabs = pcall(C_Bank.FetchPurchasedBankTabData, Enum.BankType.Character)
        if ok and tabs then
            for _, tabData in ipairs(tabs) do
                local bagID = tabData.ID or tabData.bagID or (type(tabData) == "number" and tabData)
                if type(bagID) == "number" and not seen[bagID] then
                    local slots = Container.GetNumSlots(bagID)
                    if slots and slots > 0 then
                        seen[bagID] = true
                        table.insert(bankBags, bagID)
                    end
                end
            end
        end
    end

    -- 2. Classic/Wrath main bank container (-1 / BANK_CONTAINER)
    local mainBank = BANK_CONTAINER or (Enum and Enum.BagIndex and Enum.BagIndex.Bank) or -1
    local numSlots = Container.GetNumSlots(mainBank)
    if numSlots and numSlots > 0 and not seen[mainBank] then
        seen[mainBank] = true
        table.insert(bankBags, mainBank)
    end

    -- 3. Camelot / Modern CharacterBankTab IDs (bag IDs 6..14)
    for b = 6, 14 do
        if not seen[b] then
            local slots = Container.GetNumSlots(b)
            if slots and slots > 0 then
                seen[b] = true
                table.insert(bankBags, b)
            end
        end
    end

    -- 4. Classic equipped bank bags (usually bags 5..11)
    local startBag = (NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4) + 1
    local endBag = startBag + (NUM_BANKBAGSLOTS or 7)
    for b = startBag, endBag do
        if not seen[b] then
            local slots = Container.GetNumSlots(b)
            if slots and slots > 0 then
                seen[b] = true
                table.insert(bankBags, b)
            end
        end
    end

    return bankBags
end
EMB.GetBankBags = GetBankBags

-- Finds all available empty slots in the bank (general inventory bags only)
local function GetEmptyBankSlots()
    local emptySlots = {}
    local bankBags = GetBankBags()
    for _, bagID in ipairs(bankBags) do
        local numSlots = Container.GetNumSlots(bagID)
        if numSlots and numSlots > 0 then
            local _, bagType = Container.GetNumFreeSlots(bagID)
            -- Only use general bags (bagType 0 or nil), not profession/specialty bags
            if not bagType or bagType == 0 then
                for slot = 1, numSlots do
                    local itemID = Container.GetItemID(bagID, slot)
                    if not itemID then
                        local info = Container.GetItemInfo(bagID, slot)
                        if not (info and info.isLocked) then
                            table.insert(emptySlots, { bag = bagID, slot = slot })
                        end
                    end
                end
            end
        end
    end
    return emptySlots
end
EMB.GetEmptyBankSlots = GetEmptyBankSlots

-- Finds all available empty slots in player bags (general inventory only)
local function GetEmptyPlayerBagSlots()
    local emptySlots = {}
    local playerBags = GetPlayerBags()
    for _, bagID in ipairs(playerBags) do
        local numSlots = Container.GetNumSlots(bagID)
        if numSlots and numSlots > 0 then
            local _, bagType = Container.GetNumFreeSlots(bagID)
            if not bagType or bagType == 0 then
                for slot = 1, numSlots do
                    local itemID = Container.GetItemID(bagID, slot)
                    if not itemID then
                        local info = Container.GetItemInfo(bagID, slot)
                        if not (info and info.isLocked) then
                            table.insert(emptySlots, { bag = bagID, slot = slot })
                        end
                    end
                end
            end
        end
    end
    return emptySlots
end
EMB.GetEmptyPlayerBagSlots = GetEmptyPlayerBagSlots

-------------------------------------------------------------------------------
-- Equipment Set Discovery
-------------------------------------------------------------------------------

local function GetSetItems(setID)
    local items = {}
    if not (C_EquipmentSet and C_EquipmentSet.GetItemIDs) then
        return items
    end

    local itemIDs = C_EquipmentSet.GetItemIDs(setID)
    local locations = C_EquipmentSet.GetItemLocations and C_EquipmentSet.GetItemLocations(setID)
    if not itemIDs then return items end

    local usedBagSlots = {} -- prevent double-matching identical items to same physical slot

    for invSlot = 1, 19 do
        local itemID = itemIDs[invSlot]
        if itemID and itemID > 1 then
            local found = false
            local loc = locations and locations[invSlot]

            -- 1. Check packed location if valid
            if loc and loc > 1 then
                local isPlayer, isBank, isBags, slot, bag, bankBag = UnpackLocation(loc)
                if isPlayer then
                    table.insert(items, {
                        invSlot = invSlot,
                        itemID = itemID,
                        locationType = "player",
                        slot = invSlot,
                        link = GetInventoryItemLink("player", invSlot),
                    })
                    found = true
                elseif isBags and not isBank then
                    if bag and slot then
                        local actualID = Container.GetItemID(bag, slot)
                        if actualID == itemID then
                            usedBagSlots[bag .. ":" .. slot] = true
                            table.insert(items, {
                                invSlot = invSlot,
                                itemID = itemID,
                                locationType = "bag",
                                bag = bag,
                                slot = slot,
                                link = Container.GetItemLink(bag, slot),
                            })
                            found = true
                        end
                    end
                elseif isBank then
                    local targetBag = bankBag
                    if targetBag and slot then
                        local actualID = Container.GetItemID(targetBag, slot)
                        if actualID == itemID then
                            usedBagSlots[targetBag .. ":" .. slot] = true
                            table.insert(items, {
                                invSlot = invSlot,
                                itemID = itemID,
                                locationType = "bank",
                                bag = targetBag,
                                slot = slot,
                                link = Container.GetItemLink(targetBag, slot),
                            })
                            found = true
                        end
                    end
                end
            end

            -- 2. Fallback: Check equipped slot directly
            if not found then
                if GetInventoryItemID("player", invSlot) == itemID then
                    table.insert(items, {
                        invSlot = invSlot,
                        itemID = itemID,
                        locationType = "player",
                        slot = invSlot,
                        link = GetInventoryItemLink("player", invSlot),
                    })
                    found = true
                end
            end

            -- 3. Fallback: Scan player bags
            if not found then
                for _, b in ipairs(GetPlayerBags()) do
                    local nSlots = Container.GetNumSlots(b)
                    for s = 1, nSlots do
                        local key = b .. ":" .. s
                        if not usedBagSlots[key] and Container.GetItemID(b, s) == itemID then
                            usedBagSlots[key] = true
                            table.insert(items, {
                                invSlot = invSlot,
                                itemID = itemID,
                                locationType = "bag",
                                bag = b,
                                slot = s,
                                link = Container.GetItemLink(b, s),
                            })
                            found = true
                            break
                        end
                    end
                    if found then break end
                end
            end

            -- 4. Fallback: Scan bank containers if open
            if not found and IsBankOpen() then
                for _, b in ipairs(GetBankBags()) do
                    local nSlots = Container.GetNumSlots(b)
                    for s = 1, nSlots do
                        local key = b .. ":" .. s
                        if not usedBagSlots[key] and Container.GetItemID(b, s) == itemID then
                            usedBagSlots[key] = true
                            table.insert(items, {
                                invSlot = invSlot,
                                itemID = itemID,
                                locationType = "bank",
                                bag = b,
                                slot = s,
                                link = Container.GetItemLink(b, s),
                            })
                            found = true
                            break
                        end
                    end
                    if found then break end
                end
            end

            -- 5. Missing
            if not found then
                table.insert(items, {
                    invSlot = invSlot,
                    itemID = itemID,
                    locationType = "missing",
                })
            end
        end
    end

    return items
end
EMB.GetSetItems = GetSetItems

-------------------------------------------------------------------------------
-- Async Throttled Transfer Queue Engine
-------------------------------------------------------------------------------

local transferQueue = {}
local isTransferring = false
local transferTicker = nil

local function CancelTransfers(reason)
    if #transferQueue > 0 or isTransferring then
        transferQueue = {}
        isTransferring = false
        if transferTicker then
            transferTicker:Cancel()
            transferTicker = nil
        end
        ClearCursor()
        if reason then
            PrintMessage(reason)
        end
    end
end
EMB.CancelTransfers = CancelTransfers

local function ProcessNextTransfer()
    if #transferQueue == 0 then
        isTransferring = false
        if transferTicker then
            transferTicker:Cancel()
            transferTicker = nil
        end
        ClearCursor()
        return
    end

    if not IsBankOpen() then
        CancelTransfers(EMB.Strings.TransferInterruptedBankClosed)
        return
    end

    if UnitAffectingCombat("player") then
        CancelTransfers(EMB.Strings.TransferInterruptedCombat)
        return
    end

    local action = table.remove(transferQueue, 1)
    if not action then return end

    ClearCursor()

    if action.actionType == "BAG_TO_BANK" or action.actionType == "BANK_TO_BAG" then
        local currentID = Container.GetItemID(action.fromBag, action.fromSlot)
        if currentID then
            Container.PickupItem(action.fromBag, action.fromSlot)
            if CursorHasItem() then
                Container.PickupItem(action.toBag, action.toSlot)
                ClearCursor()
            end
        end
    elseif action.actionType == "EQUIP_TO_BANK" then
        PickupInventoryItem(action.invSlot)
        if CursorHasItem() then
            Container.PickupItem(action.toBag, action.toSlot)
            ClearCursor()
        end
    end
end

local function StartTransfers(actions, summaryMessage)
    if not actions or #actions == 0 then return end

    for _, act in ipairs(actions) do
        table.insert(transferQueue, act)
    end

    if summaryMessage then
        PrintMessage(summaryMessage)
    end

    if not isTransferring then
        isTransferring = true
        if C_Timer and C_Timer.NewTicker then
            transferTicker = C_Timer.NewTicker(0.08, ProcessNextTransfer)
        else
            -- Fallback loop using C_Timer.After
            local function RunNext()
                if isTransferring then
                    ProcessNextTransfer()
                    if isTransferring and #transferQueue > 0 then
                        C_Timer.After(0.08, RunNext)
                    end
                end
            end
            RunNext()
        end
    end
end

-------------------------------------------------------------------------------
-- Bank Operations (Outfitter parity)
-------------------------------------------------------------------------------

-- 1 & 2: Deposit set to bank (all items or unique items only)
function EMB.DepositSet(setID, uniqueOnly)
    if not IsBankOpen() then
        PrintMessage(EMB.Strings.MustBeAtBank)
        return
    end

    local setName = (C_EquipmentSet.GetEquipmentSetInfo and C_EquipmentSet.GetEquipmentSetInfo(setID)) or "Set"
    local items = GetSetItems(setID)

    local otherSetItemIDs = {}
    if uniqueOnly then
        local allSetIDs = C_EquipmentSet.GetEquipmentSetIDs()
        for _, otherID in ipairs(allSetIDs) do
            if otherID ~= setID then
                local oItems = C_EquipmentSet.GetItemIDs(otherID)
                if oItems then
                    for _, id in pairs(oItems) do
                        if id and id > 1 then
                            otherSetItemIDs[id] = true
                        end
                    end
                end
            end
        end
    end

    local toDeposit = {}
    for _, item in ipairs(items) do
        if uniqueOnly and otherSetItemIDs[item.itemID] then
            -- Skip items used in other sets
        else
            if item.locationType == "bag" then
                table.insert(toDeposit, {
                    actionType = "BAG_TO_BANK",
                    fromBag = item.bag,
                    fromSlot = item.slot,
                    itemID = item.itemID,
                    itemLink = item.link,
                })
            elseif item.locationType == "player" then
                table.insert(toDeposit, {
                    actionType = "EQUIP_TO_BANK",
                    invSlot = item.slot,
                    itemID = item.itemID,
                    itemLink = item.link,
                })
            end
        end
    end

    if #toDeposit == 0 then
        if uniqueOnly then
            PrintMessage(string.format(EMB.Strings.NoUniqueItems, setName))
        else
            PrintMessage(string.format(EMB.Strings.NoItemsToDeposit, setName))
        end
        return
    end

    local emptyBankSlots = GetEmptyBankSlots()
    if #emptyBankSlots < #toDeposit then
        PrintMessage(string.format("Can't deposit all items: only %d bank slots free, %d needed.", #emptyBankSlots, #toDeposit))
        while #toDeposit > #emptyBankSlots do
            table.remove(toDeposit)
        end
        if #toDeposit == 0 then return end
    end

    local actions = {}
    for i, item in ipairs(toDeposit) do
        local targetSlot = emptyBankSlots[i]
        item.toBag = targetSlot.bag
        item.toSlot = targetSlot.slot
        table.insert(actions, item)
    end

    local desc = uniqueOnly and "unique items" or "items"
    StartTransfers(actions, string.format(EMB.Strings.Depositing, #actions, desc, setName))
end

-- 3: Withdraw items for set from bank
function EMB.WithdrawSet(setID)
    if not IsBankOpen() then
        PrintMessage(EMB.Strings.MustBeAtBank)
        return
    end

    local setName = (C_EquipmentSet.GetEquipmentSetInfo and C_EquipmentSet.GetEquipmentSetInfo(setID)) or "Set"
    local items = GetSetItems(setID)

    local toWithdraw = {}
    for _, item in ipairs(items) do
        if item.locationType == "bank" then
            table.insert(toWithdraw, {
                actionType = "BANK_TO_BAG",
                fromBag = item.bag,
                fromSlot = item.slot,
                itemID = item.itemID,
                itemLink = item.link,
            })
        end
    end

    if #toWithdraw == 0 then
        PrintMessage(string.format(EMB.Strings.AllItemsInBags, setName))
        return
    end

    local emptyPlayerSlots = GetEmptyPlayerBagSlots()
    if #emptyPlayerSlots < #toWithdraw then
        PrintMessage(string.format("Can't withdraw all items: only %d bag slots free, %d needed.", #emptyPlayerSlots, #toWithdraw))
        while #toWithdraw > #emptyPlayerSlots do
            table.remove(toWithdraw)
        end
        if #toWithdraw == 0 then return end
    end

    local actions = {}
    for i, item in ipairs(toWithdraw) do
        local targetSlot = emptyPlayerSlots[i]
        item.toBag = targetSlot.bag
        item.toSlot = targetSlot.slot
        table.insert(actions, item)
    end

    StartTransfers(actions, string.format(EMB.Strings.Withdrawing, #actions, setName))
end

-- 4: Deposit other sets to bank
function EMB.DepositOtherSets(currentSetID)
    if not IsBankOpen() then
        PrintMessage(EMB.Strings.MustBeAtBank)
        return
    end

    local currentSetName = (C_EquipmentSet.GetEquipmentSetInfo and C_EquipmentSet.GetEquipmentSetInfo(currentSetID)) or "Current Set"

    -- Collect all item IDs used by current set to protect them
    local currentSetItemIDs = {}
    local currentItems = C_EquipmentSet.GetItemIDs(currentSetID)
    if currentItems then
        for _, id in pairs(currentItems) do
            if id and id > 1 then
                currentSetItemIDs[id] = true
            end
        end
    end

    -- Collect item IDs belonging to any other set
    local otherSetItemIDs = {}
    local allSetIDs = C_EquipmentSet.GetEquipmentSetIDs()
    for _, sID in ipairs(allSetIDs) do
        if sID ~= currentSetID then
            local items = C_EquipmentSet.GetItemIDs(sID)
            if items then
                for _, id in pairs(items) do
                    if id and id > 1 and not currentSetItemIDs[id] then
                        otherSetItemIDs[id] = true
                    end
                end
            end
        end
    end

    -- Scan player bags for these items
    local toDeposit = {}
    for _, bagID in ipairs(GetPlayerBags()) do
        local numSlots = Container.GetNumSlots(bagID)
        for slot = 1, numSlots do
            local itemID = Container.GetItemID(bagID, slot)
            if itemID and otherSetItemIDs[itemID] then
                local info = Container.GetItemInfo(bagID, slot)
                if not (info and info.isLocked) then
                    table.insert(toDeposit, {
                        actionType = "BAG_TO_BANK",
                        fromBag = bagID,
                        fromSlot = slot,
                        itemID = itemID,
                        itemLink = Container.GetItemLink(bagID, slot),
                    })
                end
            end
        end
    end

    if #toDeposit == 0 then
        PrintMessage(EMB.Strings.NoOtherItemsToDeposit)
        return
    end

    local emptyBankSlots = GetEmptyBankSlots()
    if #emptyBankSlots < #toDeposit then
        PrintMessage(string.format("Can't deposit all items: only %d bank slots free, %d needed.", #emptyBankSlots, #toDeposit))
        while #toDeposit > #emptyBankSlots do
            table.remove(toDeposit)
        end
        if #toDeposit == 0 then return end
    end

    local actions = {}
    for i, item in ipairs(toDeposit) do
        local targetSlot = emptyBankSlots[i]
        item.toBag = targetSlot.bag
        item.toSlot = targetSlot.slot
        table.insert(actions, item)
    end

    StartTransfers(actions, string.format(EMB.Strings.DepositingOthers, #actions, currentSetName))
end

-- 5: Withdraw other sets from bank
function EMB.WithdrawOtherSets(currentSetID)
    if not IsBankOpen() then
        PrintMessage(EMB.Strings.MustBeAtBank)
        return
    end

    local currentSetItemIDs = {}
    local currentItems = C_EquipmentSet.GetItemIDs(currentSetID)
    if currentItems then
        for _, id in pairs(currentItems) do
            if id and id > 1 then
                currentSetItemIDs[id] = true
            end
        end
    end

    local otherSetItemIDs = {}
    local allSetIDs = C_EquipmentSet.GetEquipmentSetIDs()
    for _, sID in ipairs(allSetIDs) do
        if sID ~= currentSetID then
            local items = C_EquipmentSet.GetItemIDs(sID)
            if items then
                for _, id in pairs(items) do
                    if id and id > 1 and not currentSetItemIDs[id] then
                        otherSetItemIDs[id] = true
                    end
                end
            end
        end
    end

    -- Scan bank containers for these items
    local toWithdraw = {}
    for _, bagID in ipairs(GetBankBags()) do
        local numSlots = Container.GetNumSlots(bagID)
        for slot = 1, numSlots do
            local itemID = Container.GetItemID(bagID, slot)
            if itemID and otherSetItemIDs[itemID] then
                local info = Container.GetItemInfo(bagID, slot)
                if not (info and info.isLocked) then
                    table.insert(toWithdraw, {
                        actionType = "BANK_TO_BAG",
                        fromBag = bagID,
                        fromSlot = slot,
                        itemID = itemID,
                        itemLink = Container.GetItemLink(bagID, slot),
                    })
                end
            end
        end
    end

    if #toWithdraw == 0 then
        PrintMessage(EMB.Strings.NoOtherItemsToWithdraw)
        return
    end

    local emptyPlayerSlots = GetEmptyPlayerBagSlots()
    if #emptyPlayerSlots < #toWithdraw then
        PrintMessage(string.format("Can't withdraw all items: only %d bag slots free, %d needed.", #emptyPlayerSlots, #toWithdraw))
        while #toWithdraw > #emptyPlayerSlots do
            table.remove(toWithdraw)
        end
        if #toWithdraw == 0 then return end
    end

    local actions = {}
    for i, item in ipairs(toWithdraw) do
        local targetSlot = emptyPlayerSlots[i]
        item.toBag = targetSlot.bag
        item.toSlot = targetSlot.slot
        table.insert(actions, item)
    end

    StartTransfers(actions, string.format(EMB.Strings.WithdrawingOthers, #actions))
end

-------------------------------------------------------------------------------
-- Context Menu Generation
-------------------------------------------------------------------------------

local dropdownFrame = nil

local function OpenContextMenu(anchorButton, setID)
    if not setID then return end
    local setName = (C_EquipmentSet.GetEquipmentSetInfo and C_EquipmentSet.GetEquipmentSetInfo(setID)) or ("Set #" .. tostring(setID))
    local bankOpen = IsBankOpen()

    -- Modern MenuUtil API (Mainline / WoW Forever / 11.0+)
    if MenuUtil and MenuUtil.CreateContextMenu then
        MenuUtil.CreateContextMenu(anchorButton, function(owner, rootDescription)
            rootDescription:CreateTitle(setName)

            rootDescription:CreateButton(EMB.Strings.EquipSet, function()
                if C_EquipmentSet and C_EquipmentSet.UseEquipmentSet then
                    C_EquipmentSet.UseEquipmentSet(setID)
                end
            end)

            rootDescription:CreateDivider()

            -- Outfitter-style "Bank" Submenu
            local bankSubmenu = rootDescription:CreateButton(EMB.Strings.Bank)
            if not bankOpen then
                bankSubmenu:SetEnabled(false)
                bankSubmenu:SetTooltip(function(tooltip)
                    GameTooltip_SetDefaultAnchor(tooltip, UIParent)
                    tooltip:SetText(EMB.Strings.BankClosed, 1, 0.2, 0.2)
                end)
            end

            bankSubmenu:CreateTitle(EMB.Strings.QuickBank)

            local btnDepAll = bankSubmenu:CreateButton(EMB.Strings.DepositAll, function()
                EMB.DepositSet(setID, false)
            end)
            if not bankOpen then btnDepAll:SetEnabled(false) end

            local btnDepUniq = bankSubmenu:CreateButton(EMB.Strings.DepositUnique, function()
                EMB.DepositSet(setID, true)
            end)
            if not bankOpen then btnDepUniq:SetEnabled(false) end

            local btnWthAll = bankSubmenu:CreateButton(EMB.Strings.WithdrawAll, function()
                EMB.WithdrawSet(setID)
            end)
            if not bankOpen then btnWthAll:SetEnabled(false) end

            bankSubmenu:CreateDivider()

            local btnDepOth = bankSubmenu:CreateButton(EMB.Strings.DepositOthers, function()
                EMB.DepositOtherSets(setID)
            end)
            if not bankOpen then btnDepOth:SetEnabled(false) end

            local btnWthOth = bankSubmenu:CreateButton(EMB.Strings.WithdrawOthers, function()
                EMB.WithdrawOtherSets(setID)
            end)
            if not bankOpen then btnWthOth:SetEnabled(false) end

            -- Direct 1-click bank buttons when bank is open
            if bankOpen then
                rootDescription:CreateDivider()
                rootDescription:CreateButton(EMB.Strings.DepositAll, function()
                    EMB.DepositSet(setID, false)
                end)
                rootDescription:CreateButton(EMB.Strings.WithdrawAll, function()
                    EMB.WithdrawSet(setID)
                end)
            end
        end)
        return
    end

    -- Classic / Fallback UIDropDownMenu API
    if not dropdownFrame then
        dropdownFrame = CreateFrame("Frame", "EquipmentManagerBankDropdown", UIParent, "UIDropDownMenuTemplate")
    end

    local menu = {
        { text = setName, isTitle = true, notCheckable = true },
        {
            text = EMB.Strings.EquipSet,
            notCheckable = true,
            func = function()
                if C_EquipmentSet and C_EquipmentSet.UseEquipmentSet then
                    C_EquipmentSet.UseEquipmentSet(setID)
                end
            end
        },
        { text = "", isTitle = true, notCheckable = true },
        {
            text = EMB.Strings.Bank,
            hasArrow = true,
            notCheckable = true,
            disabled = not bankOpen,
            menuList = {
                {
                    text = EMB.Strings.DepositAll,
                    notCheckable = true,
                    disabled = not bankOpen,
                    func = function() EMB.DepositSet(setID, false) end
                },
                {
                    text = EMB.Strings.DepositUnique,
                    notCheckable = true,
                    disabled = not bankOpen,
                    func = function() EMB.DepositSet(setID, true) end
                },
                {
                    text = EMB.Strings.WithdrawAll,
                    notCheckable = true,
                    disabled = not bankOpen,
                    func = function() EMB.WithdrawSet(setID) end
                },
                { text = "", isTitle = true, notCheckable = true },
                {
                    text = EMB.Strings.DepositOthers,
                    notCheckable = true,
                    disabled = not bankOpen,
                    func = function() EMB.DepositOtherSets(setID) end
                },
                {
                    text = EMB.Strings.WithdrawOthers,
                    notCheckable = true,
                    disabled = not bankOpen,
                    func = function() EMB.WithdrawOtherSets(setID) end
                },
            }
        }
    }

    if bankOpen then
        table.insert(menu, { text = "", isTitle = true, notCheckable = true })
        table.insert(menu, {
            text = EMB.Strings.DepositAll,
            notCheckable = true,
            func = function() EMB.DepositSet(setID, false) end
        })
        table.insert(menu, {
            text = EMB.Strings.WithdrawAll,
            notCheckable = true,
            func = function() EMB.WithdrawSet(setID) end
        })
    end

    EasyMenu(menu, dropdownFrame, "cursor", 0, 0, "MENU")
end
EMB.OpenContextMenu = OpenContextMenu

-------------------------------------------------------------------------------
-- Hooking the Default Equipment Manager
-------------------------------------------------------------------------------

local function RegisterButtonForRightClick(button)
    if not button then return end
    if not button._embRegistered then
        button._embRegistered = true
        button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    end
end

local function HookEquipmentManagerPane()
    local pane = (PaperDollFrame and PaperDollFrame.EquipmentManagerPane) or PaperDollEquipmentManagerPane

    -- Hook ScrollBox element initialization in modern UI
    if PaperDollEquipmentManagerPane_InitButton then
        hooksecurefunc("PaperDollEquipmentManagerPane_InitButton", function(button, elementData)
            if button then
                RegisterButtonForRightClick(button)
            end
        end)
    end

    -- Hook ScrollBox:ForEachFrame on update/show
    if pane and pane.ScrollBox and pane.ScrollBox.ForEachFrame then
        local function RefreshAllButtons()
            pane.ScrollBox:ForEachFrame(function(button)
                RegisterButtonForRightClick(button)
            end)
        end
        if PaperDollEquipmentManagerPane_Update then
            hooksecurefunc("PaperDollEquipmentManagerPane_Update", RefreshAllButtons)
        end
        if pane.HookScript then
            pane:HookScript("OnShow", RefreshAllButtons)
        end
        RefreshAllButtons()
    end

    -- Hook GearSetButton_OnClick for right click
    if GearSetButton_OnClick then
        hooksecurefunc("GearSetButton_OnClick", function(button, mouseButton)
            if mouseButton == "RightButton" and button then
                local setID = button.setID
                if not setID and button.name and C_EquipmentSet and C_EquipmentSet.GetEquipmentSetID then
                    setID = C_EquipmentSet.GetEquipmentSetID(button.name)
                end
                if setID then
                    OpenContextMenu(button, setID)
                end
            end
        end)
    end

    -- Support for ClassicUI / Wrath GearManagerDialog
    if GearManagerDialog then
        for i = 1, 10 do
            local btn = _G["GearSetButton" .. i]
            if btn then
                RegisterButtonForRightClick(btn)
                if not btn._embHooked then
                    btn._embHooked = true
                    btn:HookScript("OnClick", function(self, mouseButton)
                        if mouseButton == "RightButton" then
                            local sID = self.setID
                            if not sID and self.name and C_EquipmentSet and C_EquipmentSet.GetEquipmentSetID then
                                sID = C_EquipmentSet.GetEquipmentSetID(self.name)
                            end
                            if sID then
                                OpenContextMenu(self, sID)
                            end
                        end
                    end)
                end
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Event Handler & Slash Commands
-------------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame", "EquipmentManagerBankEventFrame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("BANKFRAME_OPENED")
eventFrame:RegisterEvent("BANKFRAME_CLOSED")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")

eventFrame:SetScript("OnEvent", function(self, event, arg1, ...)
    if event == "PLAYER_LOGIN" then
        HookEquipmentManagerPane()
    elseif event == "ADDON_LOADED" then
        if arg1 == "Blizzard_UIPanels_Game" or arg1 == "Blizzard_EquipmentManager" then
            HookEquipmentManagerPane()
        end
    elseif event == "BANKFRAME_OPENED" then
        isBankFrameOpen = true
    elseif event == "BANKFRAME_CLOSED" then
        isBankFrameOpen = false
        CancelTransfers(EMB.Strings.TransferInterruptedBankClosed)
    elseif event == "PLAYER_REGEN_DISABLED" then
        CancelTransfers(EMB.Strings.TransferInterruptedCombat)
    end
end)

-- Slash Command Handler
SLASH_EQUIPMENTMANAGERBANK1 = "/eqbank"
SLASH_EQUIPMENTMANAGERBANK2 = "/embank"
SlashCmdList["EQUIPMENTMANAGERBANK"] = function(msg)
    local cmd, arg = strsplit(" ", msg or "", 2)
    cmd = string.lower(strtrim(cmd or ""))
    arg = strtrim(arg or "")

    if cmd == "deposit" and arg ~= "" then
        local setID = C_EquipmentSet.GetEquipmentSetID(arg)
        if setID then
            EMB.DepositSet(setID, false)
        else
            PrintMessage("Equipment set '" .. arg .. "' not found.")
        end
    elseif cmd == "withdraw" and arg ~= "" then
        local setID = C_EquipmentSet.GetEquipmentSetID(arg)
        if setID then
            EMB.WithdrawSet(setID)
        else
            PrintMessage("Equipment set '" .. arg .. "' not found.")
        end
    elseif cmd == "help" then
        PrintMessage("Commands:")
        PrintMessage("  /eqbank - Toggle Character Frame Equipment Manager")
        PrintMessage("  /eqbank deposit <SetName> - Deposit all items for set into bank")
        PrintMessage("  /eqbank withdraw <SetName> - Withdraw all items for set from bank")
        PrintMessage("  Right-click any equipment set in Equipment Manager for Outfitter bank options.")
    else
        -- Default: open Equipment Manager
        if PaperDollFrame_SetSidebar and CharacterFrame then
            if not CharacterFrame:IsShown() then
                ShowUIPanel(CharacterFrame)
            end
            PaperDollFrame_SetSidebar(PaperDollFrame, 3)
        elseif ToggleCharacter then
            ToggleCharacter("PaperDollFrame")
        end
    end
end
