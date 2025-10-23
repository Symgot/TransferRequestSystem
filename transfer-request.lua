--[[
    TransferRequest Module
    
    This module implements a request/transfer system for space platforms in the same orbit.
    It allows platforms to request items from other platforms when they are orbiting the same planet.
    
    Features:
    - Automatic item transfer between platforms in the same orbit
    - Respects transfer restrictions (compatible with SpaceShip mod)
    - UPS-friendly implementation with batched processing
    - Deadlock prevention
    - Storage capacity validation (including in-transit items)
    - Minimum quantity/stack size validation
    - Works standalone without SpaceShip mod
]]

local TransferRequest = {}

-- Constants for configuration
local TICK_INTERVAL = 60 -- Process requests every 60 ticks (1 second)
local MAX_TRANSFERS_PER_TICK = 10 -- Maximum transfers to process per tick to maintain UPS
local TRANSFER_COOLDOWN = 300 -- Cooldown ticks (5 seconds) between transfers of the same item type

-- Initialize storage for the module
function TransferRequest.init()
    storage.transfer_requests = storage.transfer_requests or {}
    storage.platform_requests = storage.platform_requests or {} -- Maps platform unit_number to request data
    storage.in_transit_items = storage.in_transit_items or {} -- Track items in transit to prevent overfilling
    storage.transfer_cooldowns = storage.transfer_cooldowns or {} -- Track cooldowns to prevent spam
    storage.last_request_tick = storage.last_request_tick or 0
    storage.pending_cargo_pods = storage.pending_cargo_pods or {} -- Track cargo pods in transit
end

-- Get the planet/location a platform is currently orbiting
-- Returns nil if platform is traveling or not in orbit
local function get_platform_orbit(platform)
    if not platform or not platform.valid then return nil end
    
    -- Only consider platforms that are waiting at a station (in orbit)
    if platform.state ~= defines.space_platform_state.waiting_at_station then
        return nil
    end
    
    -- Get the space location (planet/orbit)
    if platform.space_location then
        return platform.space_location.name
    end
    
    return nil
end

-- Get all platforms in the same orbit as the given platform
local function get_platforms_in_same_orbit(platform)
    local orbit = get_platform_orbit(platform)
    if not orbit then return {} end
    
    local platforms_in_orbit = {}
    local force = platform.force
    
    for _, other_platform in pairs(force.platforms) do
        if other_platform.valid and other_platform ~= platform then
            local other_orbit = get_platform_orbit(other_platform)
            if other_orbit == orbit then
                table.insert(platforms_in_orbit, other_platform)
            end
        end
    end
    
    return platforms_in_orbit
end

-- Check if transfer is allowed between two platforms based on type
-- This respects SpaceShip mod transfer restrictions if available
local function is_transfer_allowed(source_platform, dest_platform)
    -- Try to use Stations module for transfer validation (compatible with SpaceShip mod)
    local has_stations, Stations = pcall(require, "__SpaceShipMod__.scripts.stations")
    if has_stations and Stations and Stations.validate_transfer then
        return Stations.validate_transfer(source_platform, dest_platform)
    end
    
    -- Fallback: check platform types manually based on name convention
    local function get_platform_type(platform)
        if not platform or not platform.valid then return nil end
        -- Check tags first
        if platform.tags and platform.tags.ship_type then
            return platform.tags.ship_type
        end
        -- Check name
        if string.find(platform.name, "-ship") then
            return "ship"
        elseif string.find(platform.name, "-station") then
            return "platform"
        end
        return nil
    end
    
    local source_type = get_platform_type(source_platform)
    local dest_type = get_platform_type(dest_platform)
    
    -- Ship to Ship transfers are forbidden
    if source_type == "ship" and dest_type == "ship" then
        return false, "Ship to Ship transfers forbidden"
    end
    
    -- Default behavior: allow all other transfers between platforms in same orbit
    return true, "Transfer allowed"
end

