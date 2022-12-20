-- Method: through browser results. Cache vendor sell price. Lookup for ItemKey to item link for retrieving vendor sell price once it is cached and omitting, retrieving the non-commidity items for an item link.
-- Maybe C_AuctionHouse.SearchForItemKeys is an efficient way to retrieve the item links for multiple items

-- Notes:
-- * The price in the browser results shows the smallest buyout price.
-- * Item id and item level seems to be enough for the price.

-- 1. Retrieving all browse results
-- 2. Processing browse results (one by one)
--    2.1. Retrieving information for determining if profitable deal.
--    2.2. If profitable deal: Show buy button
-- Continue when not profitable deal or after the deal has been bought.

-- FIXME: Seems to sometimes disconnect.
-- FIXME: Consider C_AuctionHouse.RequestMoreItemSearchResults for loading additional search results when required (it is possible that there are deals in them).
-- TODO: On auction house close: stop deal finding process.

-- /dump coroutine.wrap(function () printTable(AuctionHouseDealFinder.retrieveItemInfo(C_AuctionHouse.GetBrowseResults()[94].itemKey)) end)()

local originalCoroutineResume = coroutine.resume

local function logCoroutineError(...)
    local result = { originalCoroutineResume(...) }
    local wasSuccessful = result[1]
    if not wasSuccessful then
        local errorMessage = result[2]
        error(errorMessage)
    end
    return unpack(result)
end

coroutine.resume = logCoroutineError

local AddOn = {}
AuctionHouseDealFinder = AddOn
local ItemInfoCache = {}

local frame

local thread = nil

local MINIMUM_PROFIT = 1

local method = 'browserResults' -- 'replicate'

local isProcessingAuctions = false
local itemPriceQuery = nil

local buyoutQueue = {}
local auctionIDsInBuyoutQueue = {}
local commodityItemIDsInBuyoutQueue = {}

local purchase = nil

local button

local searches = {}

local isThrottledSystemReady = true

local pendingSearchQuery = nil

local DEBUG = true

local findAuctionsToBuyQueue = {}
local isFindAuctionsToBuyInProgress = false

function AddOn.findDeals()
    thread = coroutine.create(function()
        if method == 'replicate' then
            if not lastTimeAuctionHouseItemsReplicated or time() - lastTimeAuctionHouseItemsReplicated > 15 * 60 then
                print('Requesting all auctions...')
                AddOn.replicateAndProcessItems()
            else
                local timeLeft = 15 * 60 - (time() - lastTimeAuctionHouseItemsReplicated)
                local minutes = Math.round(timeLeft / 60)
                local seconds = timeLeft % 60
                print('Still ' .. minutes .. ' minutes and ' .. seconds .. ' seconds remaining until the auction house items can be replicated again.')

                if #auctions >= 1 then
                    print('Finding deals in the cached auctions.')
                    AddOn.processStoredAuctions()
                end
            end
        elseif method == 'browserResults' then
            if not lastTimeAuctionHouseItemsReplicated or time() - lastTimeAuctionHouseItemsReplicated > 15 * 60 then
                print('replicateAndProcessItems()')
                AddOn.replicateAndProcessItems()
            else
                AddOn.loadAndProcessBrowseResults()
            end
        else
            print('Error: Unknown method: "' .. method .. '"')
        end
    end)
    coroutine.resume(thread)
end

function AddOn.replicateAndProcessItems()
    AddOn.replicateItems()

    print('processAuctions')
    AddOn.processAuctions()
    print('buildItemInfoCache2')
    AddOn.buildItemInfoCache2()
    if method == 'replicate' then
        print('AddOn.processStoredAuctions')
        AddOn.processStoredAuctions()
    elseif method == 'browserResults' then
        AddOn.loadAndProcessBrowseResults()
    end
end

function AddOn.replicateItems()
    lastTimeAuctionHouseItemsReplicated = time()
    C_AuctionHouse.ReplicateItems()
    Events.waitForEvent('REPLICATE_ITEM_LIST_UPDATE')
    lastTimeAuctionHouseItemsReplicated = time()
end

