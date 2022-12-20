local frame = nil
local thread = nil
local shouldStopSelling = false

local AddOn = {}

Seller = {}

Seller.addItemToSell = function(itemIdentifier, quantity)
    if SellerItemsToSell[itemIdentifier] then
        SellerItemsToSell[itemIdentifier] = SellerItemsToSell[itemIdentifier] + quantity
    else
        SellerItemsToSell[itemIdentifier] = quantity
    end
end

local function findFreeSlot(containerIndex, slotIndex)
    for containerIndex = 0, NUM_BAG_SLOTS do
        if GetContainerNumFreeSlots(containerIndex) >= 1 then
            -- TODO: Is https://wowpedia.fandom.com/wiki/API_GetContainerFreeSlots faster?
            for slotIndex = 1, GetContainerNumSlots(containerIndex) do
                local itemID = GetContainerItemID(containerIndex, slotIndex)
                local isSlotFree = not itemID
                if isSlotFree then
                    return containerIndex, slotIndex
                end
            end
        end
    end
    return nil, nil
end

local function waitForBagUpdate()
    Events.waitForEvent('BAG_UPDATE_DELAYED')
end

function splitItem(containerIndex, slotIndex, firstStackSize)
    local itemCount = select(2, GetContainerItemInfo(containerIndex, slotIndex))
    local quantityToPickUp = itemCount - firstStackSize
    if quantityToPickUp >= 1 then
        local dropContainerIndex, dropSlotIndex = findFreeSlot(containerIndex, slotIndex)
        if dropContainerIndex and dropSlotIndex then
            SplitContainerItem(containerIndex, slotIndex, quantityToPickUp)
            PickupContainerItem(dropContainerIndex, dropSlotIndex)
            waitForBagUpdate()
            return true
        end
    end
    return false
end

function testSplitItem()
    thread = coroutine.create(function()
        splitItem(0, 1, 1)
    end)
    coroutine.resume(thread)
end

local function sell2()
    for containerIndex = 0, NUM_BAG_SLOTS do
        for slotIndex = 1, GetContainerNumSlots(containerIndex) do
            if shouldStopSelling then
                return
            end
            local itemID = GetContainerItemID(containerIndex, slotIndex)
            local itemLink = GetContainerItemLink(containerIndex, slotIndex)
            local itemCount = select(2, GetContainerItemInfo(containerIndex, slotIndex))
            local itemLinkSellCount = 0
            local itemIDSellCount = 0
            if itemLink and SellerItemsToSell[itemLink] then
                itemLinkSellCount = math.min(SellerItemsToSell[itemLink], itemCount)
            end
            if itemID and SellerItemsToSell[itemID] then
                itemIDSellCount = math.min(SellerItemsToSell[itemID], itemCount - itemLinkSellCount)
            end

            local function sellItem()
                UseContainerItem(containerIndex, slotIndex)
                waitForBagUpdate()
                AddOn.removeItemToSell(itemLink, itemLinkSellCount)
                AddOn.removeItemToSell(itemID, itemIDSellCount)
            end

            local sellCount = itemLinkSellCount + itemIDSellCount
            if sellCount >= 1 then
                if itemCount == sellCount then
                    sellItem()
                elseif itemCount > sellCount then
                    local wasSplitSuccessful = splitItem(sellCount)
                    if wasSplitSuccessful then
                        sellItem()
                    else
                        print('There was some item which could not be split because no slot was free.')
                    end
                end
            end
        end
    end
end

local function sell()
    frame:RegisterEvent('BAG_UPDATE_DELAYED')

    sell2()

    frame:UnregisterEvent('BAG_UPDATE_DELAYED')
    thread = nil
end

Seller.sell = function()
    if not thread then
        shouldStopSelling = false
        thread = coroutine.create(sell)
        coroutine.resume(thread)
    end
end

local function initializeSavedVariables()
    if SellerItemsToSell == nil then
        SellerItemsToSell = {}
    end
end

local function onAddonLoaded(name)
    if name == 'AuctionHouseDealFinder' then
        initializeSavedVariables()
    end
end

local function onMerchantShow()
    --Seller.sell()
end

local function stopSelling()
    shouldStopSelling = true
end

local function onMerchantClosed()
    stopSelling()
end

function AddOn.removeItemToSell(itemIdentifier, quantity)
    if SellerItemsToSell[itemIdentifier] then
        SellerItemsToSell[itemIdentifier] = SellerItemsToSell[itemIdentifier] - quantity
        if SellerItemsToSell[itemIdentifier] <= 0 then
            SellerItemsToSell[itemIdentifier] = nil
        end
    end
end

local function onEvent(self, event, ...)
    if event == 'ADDON_LOADED' then
        onAddonLoaded(...)
    elseif event == 'MERCHANT_SHOW' then
        onMerchantShow(...)
    elseif event == 'MERCHANT_CLOSED' then
        onMerchantClosed(...)
    end
end

frame = CreateFrame('Frame')
frame:SetScript('OnEvent', onEvent)
frame:RegisterEvent('ADDON_LOADED')
frame:RegisterEvent('MERCHANT_SHOW')
frame:RegisterEvent('MERCHANT_CLOSED')