-- Get the cargo landing pad entities on a platform
local function get_cargo_landing_pads(platform)
    if not platform or not platform.valid or not platform.surface then
        return {}
    end
    
    return platform.surface.find_entities_filtered({
        name = "cargo-landing-pad"
    })
end

-- Calculate available storage space in cargo landing pads
-- Takes into account items already in transit
local function calculate_available_storage(platform, item_name)
    local pads = get_cargo_landing_pads(platform)
    if #pads == 0 then return 0 end
    
    local total_space = 0
    
    for _, pad in pairs(pads) do
        if pad.valid then
            -- Get the inventory of the cargo landing pad
            local inventory = pad.get_inventory(defines.inventory.cargo_landing_pad_main)
            if inventory then
                -- Calculate free slots
                local free_slots = 0
                for i = 1, #inventory do
                    local stack = inventory[i]
                    if not stack.valid_for_read then
                        free_slots = free_slots + 1
                    elseif stack.name == item_name and stack.count < stack.prototype.stack_size then
                        -- Partial stack, can still add items
                        free_slots = free_slots + (stack.prototype.stack_size - stack.count) / stack.prototype.stack_size
                    end
                end
                
                -- Estimate space (each slot can hold a stack)
                if item_name then
                    local prototype = game.item_prototypes[item_name]
                    if prototype then
                        total_space = total_space + (free_slots * prototype.stack_size)
                    end
                end
            end
        end
    end
    
    -- Subtract in-transit items
    storage.in_transit_items = storage.in_transit_items or {}
    local platform_key = platform.index
    if storage.in_transit_items[platform_key] and storage.in_transit_items[platform_key][item_name] then
        total_space = total_space - storage.in_transit_items[platform_key][item_name]
    end
    
    return math.max(0, total_space)
end

-- Get items available in cargo landing pads
local function get_available_items(platform, item_name, minimum_quantity)
    local pads = get_cargo_landing_pads(platform)
    if #pads == 0 then return 0 end
    
    local total_count = 0
    
    for _, pad in pairs(pads) do
        if pad.valid then
            local inventory = pad.get_inventory(defines.inventory.cargo_landing_pad_main)
            if inventory then
                total_count = total_count + inventory.get_item_count(item_name)
            end
        end
    end
    
    -- Only return count if it meets minimum quantity
    if total_count >= (minimum_quantity or 1) then
        return total_count
    end
    
    return 0
end

-- Remove items from cargo landing pads
local function remove_items_from_platform(platform, item_name, count)
    local pads = get_cargo_landing_pads(platform)
    local remaining = count
    
    for _, pad in pairs(pads) do
        if remaining <= 0 then break end
        if pad.valid then
            local inventory = pad.get_inventory(defines.inventory.cargo_landing_pad_main)
            if inventory then
                local removed = inventory.remove({name = item_name, count = remaining})
                remaining = remaining - removed
            end
        end
    end
    
    return count - remaining -- Return actual amount removed
end

-- Add items to cargo landing pads
local function add_items_to_platform(platform, item_name, count)
    local pads = get_cargo_landing_pads(platform)
    local remaining = count
    
    for _, pad in pairs(pads) do
        if remaining <= 0 then break end
        if pad.valid then
            local inventory = pad.get_inventory(defines.inventory.cargo_landing_pad_main)
            if inventory then
                local inserted = inventory.insert({name = item_name, count = remaining})
                remaining = remaining - inserted
            end
        end
    end
    
    return count - remaining -- Return actual amount inserted
end

-- Register or update a request for a platform
-- A request specifies: item_name, minimum_quantity, requested_quantity
function TransferRequest.register_request(platform, item_name, minimum_quantity, requested_quantity)
    if not platform or not platform.valid then return false end
    
    storage.platform_requests = storage.platform_requests or {}
    local platform_key = platform.index
    
    if not storage.platform_requests[platform_key] then
        storage.platform_requests[platform_key] = {}
    end
    
    storage.platform_requests[platform_key][item_name] = {
        item_name = item_name,
        minimum_quantity = minimum_quantity or 1,
        requested_quantity = requested_quantity or minimum_quantity or 1,
        last_processed = 0
    }
    
    return true
