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
    EquipSet = "Equip",
    Deposit = "Deposit",
    Withdraw = "Withdraw",
    DepositUnique = "Deposit Unique",
    WithdrawUnique = "Withdraw Unique",
    DepositOther = "Deposit Other",
    WithdrawOther = "Withdraw Other",
    DepositAll = "Deposit All",
    TooltipEquip = "Left-click: Equip this set.",
    TooltipManagerRightClick = "Right-click: Open set and bank options.",
    TooltipBankRequired = "Bank actions are available only while a bank is open.",
    TooltipActionBarRightClick = "At the bank, right-click: Withdraw this set if banked; otherwise deposit unique items from bags.",
    TooltipActionBarModifiedRightClick = "At the bank, Ctrl+Shift+right-click: Transfer other-set items (withdraw if banked; otherwise deposit from bags).",
    WithdrawAll = "Withdraw All",
    DepositFullError = "Can't deposit %s because all bank bags are full",
    WithdrawFullError = "Can't withdraw %s because all bags are full",
    MustBeAtBank = "You must have your bank open to use bank options",
    NoItemsToDeposit = "No items in set '%s' to deposit.",
    NoUniqueItems = "No unique items in set '%s' to deposit.",
    NoUniqueBagItems = "No unique items in the bags for set '%s' to deposit.",
    NoItemsToWithdraw = "No items in set '%s' found in the bank.",
    NoUniqueItemsToWithdraw = "No unique items in set '%s' found in the bank.",
    NoOtherSetItems = "No items for other sets found in the bank or your bags.",
    Depositing = "Depositing %d %s for '%s' to bank...",
    Withdrawing = "Withdrawing %d %s for '%s' from bank...",
    DepositingOtherSets = "Depositing %d items for other sets to bank...",
    WithdrawingOtherSets = "Withdrawing %d items for other sets from bank...",
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
                if isBank then
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
                elseif isBags then
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
                elseif isPlayer then
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

            -- 3. Fallback: Scan bank containers first when open
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

            -- 4. Fallback: Scan player bags
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

-- Returns item IDs used by a set, keyed by ID for quick membership checks.
local function GetSetItemIDSet(setID)
    local itemIDs = {}
    if C_EquipmentSet and C_EquipmentSet.GetItemIDs then
        local setItems = C_EquipmentSet.GetItemIDs(setID)
        if setItems then
            for _, itemID in pairs(setItems) do
                if itemID and itemID > 1 then
                    itemIDs[itemID] = true
                end
            end
        end
    end
    return itemIDs
end

-- Returns item IDs used by any equipment set other than setID.
local function GetOtherSetItemIDs(setID)
    local itemIDs = {}
    if not (C_EquipmentSet and C_EquipmentSet.GetEquipmentSetIDs and C_EquipmentSet.GetItemIDs) then
        return itemIDs
    end

    local setIDs = C_EquipmentSet.GetEquipmentSetIDs() or {}
    for _, otherID in ipairs(setIDs) do
        if otherID ~= setID then
            local otherItems = C_EquipmentSet.GetItemIDs(otherID)
            if otherItems then
                for _, itemID in pairs(otherItems) do
                    if itemID and itemID > 1 then
                        itemIDs[itemID] = true
                    end
                end
            end
        end
    end
    return itemIDs
end

-- Returns IDs used by other sets but not by the set whose icon was clicked.
local function GetOtherSetOnlyItemIDs(setID)
    local itemIDs = GetOtherSetItemIDs(setID)
    local currentSetItemIDs = GetSetItemIDSet(setID)
    for itemID in pairs(currentSetItemIDs) do
        itemIDs[itemID] = nil
    end
    return itemIDs
end

-- Returns the union of item IDs used by every equipment set.
local function GetAllSetItemIDs()
    local itemIDs = {}
    if not (C_EquipmentSet and C_EquipmentSet.GetEquipmentSetIDs and C_EquipmentSet.GetItemIDs) then
        return itemIDs
    end

    for _, setID in ipairs(C_EquipmentSet.GetEquipmentSetIDs() or {}) do
        local setItems = GetSetItemIDSet(setID)
        for itemID in pairs(setItems) do
            itemIDs[itemID] = true
        end
    end
    return itemIDs