function AddOn.loadAndProcessBrowseResults()
    print('AddOn.loadBrowseResults')
    local browseResults = AddOn.loadAllBrowseResults()
    print('All browser results loaded (' .. #browseResults .. ').')
    AddOn.processBrowseResults(browseResults)
end

function AddOn.loadAllBrowseResults()
    return AddOn.loadBrowseResults({
        searchString = '',
        sorts = {},
        filters = {
            Enum.AuctionHouseFilter.PoorQuality,
            Enum.AuctionHouseFilter.CommonQuality,
            Enum.AuctionHouseFilter.UncommonQuality,
            Enum.AuctionHouseFilter.RareQuality,
            Enum.AuctionHouseFilter.EpicQuality,
            Enum.AuctionHouseFilter.LegendaryQuality,
            Enum.AuctionHouseFilter.ArtifactQuality,
        }
    })
end

function AddOn.loadBrowseResults(query)
    C_AuctionHouse.SendBrowseQuery(query)

    Events.waitForOneOfEventsAndCondition({ 'AUCTION_HOUSE_BROWSE_RESULTS_UPDATED', 'AUCTION_HOUSE_BROWSE_RESULTS_ADDED' }, function()
        if C_AuctionHouse.HasFullBrowseResults() then
            return true
        else
            C_AuctionHouse.RequestMoreBrowseResults()
            return false
        end
    end)

    return C_AuctionHouse.GetBrowseResults()
end

function AddOn.processBrowseResults(browseResults)
    print('Processing browse results...')

    for index, browseResult in ipairs(browseResults) do
        print('processBrowseResult', index)
        AddOn.processBrowseResult(browseResult)
    end

    print('Done processing browser results.')
    C_Timer.After(0, AddOn.findDeals)
end

function AddOn.processBrowseResult(browseResult)
    if browseResult.itemKey.battlePetSpeciesID == 0 then
        AddOn.processBrowseResult2(browseResult)
    end
end

function AddOn.processBrowseResult2(browseResult)
    local itemInfo = AddOn.retrieveItemInfo(browseResult.itemKey)
    if itemInfo then
        local vendorSellPrice = itemInfo.vendorSellPrice
        if vendorSellPrice then
            local minimumBuyPrice = browseResult.minPrice
            local profit = AddOn.calculateProfit(vendorSellPrice, minimumBuyPrice)
            if AddOn.shouldBuy(profit) then
                AddOn.sendSearchQuery(
                    browseResult.itemKey,
                    {
                        {
                            sortOrder = Enum.AuctionHouseSortOrder.Price,
                            reverseSort = false
                        }
                    },
                    false
                )
                if AddOn.isCommodityItem(browseResult.itemKey.itemID) then
                    AddOn.processCommoditySearchResults(browseResult.itemKey.itemID)
                else
                    AddOn.processItemSearchResults(browseResult.itemKey)
                end
            end
        end
    end
end

function AddOn.processCommoditySearchResults(itemID)
    print('AddOn.processCommoditySearchResults')
    local numberOfCommoditySearchResults = C_AuctionHouse.GetNumCommoditySearchResults(itemID)

    print(1)
    if numberOfCommoditySearchResults >= 1 then
        print(2)
        local itemInfo = AddOn.retrieveItemInfo({
            itemID = itemID
        })
        print(3)
        local vendorSellPrice = itemInfo.vendorSellPrice
        print(4)
        if vendorSellPrice then
            print(5)
            for i = 1, numberOfCommoditySearchResults do
                print(6)
                local result = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
                print(7)
                if result and result.itemID == itemID then
                    print(8)
                    local buyoutPrice = result.unitPrice
                    print(9)
                    local profit = AddOn.calculateProfit(vendorSellPrice, buyoutPrice)
                    print(10)
                    if AddOn.shouldBuy(profit) then
                        print(11)
                        AddOn.showItemToBuyOut({
                            itemID = itemID,
                            price = buyoutPrice,
                            vendorSellPrice = vendorSellPrice,
                            profit = profit,
                            commodity = true,
                            quantity = result.quantity
                        })
                        print(12)
                    elseif buyoutPrice >= vendorSellPrice then
                        print(3)
                        break
                    end
                    print(14)
                end
                print(15)
            end
            print(16)
        end
        print(17)
    end
    print(18)
end

function AddOn.processItemSearchResults(itemKey)
    print('AddOn.processItemSearchResults')
    local numberOfItemSearchResults = C_AuctionHouse.GetNumItemSearchResults(itemKey)

    if numberOfItemSearchResults >= 1 then
        local result = C_AuctionHouse.GetItemSearchResultInfo(itemKey, 1)
        local itemInfo = AddOn.retrieveItemInfo(itemKey)
        local vendorSellPrice = itemInfo.vendorSellPrice

        if vendorSellPrice then
            local function processSearchResult(result)
                if result then
                    local buyoutPrice = result.buyoutAmount
                    if buyoutPrice then
                        if result.itemLink then
                            local profit = AddOn.calculateProfit(vendorSellPrice, buyoutPrice)
                            if AddOn.shouldBuy(profit) then
                                for i = 1, result.quantity do
                                    AddOn.showItemToBuyOut({
                                        auctionID = result.auctionID,
                                        price = buyoutPrice,
                                        profit = profit,
                                        commodity = false,
                                        itemLink = result.itemLink,
                                        quantity = 1
                                    })
                                end
                            else
                                local timeLeft = result.timeLeft
                                if timeLeft == Enum.AuctionHouseTimeLeftBand.Short then
                                    local bidAmount = result.bidAmount
                                    if bidAmount then
                                        local profit = AddOn.calculateProfit(vendorSellPrice, bidAmount)
                                        if AddOn.shouldBuy(profit) then
                                            AddOn.showItemToBuyOut({
                                                auctionID = result.auctionID,
                                                price = bidAmount,
                                                profit = profit,
                                                commodity = false,
                                                itemLink = result.itemLink,
                                                quantity = 1,
                                                isBid = true
                                            })
                                        end
                                    end
                                end
                            end
                        else
                            debugPrint('o.O')
                        end
                    end
                end
            end

            processSearchResult(result)

            for i = 2, numberOfItemSearchResults do
                print('The thing', i, numberOfItemSearchResults)
                local result = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
                processSearchResult(result)
            end
        end
    end
end

local function p(label, data)
    if type(data) == 'table' then
        print(label .. ':')
        printTable(data)
        print('---')
    else
        print(label .. ':', data)
    end
end

local function debugPrint(...)
    if DEBUG then
        return print(...)
    end
end

function AddOn.waitForItemToLoad(item)
    if not item:IsItemDataCached() then
        local thread = coroutine.running()

        item:ContinueOnItemLoad(function()
            coroutine.resume(thread)
        end)

        coroutine.yield()
    end
end

function AddOn.waitForThrottledSystemReady()
    Events.waitForEvent('AUCTION_HOUSE_THROTTLED_SYSTEM_READY')
end

function AddOn.sendSearchQuery(itemKey, sorts, separateOwnerItems, minLevelFilter, maxLevelFilter)
    print('B1')
    print('AddOn.sendSearchQuery')
    print('B2')
    local item = Item:CreateFromItemID(itemKey.itemID)
    print('B3')
    AddOn.waitForItemToLoad(item)
    print('B4')
    if not isThrottledSystemReady then
        print('B4.1')
        AddOn.waitForThrottledSystemReady()
        print('B4.2')
    end
    print('B4.3')
    local wasSuccessful
    repeat
        C_AuctionHouse.SendSearchQuery(itemKey, sorts, separateOwnerItems, minLevelFilter, maxLevelFilter)
        print('B5')
        if AddOn.isCommodityItem(itemKey.itemID) then
            print('B6')
            wasSuccessful = Events.waitForEventCondition('COMMODITY_SEARCH_RESULTS_UPDATED', function(self, event, itemID)
                return itemID == itemKey.itemID
            end, 1)
            print('B7')
        else
            print('B8')
            wasSuccessful = Events.waitForOneOfEventsAndCondition({ 'ITEM_SEARCH_RESULTS_UPDATED', 'ITEM_SEARCH_RESULTS_ADDED' }, function(self, event, eventItemKey)
                print(event, 'AAA')
                p('eventItemKey', eventItemKey)
                p('itemKey', itemKey)
                return Object2.equals(eventItemKey, itemKey)
            end, 1)
            print('B9')
        end
    until wasSuccessful
    print('B10')
    print('--- AddOn.sendSearchQuery')
    -- TODO: AuctionHouse.RequestMoreCommoditySearchResults (only when there can be potentially deals in them)
    -- TODO: AuctionHouse.RequestMoreItemSearchResults (only when there can be potentially deals in them)
end

function debugPrintTable(...)
    if DEBUG then
        return printTable(...)
    end
end

function AddOn.convertToItemInfoCacheEntry(itemInfo)
    return {
        itemInfo.vendorSellPrice,
        itemInfo.itemLevel
    }
end

function AddOn.convertFromItemInfoCacheEntry(itemInfoCacheEntry)
    return {
        vendorSellPrice = itemInfoCacheEntry[1],
        itemLevel = itemInfoCacheEntry[2]
    }
end

function AddOn.isCommodityItem(itemIdentifier)
    local classID, subclassID = select(6, GetItemInfoInstant(itemIdentifier))
    return (
        classID == Enum.ItemClass.Consumable or
            classID == Enum.ItemClass.Gem or
            classID == Enum.ItemClass.Tradegoods or
            classID == Enum.ItemClass.ItemEnhancement or
            classID == Enum.ItemClass.Questitem or
            (classID == Enum.ItemClass.Miscellaneous and subclassID ~= Enum.ItemMiscellaneousSubclass.Mount) or
            classID == Enum.ItemClass.Glyph or
            classID == Enum.ItemClass.Key
    )
end

function AddOn.isNonCommodityItem(itemIdentifier)
    local classID, subclassID = select(6, GetItemInfoInstant(itemIdentifier))
    return (
        classID == Enum.ItemClass.Container or
            classID == Enum.ItemClass.Weapon or
            classID == Enum.ItemClass.Armor or
            classID == Enum.ItemClass.Recipe or
            (classID == Enum.ItemClass.Miscellaneous and subclassID == Enum.ItemMiscellaneousSubclass.Mount) or
            classID == Enum.ItemClass.Battlepet or
            classID == Enum.ItemClass.WoWToken
    )
end

function AddOn.generateItemInfoCacheKey(itemIdentifier)
    local itemID = itemIdentifier.itemID
    local key = tostring(itemID)
    if AddOn.isNonCommodityItem(itemID) then
        local itemLevel = itemIdentifier.itemLevel
        key = key .. '_' .. itemLevel
    end
    return key
end

function AddOn.requestItemInfo(itemIdentifier)
    local item
    local itemIdentifierType = type(itemIdentifier)
    if itemIdentifierType == 'string' then
        item = Item:CreateFromItemLink(itemIdentifier)
    elseif itemIdentifierType == 'number' then
        item = Item:CreateFromItemID(itemIdentifier)
    else
        print('Error: Unexpected type "' .. itemIdentifierType .. '"')
        return nil
    end

    AddOn.waitForItemToLoad(item)
    local vendorSellPrice = select(11, GetItemInfo(itemIdentifier))
    local itemInfo = {
        vendorSellPrice = vendorSellPrice,
        itemLevel = GetDetailedItemLevelInfo(itemIdentifier)
    }

    return itemInfo
end

function AddOn.requestItemInfo2(itemIdentifier)
    local item
    local itemIdentifierType = type(itemIdentifier)
    if itemIdentifierType == 'string' then
        item = Item:CreateFromItemLink(itemIdentifier)
    elseif itemIdentifierType == 'number' then
        item = Item:CreateFromItemID(itemIdentifier)
    else
        print('Error: Unexpected type "' .. itemIdentifierType .. '"')
        return nil
    end

    AddOn.waitForItemToLoad(item)
    local vendorSellPrice = select(11, GetItemInfo(itemIdentifier))
    local itemInfo = {
        vendorSellPrice = vendorSellPrice,
    }

    return itemInfo
end

function AddOn.retrieveItemInfoDeprecated(itemIdentifier)
    if itemInfoCache[itemIdentifier] then
        return AddOn.convertFromItemInfoCacheEntry(itemInfoCache[itemIdentifier])
    else
        local itemInfo = AddOn.requestItemInfo(itemIdentifier)
        itemInfoCache[itemIdentifier] = AddOn.convertToItemInfoCacheEntry(itemInfo)
        return itemInfo
    end
end

function ItemInfoCache.retrieve(itemIdentifier)
    local key = AddOn.generateItemInfoCacheKey(itemIdentifier)
    local itemInfoCacheEntry = itemInfoCache2[key]
    if itemInfoCacheEntry then
        return ItemInfoCache.convertFromItemInfoCacheEntry(itemInfoCacheEntry)
    else
        return nil
    end
end

function ItemInfoCache.store(itemIdentifier, itemInfo)
    local key = AddOn.generateItemInfoCacheKey(itemIdentifier)
    itemInfoCache2[key] = ItemInfoCache.convertToItemInfoCacheEntry(itemInfo)
end

function ItemInfoCache.convertToItemInfoCacheEntry(itemInfo)
    return {
        itemInfo.vendorSellPrice
    }
end

function ItemInfoCache.convertFromItemInfoCacheEntry(itemInfoCacheEntry)
    return {
        vendorSellPrice = itemInfoCacheEntry[1],
    }
end

function AddOn.findAuctionsToBuy(item)
    debugPrint('findAuctionsToBuy', item.itemLink)
    isFindAuctionsToBuyInProgress = true

    local itemID = item.itemID
    local itemLevel = item.itemLevel
    local itemLink = item.itemLink

    local item2 = Item:CreateFromItemID(itemID)
    AddOn.waitForItemToLoad(item2)
    if AddOn.isNonCommodityItem(itemID) then
        local itemName = GetItemInfo(itemLink)
        AddOn.loadBrowseResults(
            {
                searchString = itemName,
                sorts = {
                    {
                        sortOrder = Enum.AuctionHouseSortOrder.Price,
                        reverseSort = false
                    }
                },
                filters = {
                    Enum.AuctionHouseFilter.PoorQuality,
                    Enum.AuctionHouseFilter.CommonQuality,
                    Enum.AuctionHouseFilter.UncommonQuality,
                    Enum.AuctionHouseFilter.RareQuality,
                    Enum.AuctionHouseFilter.EpicQuality,
                    Enum.AuctionHouseFilter.LegendaryQuality,
                    Enum.AuctionHouseFilter.ArtifactQuality,
                }
            }
        )

        local browseResults = C_AuctionHouse.GetBrowseResults()
        local browseResult = AddOn.findBrowserResultForItem(browseResults, item)
        if browseResult then
            AddOn.processBrowseResult(browseResult)
        end
    else
        AddOn.sendSearchQuery(
            {
                itemID = itemID
            },
            {
                {
                    sortOrder = Enum.AuctionHouseSortOrder.Price,
                    reverseSort = false
                }
            },
            false
        )
        AddOn.processCommoditySearchResults(itemID)
    end
end

function AddOn.calculateProfit(vendorSellPrice, buyoutPrice)
    return vendorSellPrice - buyoutPrice
end

function AddOn.shouldBuy(profit)
    return profit >= MINIMUM_PROFIT
end

function AddOn.processStoredAuctions()
    isProcessingAuctions = true

    searches = {}

    for _, auction in ipairs(auctions) do
        local itemLink = auction.itemLink
        local itemInfo = auction.itemInfo
        local battlePetInfo = auction.battlePetInfo
        if battlePetInfo[0] == nil and battlePetInfo[1] == nil then
            local itemInfo2 = AddOn.retrieveItemInfoDeprecated(itemLink)
            local vendorSellPrice = itemInfo2.vendorSellPrice
            local itemLevel = itemInfo2.itemLevel
            if not vendorSellPrice then
                print('vendorSellPrice error', vendorSellPrice, itemLink)
            end
            if vendorSellPrice then
                local buyoutPrice = itemInfo[10]
                local profit = AddOn.calculateProfit(vendorSellPrice, buyoutPrice)
                if not profit then
                    print('profit calculation error', profit)
                end
                if AddOn.shouldBuy(profit) then
                    local itemID = itemInfo[17]
                    debugPrint(itemID, itemLink .. ' (profit: ' .. GetCoinTextureString(profit) .. ')')
                    AddOn.findAuctionsToBuy({
                        itemID = itemID,
                        itemLevel = itemLevel,
                        itemLink = itemLink
                    })
                else
                    local bidPrice = itemInfo[11]
                    if bidPrice then
                        local profit = AddOn.calculateProfit(vendorSellPrice, bidPrice)
                        if not profit then
                            print('profit calculation error', profit)
                        end
                        if AddOn.shouldBuy(profit) then
                            local itemID = itemInfo[17]
                            debugPrint(itemID, itemLink .. ' (profit: ' .. GetCoinTextureString(profit) .. ')')
                            AddOn.findAuctionsToBuy({
                                itemID = itemID,
                                itemLevel = itemLevel,
                                itemLink = itemLink
                            })
                        end
                    end
                end
            end
        end
    end

    print('Done processing auctions.')
    isProcessingAuctions = false
end

local numberOfProcessedAuctions = nil

function AddOn.processAuctions()
    print('Processing auctions...')
    auctions = {}
    numberOfProcessedAuctions = 0
    local numberOfReplicateItems = C_AuctionHouse.GetNumReplicateItems()

    for index = 0, numberOfReplicateItems - 1 do
        local itemID, hasAllInfo = select(17, C_AuctionHouse.GetReplicateItemInfo(index))
        if not hasAllInfo then
            C_Item.RequestLoadItemDataByID(itemID)
        end
    end

    for index = 0, numberOfReplicateItems - 1 do
        local itemID, hasAllInfo = select(17, C_AuctionHouse.GetReplicateItemInfo(index))
        if hasAllInfo then
            AddOn.processAuction(index)
        else
            local item = Item:CreateFromItemID(itemID)
            item:ContinueOnItemLoad(function()
                AddOn.processAuction(index)
            end)
        end
    end

    coroutine.yield()
end

function AddOn.processAuction(index)
    local itemLink = C_AuctionHouse.GetReplicateItemLink(index)
    local itemInfo = { C_AuctionHouse.GetReplicateItemInfo(index) }
    local battlePetInfo = { C_AuctionHouse.GetReplicateItemBattlePetInfo(index) }

    local auction = {
        itemLink = itemLink,
        itemInfo = itemInfo,
        battlePetInfo = battlePetInfo
    }
    table.insert(auctions, auction)

    local numberOfReplicateItems = C_AuctionHouse.GetNumReplicateItems()
    numberOfProcessedAuctions = numberOfProcessedAuctions + 1
    if numberOfProcessedAuctions % 10000 == 0 then
        print(numberOfProcessedAuctions .. ' / ' .. numberOfReplicateItems)
    end
    if numberOfProcessedAuctions >= numberOfReplicateItems then
        coroutine.resume(thread)
    end
end

function AddOn.buildItemInfoCache2()
    local i = 0
    for _, auction in ipairs(auctions) do
        i = i + 1
        if i % 10000 == 0 then
            print(i .. ' / ' .. #auctions)
        end
        local itemLink = auction.itemLink
        local itemInfo = auction.itemInfo
        local battlePetInfo = auction.battlePetInfo
        if battlePetInfo[0] == nil and battlePetInfo[1] == nil then
            if not AddOn.isCommodityItem(itemLink) then
                local itemInfo2 = AddOn.retrieveItemInfoDeprecated(itemLink)
                local itemIdentifier = {
                    itemID = itemInfo[17],
                    itemLevel = itemInfo2.itemLevel
                }
                ItemInfoCache.store(itemIdentifier, itemInfo2)
            end
        end
    end

    hasItemInfoCache2BeenBuilt = true
end

function AddOn.onAddonLoaded(name)
    if name == 'AuctionHouseDealFinder' then
        AddOn.initializeSavedVariables()
    end
end

function AddOn.initializeSavedVariables()
    local build = select(2, GetBuildInfo())
    if itemInfoCache == nil or itemInfoCacheBuild ~= build then
        itemInfoCache = {}
        itemInfoCacheBuild = build
    end
    if itemInfoCache2 == nil or itemInfoCache2Build ~= build then
        itemInfoCache2 = {}
        itemInfoCache2Build = build
    end
end

function AddOn.showItemToBuyOut(buyoutItem)
    local itemIdentifier
    if buyoutItem.itemLink then
        itemIdentifier = buyoutItem.itemLink
    else
        itemIdentifier = select(2, GetItemInfo(buyoutItem.itemID))
    end
    local totalProfit = buyoutItem.quantity * buyoutItem.profit
    local text
    if buyoutItem.isBid then
        text = 'Bidding on'
        button:SetText('Bid')
    else
        text = 'Buying'
        button:SetText('Buy')
    end
    print(text .. ' ' .. buyoutItem.quantity .. ' x ' .. itemIdentifier .. ' (buy price: ' .. GetCoinTextureString(buyoutItem.price) .. ', profit: ' .. GetCoinTextureString(buyoutItem.profit) .. ', total profit: ' .. GetCoinTextureString(totalProfit) .. ')')
    debugPrint('auctionID: ', buyoutItem.auctionID)
    button:Show()
    coroutine.yield()
    AddOn.buyOut(buyoutItem)
end

function AddOn.buyOut(buyoutItem)
    print('AddOn.buyOut')
    button:Hide()
    if buyoutItem.commodity then
        purchase = {
            itemID = buyoutItem.itemID,
            quantity = buyoutItem.quantity,
            vendorSellPrice = buyoutItem.vendorSellPrice,
            quantity = buyoutItem.quantity
        }
        print('a', coroutine.running())

        C_AuctionHouse.StartCommoditiesPurchase(buyoutItem.itemID, buyoutItem.quantity, buyoutItem.price)
        print('b', coroutine.running())
        local _, event, unitPrice, totalPrice = Events.waitForOneOfEvents({ 'COMMODITY_PRICE_UPDATED', 'COMMODITY_PRICE_UNAVAILABLE' })
        if event == 'COMMODITY_PRICE_UPDATED' then
            if purchase.quantity * purchase.vendorSellPrice > totalPrice then
                C_AuctionHouse.ConfirmCommoditiesPurchase(purchase.itemID, purchase.quantity)
                local _, event = Events.waitForOneOfEvents({ 'COMMODITY_PURCHASE_SUCCEEDED', 'COMMODITY_PURCHASE_FAILED' })
                if event == 'COMMODITY_PURCHASE_SUCCEEDED' then
                    Seller.addItemToSell(purchase.itemID, purchase.quantity)
                end
            else
                debugPrint('onCommodityPriceUpdated: price now too high to make profit')
            end
        end
    else
        purchase = {
            itemLink = buyoutItem.itemLink,
            auctionID = buyoutItem.auctionID,
            price = buyoutItem.price,
            quantity = buyoutItem.quantity
        }
        local item = Item:CreateFromItemLink(buyoutItem.itemLink)
        AddOn.waitForItemToLoad(item)
        debugPrint('C_AuctionHouse.PlaceBid', buyoutItem.auctionID, buyoutItem.price, buyoutItem.itemLink)
        C_AuctionHouse.PlaceBid(buyoutItem.auctionID, buyoutItem.price)
        local _, event = Events.waitForOneOfEventsAndCondition({ 'AUCTION_HOUSE_PURCHASE_COMPLETED', 'AUCTION_HOUSE_SHOW_ERROR' }, function(self, event, auctionID)
            return event == 'AUCTION_HOUSE_SHOW_ERROR' or (event == 'AUCTION_HOUSE_PURCHASE_COMPLETED' and auctionID == buyoutItem.auctionID)
        end)
        if event == 'AUCTION_HOUSE_PURCHASE_COMPLETED' then
            Seller.addItemToSell(purchase.itemLink, purchase.quantity)
        end
    end
end

function AddOn.findBrowserResultForItem(browserResults, item)
    debugPrint('findBrowserResultForItem')
    debugPrint('browserResults:')
    debugPrintTable(browserResults)
    debugPrint('---')
    debugPrint('item:')
    debugPrintTable(item)
    debugPrint('---')
    for index, browserResult in ipairs(browserResults) do
        if browserResult.itemKey.itemID == item.itemID and browserResult.itemKey.itemLevel == item.itemLevel then
            return browserResult
        end
    end
    return nil
end

function AddOn.retrieveItemInfo(itemKey)
    print('A1')
    local itemInfo = ItemInfoCache.retrieve(itemKey)
    print('A2')
    if not itemInfo then
        print('A3')
        if AddOn.isCommodityItem(itemKey.itemID) then
            print('A4')
            itemInfo = AddOn.requestItemInfo2(itemKey.itemID)
            print('A5')
            ItemInfoCache.store(itemKey, itemInfo)
            print('A6')
        else
            local numberOfItemSearchResults = C_AuctionHouse.GetNumItemSearchResults(itemKey)
            if numberOfItemSearchResults == 0 then
                print('A7')
                AddOn.sendSearchQuery(itemKey, {}, false)

                print('A8')
                numberOfItemSearchResults = C_AuctionHouse.GetNumItemSearchResults(itemKey)
                print('A9')
            end
            if numberOfItemSearchResults >= 1 then
                print('A10')
                local searchResultInfo = C_AuctionHouse.GetItemSearchResultInfo(itemKey, 1)
                print('A11')
                if searchResultInfo.itemLink then
                    print('A12')
                    itemInfo = AddOn.requestItemInfo2(searchResultInfo.itemLink)
                    print('A13')
                    ItemInfoCache.store(itemKey, itemInfo)
                    print('A14')
                else
                    print('A15')
                    debugPrint('o.O')
                    print('A16')
                end
                print('A17')
            end
            print('A18')
        end
        print('A19')
    end
    print('A20')
    return itemInfo
end

function AddOn.finishCurrentPurchase()
    Seller.addItemToSell(purchase.itemLink or purchase.itemID, purchase.quantity)
    purchase = nil
end

local reshowButton = false

function AddOn.onAuctionHouseThrottledMessageSent()
    print('AUCTION_HOUSE_THROTTLED_MESSAGE_SENT')
    isThrottledSystemReady = false

    if button:IsShown() then
        reshowButton = true
        button:Hide()
    end
end

function AddOn.onAuctionHouseThrottledSystemReady()
    print('AUCTION_HOUSE_THROTTLED_SYSTEM_READY')

    isThrottledSystemReady = true

    if reshowButton then
        reshowButton = false
        button:Show()
    end
end

function AddOn.onEvent(self, event, ...)
    if event == 'ADDON_LOADED' then
        AddOn.onAddonLoaded(...)
    elseif event == 'AUCTION_HOUSE_THROTTLED_MESSAGE_SENT' then
        AddOn.onAuctionHouseThrottledMessageSent(...)
    elseif event == 'AUCTION_HOUSE_THROTTLED_SYSTEM_READY' then
        AddOn.onAuctionHouseThrottledSystemReady(...)
    elseif event == 'ITEM_SEARCH_RESULTS_UPDATED' then
        local itemKey = ...
        print('ITEM_SEARCH_RESULTS_UPDATED')
        p('itemKey', itemKey)
    elseif event == 'ITEM_SEARCH_RESULTS_ADDED' then
        local itemKey = ...
        print('ITEM_SEARCH_RESULTS_ADDED')
        p('itemKey', itemKey)
    elseif event == 'COMMODITY_SEARCH_RESULTS_UPDATED' then
        local itemID = ...
        print('COMMODITY_SEARCH_RESULTS_UPDATED')
        p('itemID', itemID)
    elseif event == 'AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED' then
        print('AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED')
    elseif event == 'AUCTION_HOUSE_BROWSE_RESULTS_UPDATED' then
        print('AUCTION_HOUSE_BROWSE_RESULTS_UPDATED')
    elseif event == 'AUCTION_HOUSE_BROWSE_RESULTS_ADDED' then
        print('AUCTION_HOUSE_BROWSE_RESULTS_ADDED')
    elseif event == 'AUCTION_HOUSE_BROWSE_FAILURE' then
        print('AUCTION_HOUSE_BROWSE_FAILURE')
    end
end

frame = CreateFrame('Frame')
frame:SetScript('OnEvent', AddOn.onEvent)
frame:RegisterEvent('ADDON_LOADED')
frame:RegisterEvent('AUCTION_HOUSE_THROTTLED_MESSAGE_SENT')
frame:RegisterEvent('AUCTION_HOUSE_THROTTLED_SYSTEM_READY')
frame:RegisterEvent('ITEM_SEARCH_RESULTS_UPDATED')
frame:RegisterEvent('ITEM_SEARCH_RESULTS_ADDED')
frame:RegisterEvent('COMMODITY_SEARCH_RESULTS_UPDATED')
frame:RegisterEvent('AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED')
frame:RegisterEvent('AUCTION_HOUSE_BROWSE_RESULTS_UPDATED')
frame:RegisterEvent('AUCTION_HOUSE_BROWSE_RESULTS_ADDED')
frame:RegisterEvent('AUCTION_HOUSE_BROWSE_FAILURE')

button = CreateFrame('Button', nil, UIParent, 'UIPanelButtonNoTooltipTemplate')
button:SetPoint('CENTER', 0, 0)
button:SetSize(300, 60)
button:SetText('Buy')
button:SetScript('OnClick', function()
    coroutine.resume(thread)
end)
button:Hide()

function checkItemLinks()
    local count = 0
    for _, auction in ipairs(auctions) do
        if auction.itemLink then
            count = count + 1
        end
    end
    return count
end

function printBuyoutQueue()
    print('buyoutQueue:')
    printTable(buyoutQueue)
    print('---')
end

function printFindAuctionsToBuyQueue()
    print('findAuctionsToBuyQueue:')
    printTable(findAuctionsToBuyQueue)
    print('---')
end

--hooksecurefunc(C_AuctionHouse, 'PlaceBid', function(...)
--    debugPrint('hook C_AuctionHouse.PlaceBid')
--    debugPrintTable({ ... })
--    debugPrint('---')
--end)
--
--hooksecurefunc(C_AuctionHouse, 'SendBrowseQuery', function(...)
--    debugPrint('hook C_AuctionHouse.SendBrowseQuery')
--    debugPrintTable({ ... })
--    debugPrint('---')
--end)
--
hooksecurefunc(C_AuctionHouse, 'SendSearchQuery', function(...)
    debugPrint('hook C_AuctionHouse.SendSearchQuery')
    debugPrintTable({ ... })
    debugPrint('---')
end)

function determineNumberOfItems()
    local countedItemIDs = {}
    local count = 0
    for _, auction in ipairs(auctions) do
        local itemInfo = auction.itemInfo
        local itemID = itemInfo[17]
        if not countedItemIDs[itemID] then
            count = count + 1
            countedItemIDs[itemID] = true
        end
    end
    return count
end

function findDeals()
    return AddOn.findDeals()
end

hooksecurefunc(C_AuctionHouse, 'StartCommoditiesPurchase', function(...)
    debugPrint('hook C_AuctionHouse.StartCommoditiesPurchase')
    debugPrintTable({ ... })
    debugPrint('---')
end)

function testCD()
    C_AuctionHouse.StartCommoditiesPurchase()
end