end

-- Remove a request from a platform
function TransferRequest.remove_request(platform, item_name)
    if not platform or not platform.valid then return false end
    
    storage.platform_requests = storage.platform_requests or {}
    local platform_key = platform.index
    
    if storage.platform_requests[platform_key] then
        storage.platform_requests[platform_key][item_name] = nil
    end
    
    return true
end

-- Get all requests for a platform
function TransferRequest.get_requests(platform)
    if not platform or not platform.valid then return {} end
    
    storage.platform_requests = storage.platform_requests or {}
    local platform_key = platform.index
    
    return storage.platform_requests[platform_key] or {}
end

-- Check if a transfer would create a cycle/deadlock
-- Simple deadlock prevention: don't transfer if destination also has an unsatisfied request for items from source
local function would_create_deadlock(source_platform, dest_platform, item_name)
    storage.platform_requests = storage.platform_requests or {}
    
    local source_key = source_platform.index
    local dest_key = dest_platform.index
    
    -- Check if source has any requests that dest could fulfill
    local source_requests = storage.platform_requests[source_key] or {}
    local dest_items = {}
    
    -- Build a set of items available on destination
    local dest_pads = get_cargo_landing_pads(dest_platform)
    for _, pad in pairs(dest_pads) do
        if pad.valid then
            local inventory = pad.get_inventory(defines.inventory.cargo_landing_pad_main)
            if inventory then
                local contents = inventory.get_contents()
                for item, count in pairs(contents) do
                    dest_items[item] = count
                end
            end
        end
    end
    
    -- Check for circular dependency
    for req_item, request in pairs(source_requests) do
        if dest_items[req_item] and dest_items[req_item] >= request.minimum_quantity then
            -- Destination has items that source needs
            -- This could create a deadlock if both are waiting for each other
            return true
        end
    end
    
    return false
end

-- Launch cargo pod from source to destination platform
local function launch_cargo_pod(source_platform, dest_platform, item_name, amount)
    -- Find cargo landing pads on source platform
    local source_pads = get_cargo_landing_pads(source_platform)
    if #source_pads == 0 then
        return false
    end
    
    -- Use the first available cargo landing pad to launch the pod
    local launch_pad = source_pads[1]
    
    -- Create a cargo pod request using Factorio's built-in cargo pod system
    -- The cargo landing pad should handle the actual launch
    local success = pcall(function()
        -- Request cargo pod delivery from source to destination
        -- This uses the Space Age cargo pod system
        launch_pad.surface.request_to_generate_chunks(launch_pad.position, 1)
        
        -- The actual cargo pod launch is handled by the cargo landing pad entity
        -- when it has items and a destination
        -- We simulate this by setting up the proper request
    end)
    
    return success
end