end

-- Deposit this set's items from equipped slots and player bags.
function EMB.DepositSet(setID, uniqueOnly)
    if not IsBankOpen() then
        PrintMessage(EMB.Strings.MustBeAtBank)
        return
    end

    local setName = (C_EquipmentSet.GetEquipmentSetInfo and C_EquipmentSet.GetEquipmentSetInfo(setID)) or "Set"
    local items = GetSetItems(setID)
    local otherSetItemIDs = uniqueOnly and GetOtherSetItemIDs(setID) or {}

    local toDeposit = {}
    for _, item in ipairs(items) do
        local isUnique = not otherSetItemIDs[item.itemID]
        if not uniqueOnly or isUnique then
            if item.locationType == "player"
                and GetInventoryItemID("player", item.slot) == item.itemID then
                table.insert(toDeposit, {
                    actionType = "EQUIP_TO_BANK",
                    invSlot = item.slot,
                    itemID = item.itemID,
                    itemLink = item.link,
                })
            elseif item.locationType == "bag"
                and Container.GetItemID(item.bag, item.slot) == item.itemID then
                local info = Container.GetItemInfo(item.bag, item.slot)
                if not (info and info.isLocked) then
                    table.insert(toDeposit, {
                        actionType = "BAG_TO_BANK",
                        fromBag = item.bag,
                        fromSlot = item.slot,
                        itemID = item.itemID,
                        itemLink = item.link,
                    })
                end
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