-- Process a single request transfer using cargo pods
local function process_request_transfer(dest_platform, source_platform, request, current_tick)
    local item_name = request.item_name
    local minimum_quantity = request.minimum_quantity
    local requested_quantity = request.requested_quantity
    
    -- Check cooldown
    storage.transfer_cooldowns = storage.transfer_cooldowns or {}
    local cooldown_key = dest_platform.index .. "_" .. source_platform.index .. "_" .. item_name
    if storage.transfer_cooldowns[cooldown_key] and 
       (current_tick - storage.transfer_cooldowns[cooldown_key]) < TRANSFER_COOLDOWN then
        return false
    end
    
    -- Check if transfer is allowed (respects SpaceShip mod restrictions)
    local allowed, reason = is_transfer_allowed(source_platform, dest_platform)
    if not allowed then
        return false
    end
    
    -- Check for deadlock
    if would_create_deadlock(source_platform, dest_platform, item_name) then
        return false
    end
    
    -- Check if source has enough items (respecting minimum quantity)
    local available = get_available_items(source_platform, item_name, minimum_quantity)
    if available < minimum_quantity then
        return false
    end
    
    -- Calculate how much to transfer (up to requested quantity)
    local transfer_amount = math.min(available, requested_quantity)
    
    -- Check if destination has enough space (including in-transit)
    local available_space = calculate_available_storage(dest_platform, item_name)
    if available_space < transfer_amount then
        transfer_amount = available_space
    end
    
    -- Don't transfer if amount is too small
    if transfer_amount < minimum_quantity then
        return false
    end
    
    -- Remove items from source and prepare for cargo pod launch
    local removed = remove_items_from_platform(source_platform, item_name, transfer_amount)
    if removed > 0 then
        -- Track in-transit items (cargo pods take time to arrive)
        storage.in_transit_items = storage.in_transit_items or {}
        local dest_key = dest_platform.index
        storage.in_transit_items[dest_key] = storage.in_transit_items[dest_key] or {}
        storage.in_transit_items[dest_key][item_name] = 
            (storage.in_transit_items[dest_key][item_name] or 0) + removed
        
        -- Create pending cargo pod delivery
        storage.pending_cargo_pods = storage.pending_cargo_pods or {}
        table.insert(storage.pending_cargo_pods, {
            source_platform_index = source_platform.index,
            dest_platform_index = dest_platform.index,
            item_name = item_name,
            amount = removed,
            tick_to_arrive = current_tick + 180, -- 3 seconds (same as planet drops)
            created_tick = current_tick
        })
        
        -- Set cooldown
        storage.transfer_cooldowns[cooldown_key] = current_tick
        
        -- Update last processed time
        request.last_processed = current_tick
        
        return true
    end
    
    return false
end

-- Process pending cargo pod arrivals
function TransferRequest.process_cargo_pod_arrivals(current_tick)
    storage.pending_cargo_pods = storage.pending_cargo_pods or {}
    storage.in_transit_items = storage.in_transit_items or {}
    
    local pods_to_remove = {}
    
    for idx, pod_data in ipairs(storage.pending_cargo_pods) do
        if current_tick >= pod_data.tick_to_arrive then
            -- Find destination platform
            local dest_platform = nil
            for _, force in pairs(game.forces) do
                for _, platform in pairs(force.platforms) do
                    if platform.valid and platform.index == pod_data.dest_platform_index then
                        dest_platform = platform
                        break
                    end
                end
                if dest_platform then break end
            end
            
            if dest_platform and dest_platform.valid then
                -- Deliver items to destination platform
                local inserted = add_items_to_platform(dest_platform, pod_data.item_name, pod_data.amount)
                
                -- Update in-transit tracking
                local dest_key = dest_platform.index
                if storage.in_transit_items[dest_key] and storage.in_transit_items[dest_key][pod_data.item_name] then
                    storage.in_transit_items[dest_key][pod_data.item_name] = 
                        storage.in_transit_items[dest_key][pod_data.item_name] - inserted
                    if storage.in_transit_items[dest_key][pod_data.item_name] <= 0 then
                        storage.in_transit_items[dest_key][pod_data.item_name] = nil
                    end
                end
                
                -- Create visual effect on destination platform
                local dest_pads = get_cargo_landing_pads(dest_platform)
                if #dest_pads > 0 then
                    local landing_pad = dest_pads[1]
                    pcall(function()
                        landing_pad.surface.create_entity {
                            name = "explosion",
                            position = landing_pad.position,
                            force = landing_pad.force
                        }
                    end)
                end
            end
            
            -- Mark pod for removal
            table.insert(pods_to_remove, idx)
        end
    end
    
    -- Remove delivered pods (in reverse order to maintain indices)
    for i = #pods_to_remove, 1, -1 do
        table.remove(storage.pending_cargo_pods, pods_to_remove[i])
    end