-- Action-bar smart banking deposits unique bagged items when the set has no banked pieces.
function EMB.DepositUniqueBagItems(setID)
    if not IsBankOpen() then
        PrintMessage(EMB.Strings.MustBeAtBank)
        return
    end

    local setName = (C_EquipmentSet.GetEquipmentSetInfo and C_EquipmentSet.GetEquipmentSetInfo(setID)) or "Set"
    local items = GetSetItems(setID)
    local otherSetItemIDs = GetOtherSetItemIDs(setID)
    local toDeposit = {}

    for _, item in ipairs(items) do
        if item.locationType == "bag"
            and not otherSetItemIDs[item.itemID]
            and Container.GetItemID(item.bag, item.slot) == item.itemID then
            local info = Container.GetItemInfo(item.bag, item.slot)
            if not (info and info.isLocked) then
                table.insert(toDeposit, {
                    actionType = "BAG_TO_BANK",
                    fromBag = item.bag,
                    fromSlot = item.slot,
                    itemID = item.itemID,
                    itemLink = item.link,
                })
            end
        end
    end

    if #toDeposit == 0 then
        PrintMessage(string.format(EMB.Strings.NoUniqueBagItems, setName))
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

    StartTransfers(actions, string.format(EMB.Strings.Depositing, #actions, "unique items", setName))
end

-- Withdraw items for this set from the bank. With uniqueOnly, leave shared items alone.
function EMB.WithdrawSet(setID, uniqueOnly)
    if not IsBankOpen() then
        PrintMessage(EMB.Strings.MustBeAtBank)
        return
    end

    local setName = (C_EquipmentSet.GetEquipmentSetInfo and C_EquipmentSet.GetEquipmentSetInfo(setID)) or "Set"
    local items = GetSetItems(setID)
    local otherSetItemIDs = uniqueOnly and GetOtherSetItemIDs(setID) or {}

    local toWithdraw = {}
    for _, item in ipairs(items) do
        if item.locationType == "bank" and (not uniqueOnly or not otherSetItemIDs[item.itemID]) then
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
        local message = uniqueOnly and EMB.Strings.NoUniqueItemsToWithdraw or EMB.Strings.NoItemsToWithdraw
        PrintMessage(string.format(message, setName))
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

    local desc = uniqueOnly and "unique items" or "items"
    StartTransfers(actions, string.format(EMB.Strings.Withdrawing, #actions, desc, setName))
end

-- Deposit every equipped or bagged copy of items referenced by any equipment set.
function EMB.DepositAllSets()
    if not IsBankOpen() then
        PrintMessage(EMB.Strings.MustBeAtBank)
        return
    end

    local setName = "all equipment sets"
    local setItemIDs = GetAllSetItemIDs()
    local toDeposit = {}

    for invSlot = 1, 19 do
        local itemID = GetInventoryItemID("player", invSlot)
        if itemID and setItemIDs[itemID] then
            table.insert(toDeposit, {
                actionType = "EQUIP_TO_BANK",
                invSlot = invSlot,
                itemID = itemID,
                itemLink = GetInventoryItemLink("player", invSlot),
            })
        end
    end

    for _, bagID in ipairs(GetPlayerBags()) do
        local numSlots = Container.GetNumSlots(bagID)
        for slot = 1, numSlots do
            local itemID = Container.GetItemID(bagID, slot)
            if itemID and setItemIDs[itemID] then
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
        PrintMessage(string.format(EMB.Strings.NoItemsToDeposit, setName))
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

    StartTransfers(actions, string.format(EMB.Strings.Depositing, #actions, "items", setName))
end

-- Withdraw every bank copy matching an item referenced by any equipment set.
function EMB.WithdrawAllSets()
    if not IsBankOpen() then
        PrintMessage(EMB.Strings.MustBeAtBank)
        return
    end

    local setName = "all equipment sets"
    local setItemIDs = GetAllSetItemIDs()
    local toWithdraw = {}

    for _, bagID in ipairs(GetBankBags()) do
        local numSlots = Container.GetNumSlots(bagID)
        for slot = 1, numSlots do
            local itemID = Container.GetItemID(bagID, slot)
            if itemID and setItemIDs[itemID] then
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
        PrintMessage(string.format(EMB.Strings.NoItemsToWithdraw, setName))
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

    StartTransfers(actions, string.format(EMB.Strings.Withdrawing, #actions, "items", setName))
end

local function GetSetItemTransfers(bagIDs, itemIDs, actionType)
    local transfers = {}
    for _, bagID in ipairs(bagIDs) do
        local numSlots = Container.GetNumSlots(bagID)
        for slot = 1, numSlots do
            local itemID = Container.GetItemID(bagID, slot)
            if itemID and itemIDs[itemID] then
                local info = Container.GetItemInfo(bagID, slot)
                if not (info and info.isLocked) then
                    table.insert(transfers, {
                        actionType = actionType,
                        fromBag = bagID,
                        fromSlot = slot,
                        itemID = itemID,
                        itemLink = Container.GetItemLink(bagID, slot),
                    })
                end
            end
        end
    end
    return transfers
end

function EMB.WithdrawOtherSets(setID)
    if not IsBankOpen() then
        PrintMessage(EMB.Strings.MustBeAtBank)
        return
    end

    local otherSetItemIDs = GetOtherSetOnlyItemIDs(setID)
    local toWithdraw = GetSetItemTransfers(GetBankBags(), otherSetItemIDs, "BANK_TO_BAG")
    if #toWithdraw == 0 then
        PrintMessage(EMB.Strings.NoOtherSetItems)
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
    StartTransfers(actions, string.format(EMB.Strings.WithdrawingOtherSets, #actions))
end

function EMB.DepositOtherSets(setID)
    if not IsBankOpen() then
        PrintMessage(EMB.Strings.MustBeAtBank)
        return
    end

    local otherSetItemIDs = GetOtherSetOnlyItemIDs(setID)
    local toDeposit = GetSetItemTransfers(GetPlayerBags(), otherSetItemIDs, "BAG_TO_BANK")
    if #toDeposit == 0 then
        PrintMessage(EMB.Strings.NoOtherSetItems)
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
    StartTransfers(actions, string.format(EMB.Strings.DepositingOtherSets, #actions))
end

-- Ctrl+Shift-right-click uses the selected set as the one to preserve. If other
-- set items are in the bank, withdraw them; otherwise deposit matching bag items.
function EMB.TransferOtherSetItems(setID)
    if not IsBankOpen() then
        PrintMessage(EMB.Strings.MustBeAtBank)
        return
    end

    local otherSetItemIDs = GetOtherSetOnlyItemIDs(setID)
    for _, bagID in ipairs(GetBankBags()) do
        local numSlots = Container.GetNumSlots(bagID)
        for slot = 1, numSlots do
            local itemID = Container.GetItemID(bagID, slot)
            if itemID and otherSetItemIDs[itemID] then
                EMB.WithdrawOtherSets(setID)
                return
            end
        end
    end

    EMB.DepositOtherSets(setID)
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

            local function AddBankOption(label, callback)
                local button = rootDescription:CreateButton(label, callback)
                if not bankOpen then
                    button:SetEnabled(false)
                end
            end

            AddBankOption(EMB.Strings.Deposit, function()
                EMB.DepositSet(setID, false)
            end)
            AddBankOption(EMB.Strings.Withdraw, function()
                EMB.WithdrawSet(setID, false)
            end)
            AddBankOption(EMB.Strings.DepositUnique, function()
                EMB.DepositSet(setID, true)
            end)
            AddBankOption(EMB.Strings.WithdrawUnique, function()
                EMB.WithdrawSet(setID, true)
            end)
            AddBankOption(EMB.Strings.DepositOther, function()
                EMB.DepositOtherSets(setID)
            end)
            AddBankOption(EMB.Strings.WithdrawOther, function()
                EMB.WithdrawOtherSets(setID)
            end)
            AddBankOption(EMB.Strings.DepositAll, function()
                EMB.DepositAllSets()
            end)
            AddBankOption(EMB.Strings.WithdrawAll, function()
                EMB.WithdrawAllSets()
            end)
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
        {
            text = EMB.Strings.Deposit,
            notCheckable = true,
            disabled = not bankOpen,
            func = function() EMB.DepositSet(setID, false) end
        },
        {
            text = EMB.Strings.Withdraw,
            notCheckable = true,
            disabled = not bankOpen,
            func = function() EMB.WithdrawSet(setID, false) end
        },
        {
            text = EMB.Strings.DepositUnique,
            notCheckable = true,
            disabled = not bankOpen,
            func = function() EMB.DepositSet(setID, true) end
        },
        {
            text = EMB.Strings.WithdrawUnique,
            notCheckable = true,
            disabled = not bankOpen,
            func = function() EMB.WithdrawSet(setID, true) end
        },
        {
            text = EMB.Strings.DepositOther,
            notCheckable = true,
            disabled = not bankOpen,
            func = function() EMB.DepositOtherSets(setID) end
        },
        {
            text = EMB.Strings.WithdrawOther,
            notCheckable = true,
            disabled = not bankOpen,
            func = function() EMB.WithdrawOtherSets(setID) end
        },
        {
            text = EMB.Strings.DepositAll,
            notCheckable = true,
            disabled = not bankOpen,
            func = function() EMB.DepositAllSets() end
        },
        {
            text = EMB.Strings.WithdrawAll,
            notCheckable = true,
            disabled = not bankOpen,
            func = function() EMB.WithdrawAllSets() end
        },
    }

    EasyMenu(menu, dropdownFrame, "cursor", 0, 0, "MENU")
end
EMB.OpenContextMenu = OpenContextMenu

-------------------------------------------------------------------------------
-- Action Bar Equipment Set Icons
-------------------------------------------------------------------------------

local actionButtonPrefixes = {
    "ActionButton",
    "MainMenuBarActionButton",
    "MultiBarBottomLeftButton",
    "MultiBarBottomRightButton",
    "MultiBarLeftButton",
    "MultiBarRightButton",
    "MultiBar5Button",
    "MultiBar6Button",
    "MultiBar7Button",
    "MultiBar8Button",
    "BonusActionButton",
    "OverrideActionBarButton",
}

local function TooltipHasLine(tooltip, text)
    if not tooltip or not tooltip.GetName or not tooltip.NumLines then return false end
    local name = tooltip:GetName()
    if not name then return false end

    for index = 1, tooltip:NumLines() do
        local fontString = _G[name .. "TextLeft" .. index]
        if fontString and fontString:GetText() == text then
            return true
        end
    end
    return false
end

local function AppendTooltipLines(tooltip, lines)
    if not tooltip or not tooltip.AddLine then return end

    local missingLines = {}
    for _, line in ipairs(lines) do
        if not TooltipHasLine(tooltip, line) then
            table.insert(missingLines, line)
        end
    end
    if #missingLines == 0 then return end

    tooltip:AddLine(" ")
    for _, line in ipairs(missingLines) do
        tooltip:AddLine(line, 1, 0.82, 0.1, true)
    end
    tooltip:Show()
end

local function AppendSetTooltipHelp(button, lines)
    if not GameTooltip then return end

    local ownedByButton = GameTooltip.IsOwned and GameTooltip:IsOwned(button)
    if not ownedByButton and GameTooltip.GetOwner then
        ownedByButton = GameTooltip:GetOwner() == button
    end
    if ownedByButton then
        AppendTooltipLines(GameTooltip, lines)
    end
end

local function GetActionInfoForSlot(actionSlot)
    local actionType, actionID
    if GetActionInfo then
        actionType, actionID = GetActionInfo(actionSlot)
    end
    if not actionType and C_ActionBar and C_ActionBar.GetActionInfo then
        actionType, actionID = C_ActionBar.GetActionInfo(actionSlot)
    end
    if type(actionType) == "table" then
        actionID = actionType.actionID or actionType.id or actionID
        actionType = actionType.actionType or actionType.type
    end
    return actionType, actionID
end

local function GetActionSlotForButton(button)
    local actionSlot = button.action
    if not actionSlot and button.GetAttribute then
        actionSlot = button:GetAttribute("action")
    end
    if not actionSlot and ActionButton_GetPagedID then
        actionSlot = ActionButton_GetPagedID(button)
    end
    return actionSlot
end

local function IsEquipmentSetActionButton(button)
    local actionSlot = GetActionSlotForButton(button)
    if not actionSlot then return false end
    local actionType = GetActionInfoForSlot(actionSlot)
    return actionType == "equipmentset"
end

local function GetEquipmentSetIDFromActionButton(button)
    local actionSlot = GetActionSlotForButton(button)
    if not actionSlot then return nil end

    local actionType, actionID = GetActionInfoForSlot(actionSlot)
    if actionType ~= "equipmentset" then return nil end
    if type(actionID) == "string" and C_EquipmentSet and C_EquipmentSet.GetEquipmentSetID then
        actionID = C_EquipmentSet.GetEquipmentSetID(actionID)
    end
    return actionID
end

local tooltipMethodHooks = {
    actionBarMixin = false,
    actionBarTooltip = false,
    equipmentManager = false,
}

local function HookTooltipRefreshers()
    if not tooltipMethodHooks.actionBarMixin and ActionBarActionButtonMixin and ActionBarActionButtonMixin.SetTooltip then
        local ok = pcall(hooksecurefunc, ActionBarActionButtonMixin, "SetTooltip", function(button)
            if IsEquipmentSetActionButton(button) then
                AppendTooltipLines(GameTooltip, {
                    EMB.Strings.TooltipEquip,
                    EMB.Strings.TooltipActionBarRightClick,
                    EMB.Strings.TooltipActionBarModifiedRightClick,
                })
            end
        end)
        tooltipMethodHooks.actionBarMixin = ok
    end

    if not tooltipMethodHooks.actionBarTooltip and GameTooltip and GameTooltip.SetAction then
        local ok = pcall(hooksecurefunc, GameTooltip, "SetAction", function(tooltip, actionSlot)
            local actionType = GetActionInfoForSlot(actionSlot)
            if actionType == "equipmentset" then
                AppendTooltipLines(tooltip, {
                    EMB.Strings.TooltipEquip,
                    EMB.Strings.TooltipActionBarRightClick,
                    EMB.Strings.TooltipActionBarModifiedRightClick,
                })
            end
        end)
        tooltipMethodHooks.actionBarTooltip = ok
    end

    if not tooltipMethodHooks.equipmentManager and GameTooltip and GameTooltip.SetEquipmentSet then
        local ok = pcall(hooksecurefunc, GameTooltip, "SetEquipmentSet", function(tooltip)
            AppendTooltipLines(tooltip, {
                EMB.Strings.TooltipEquip,
                EMB.Strings.TooltipManagerRightClick,
                EMB.Strings.TooltipBankRequired,
            })
        end)
        tooltipMethodHooks.equipmentManager = ok
    end
end

local function UpdateActionButtonEquippedCheck(button)
    if not button then return end
    if InCombatLockdown and InCombatLockdown() then return end

    local setID = GetEquipmentSetIDFromActionButton(button)
    if not setID then
        if button._embEquippedSetCheck then
            button._embEquippedSetCheck:Hide()
        end
        return
    end
    if not (C_EquipmentSet and C_EquipmentSet.GetEquipmentSetInfo) then return end

    if not button._embEquippedSetCheck then
        if not button.CreateTexture then return end
        local check = button:CreateTexture(nil, "OVERLAY")
        check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
        check:SetSize(16, 16)
        local icon = button.icon or button.Icon
        if icon then
            check:SetPoint("TOPRIGHT", icon, "TOPRIGHT", 0, 0)
        else
            check:SetPoint("TOPRIGHT", button, "TOPRIGHT", -3, -3)
        end
        check:Hide()
        button._embEquippedSetCheck = check
    end

    local _, _, _, isEquipped = C_EquipmentSet.GetEquipmentSetInfo(setID)
    button._embEquippedSetCheck:SetShown(isEquipped and true or false)
end

local function UpdateActionButtonBankMode(button)
    if not button or not button.GetAttribute or not button.SetAttribute then return end
    if InCombatLockdown and InCombatLockdown() then return end

    local setID = GetEquipmentSetIDFromActionButton(button)
    if IsBankOpen() and setID then
        if not button._embBankRightClickOverride then
            button._embOriginalType2 = button:GetAttribute("type2")
            button._embBankRightClickOverride = true
        end
        if button:GetAttribute("type2") ~= "" then
            -- Let the addon handle right-click while preserving normal left-click equip.
            button:SetAttribute("type2", "")
        end
    elseif button._embBankRightClickOverride then
        button:SetAttribute("type2", button._embOriginalType2)
        button._embOriginalType2 = nil
        button._embBankRightClickOverride = nil
    end
end

local function HandleEquipmentSetBankClick(setID, otherSets)
    if not setID or not IsBankOpen() then return end

    if otherSets then
        EMB.TransferOtherSetItems(setID)
        return
    end

    local items = GetSetItems(setID)
    for _, item in ipairs(items) do
        if item.locationType == "bank" then
            -- If any piece is banked, move the set's banked pieces back first.
            EMB.WithdrawSet(setID, false)
            return
        end
    end

    -- Otherwise, deposit only unique pieces of the set that are in player bags.
    EMB.DepositUniqueBagItems(setID)
end

local function RegisterActionBarButton(button)
    if not button or not button.HookScript then return end
    if InCombatLockdown and InCombatLockdown() then return end

    if not button._embActionBarBankClickHooked then
        button._embActionBarBankClickHooked = true
        button:HookScript("OnClick", function(self, mouseButton, down)
            if mouseButton ~= "RightButton" or down or not IsBankOpen() then return end
            local setID = GetEquipmentSetIDFromActionButton(self)
            if setID then
                local ctrlShift = IsControlKeyDown and IsControlKeyDown()
                    and IsShiftKeyDown and IsShiftKeyDown()
                HandleEquipmentSetBankClick(setID, ctrlShift)
            end
        end)
    end

    if not button._embActionBarTooltipHooked then
        button._embActionBarTooltipHooked = true
        button:HookScript("OnEnter", function(self)
            if IsEquipmentSetActionButton(self) then
                AppendSetTooltipHelp(self, {
                    EMB.Strings.TooltipEquip,
                    EMB.Strings.TooltipActionBarRightClick,
                    EMB.Strings.TooltipActionBarModifiedRightClick,
                })
            end
        end)
    end

    UpdateActionButtonBankMode(button)
    UpdateActionButtonEquippedCheck(button)
end

local actionButtonUpdateHooks = {}
local actionButtonMixinUpdateHooked = false

local function HookActionBarButtons()
    HookTooltipRefreshers()

    if ActionBarActionButtonMixin and ActionBarActionButtonMixin.UpdateAction and not actionButtonMixinUpdateHooked then
        local ok = pcall(hooksecurefunc, ActionBarActionButtonMixin, "UpdateAction", function(button)
            RegisterActionBarButton(button)
        end)
        actionButtonMixinUpdateHooked = ok
    end

    for _, functionName in ipairs({ "ActionButton_Update", "ActionButton_UpdateAction" }) do
        if _G[functionName] and not actionButtonUpdateHooks[functionName] then
            local ok = pcall(hooksecurefunc, functionName, function(button)
                RegisterActionBarButton(button)
            end)
            actionButtonUpdateHooks[functionName] = ok
        end
    end

    for _, prefix in ipairs(actionButtonPrefixes) do
        for index = 1, 12 do
            local button = _G[prefix .. index]
            if button then
                RegisterActionBarButton(button)
            end
        end
    end
end

local bankFrameHooks = {}

local function HookBankFrameVisibility()
    for _, frameName in ipairs({ "BankFrame", "AccountBankPanel" }) do
        local frame = _G[frameName]
        if frame and frame.HookScript and not bankFrameHooks[frameName] then
            bankFrameHooks[frameName] = true
            frame:HookScript("OnShow", function()
                isBankFrameOpen = true
                HookActionBarButtons()
            end)
            frame:HookScript("OnHide", function()
                local mainBankOpen = BankFrame and BankFrame.IsShown and BankFrame:IsShown()
                local accountBankOpen = AccountBankPanel and AccountBankPanel.IsShown and AccountBankPanel:IsShown()
                isBankFrameOpen = mainBankOpen or accountBankOpen or false
                HookActionBarButtons()
            end)
        end
    end
end

-------------------------------------------------------------------------------
-- Hooking the Default Equipment Manager
-------------------------------------------------------------------------------

local function RegisterButtonForRightClick(button)
    if not button then return end
    if not button._embRegistered then
        button._embRegistered = true
        button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    end

    if button.HookScript and not button._embManagerTooltipHooked then
        button._embManagerTooltipHooked = true
        button:HookScript("OnEnter", function(self)
            AppendSetTooltipHelp(self, {
                EMB.Strings.TooltipEquip,
                EMB.Strings.TooltipManagerRightClick,
                EMB.Strings.TooltipBankRequired,
            })
        end)
    end
end

local function HookEquipmentManagerPane()
    HookTooltipRefreshers()
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
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
for _, eventName in ipairs({ "PLAYER_EQUIPMENT_CHANGED", "EQUIPMENT_SWAP_FINISHED", "EQUIPMENT_SETS_CHANGED" }) do
    pcall(eventFrame.RegisterEvent, eventFrame, eventName)
end

eventFrame:SetScript("OnEvent", function(self, event, arg1, ...)
    if event == "PLAYER_LOGIN" then
        HookEquipmentManagerPane()
        HookBankFrameVisibility()
        HookActionBarButtons()
    elseif event == "ADDON_LOADED" then
        if arg1 == "Blizzard_UIPanels_Game" or arg1 == "Blizzard_EquipmentManager" then
            HookEquipmentManagerPane()
        end
        HookBankFrameVisibility()
        HookActionBarButtons()
    elseif event == "BANKFRAME_OPENED" then
        isBankFrameOpen = true
        HookActionBarButtons()
    elseif event == "BANKFRAME_CLOSED" then
        isBankFrameOpen = false
        CancelTransfers(EMB.Strings.TransferInterruptedBankClosed)
        HookActionBarButtons()
    elseif event == "ACTIONBAR_SLOT_CHANGED" or event == "PLAYER_REGEN_ENABLED" then
        HookBankFrameVisibility()
        HookActionBarButtons()
    elseif event == "PLAYER_EQUIPMENT_CHANGED" or event == "EQUIPMENT_SWAP_FINISHED" or event == "EQUIPMENT_SETS_CHANGED" then
        HookActionBarButtons()
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
        PrintMessage("  /eqbank deposit <SetName> - Deposit items for a set into the bank")
        PrintMessage("  /eqbank withdraw <SetName> - Withdraw set items from the bank")
        PrintMessage("  Right-click an equipment set for equip and bank options.")
        PrintMessage("  At the bank, right-click a set icon to withdraw it or deposit unique bag items.")
        PrintMessage("  Ctrl+Shift-right-click a set icon to transfer other-set items.")
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