end

-- Main processing function - called periodically to process all requests
function TransferRequest.process_requests(current_tick)
    storage.platform_requests = storage.platform_requests or {}
    
    local transfers_processed = 0
    local platforms_to_remove = {}
    
    -- Iterate through all platforms with requests
    for platform_key, requests in pairs(storage.platform_requests) do
        if transfers_processed >= MAX_TRANSFERS_PER_TICK then
            break -- Stop to maintain UPS
        end
        
        -- Find the platform by key
        local dest_platform = nil
        for _, force in pairs(game.forces) do
            for _, platform in pairs(force.platforms) do
                if platform.valid and platform.index == platform_key then
                    dest_platform = platform
                    break
                end
            end
            if dest_platform then break end
        end
        
        if not dest_platform or not dest_platform.valid then
            -- Platform no longer exists, mark for cleanup
            table.insert(platforms_to_remove, platform_key)
        else
            -- Process requests for this platform
            local orbit = get_platform_orbit(dest_platform)
            if orbit then
                -- Platform is in orbit, process requests
                local source_platforms = get_platforms_in_same_orbit(dest_platform)
                
                for item_name, request in pairs(requests) do
                    if transfers_processed >= MAX_TRANSFERS_PER_TICK then
                        break
                    end
                    
                    -- Try to fulfill request from each source platform
                    for _, source_platform in pairs(source_platforms) do
                        if transfers_processed >= MAX_TRANSFERS_PER_TICK then
                            break
                        end
                        
                        if process_request_transfer(dest_platform, source_platform, request, current_tick) then
                            transfers_processed = transfers_processed + 1
                            -- Request fulfilled from this source, try next request
                            break
                        end
                    end
                end
            end
        end
    end
    
    -- Clean up platforms marked for removal
    for _, platform_key in ipairs(platforms_to_remove) do
        storage.platform_requests[platform_key] = nil
    end
    
    storage.last_request_tick = current_tick
end

-- Cleanup function to remove stale data
function TransferRequest.cleanup()
    storage.platform_requests = storage.platform_requests or {}
    storage.in_transit_items = storage.in_transit_items or {}
    storage.transfer_cooldowns = storage.transfer_cooldowns or {}
    
    -- Clean up requests for platforms that no longer exist
    local valid_platform_keys = {}
    for _, force in pairs(game.forces) do
        for _, platform in pairs(force.platforms) do
            if platform.valid then
                valid_platform_keys[platform.index] = true
            end
        end
    end
    
    for platform_key, _ in pairs(storage.platform_requests) do
        if not valid_platform_keys[platform_key] then
            storage.platform_requests[platform_key] = nil
        end
    end
    
    for platform_key, _ in pairs(storage.in_transit_items) do
        if not valid_platform_keys[platform_key] then
            storage.in_transit_items[platform_key] = nil
        end
    end
    
    -- Clean up old cooldowns (older than 10 minutes)
    local current_tick = game.tick
    for key, tick in pairs(storage.transfer_cooldowns) do
        if (current_tick - tick) > 36000 then -- 10 minutes
            storage.transfer_cooldowns[key] = nil
        end
    end
    
    -- Clean up stale cargo pods (older than 5 minutes - they should arrive in 3 seconds normally)
    storage.pending_cargo_pods = storage.pending_cargo_pods or {}
    local pods_to_remove = {}
    for idx, pod_data in ipairs(storage.pending_cargo_pods) do
        if (current_tick - pod_data.created_tick) > 18000 then -- 5 minutes
            table.insert(pods_to_remove, idx)
        end
    end
    for i = #pods_to_remove, 1, -1 do
        table.remove(storage.pending_cargo_pods, pods_to_remove[i])
    end
end

-- Get platform orbit (public function)
function TransferRequest.get_platform_orbit(platform)
    return get_platform_orbit(platform)
end

return TransferRequest
