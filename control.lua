local TransferRequest = require("transfer-request")

-- Initialize mod when first loaded
script.on_init(function()
    TransferRequest.init()
end)

-- Handle configuration changes (mod updates)
script.on_configuration_changed(function()
    TransferRequest.init()
end)

-- Handle GUI events for cargo landing pads
script.on_event(defines.events.on_gui_opened, function(event)
    local player = game.get_player(event.player_index)
    if not player or not player.valid then return end
    
    -- Handle cargo landing pad opening for transfer requests
    if event.entity and event.entity.valid and event.entity.name == "cargo-landing-pad" then
        local surface = event.entity.surface
        if surface and surface.platform then
            -- Try to use SpaceShipMod's GUI if available
            if remote.interfaces["SpaceShipMod"] and remote.interfaces["SpaceShipMod"]["create_transfer_request_gui"] then
                remote.call("SpaceShipMod", "create_transfer_request_gui", player, event.entity)
            else
                -- Fallback: show a simple message
                player.print("[Transfer Request System] GUI not available. Install SpaceShipMod for full GUI support.")
                player.print("[Transfer Request System] Use remote interface to manage requests programmatically.")
            end
        end
    end
end)

script.on_event(defines.events.on_gui_closed, function(event)
    local player = game.get_player(event.player_index)
    if not player or not player.valid then return end
    
    -- Close transfer request GUI if cargo landing pad was closed
    if event.entity and event.entity.valid and event.entity.name == "cargo-landing-pad" then
        if player.gui.screen["transfer-request-gui"] then
            player.gui.screen["transfer-request-gui"].destroy()
        end
    end
end)

script.on_event(defines.events.on_gui_click, function(event)
    -- Try to use SpaceShipMod's GUI handler if available
    if remote.interfaces["SpaceShipMod"] and remote.interfaces["SpaceShipMod"]["handle_transfer_request_buttons"] then
        remote.call("SpaceShipMod", "handle_transfer_request_buttons", event)
    end
end)

-- Process transfer requests and cargo pod arrivals
script.on_event(defines.events.on_tick, function(event)
    -- Process transfer requests between platforms (every second)
    if game.tick % 60 == 0 then
        TransferRequest.process_requests(game.tick)
    end
    
    -- Process cargo pod arrivals every tick (they need to arrive on time)
    TransferRequest.process_cargo_pod_arrivals(game.tick)
    
    -- Periodic cleanup (every 5 minutes)
    if game.tick % 18000 == 0 then
        TransferRequest.cleanup()
    end
end)

-- Provide remote interface for other mods to interact with this mod
remote.add_interface("TransferRequestSystem", {
    -- Get module reference for other mods
    get_module = function()
        return TransferRequest
    end,
    
    -- Register a transfer request
    register_request = function(platform, item_name, minimum_quantity, requested_quantity)
        return TransferRequest.register_request(platform, item_name, minimum_quantity, requested_quantity)
    end,
    
    -- Remove a transfer request
    remove_request = function(platform, item_name)
        return TransferRequest.remove_request(platform, item_name)
    end,
    
    -- Get all requests for a platform
    get_requests = function(platform)
        return TransferRequest.get_requests(platform)
    end,
    
    -- Get request data for a specific item on a platform
    get_request = function(platform, item_name)
        return TransferRequest.get_request(platform, item_name)
    end,
    
    -- Check if a platform can receive items
    can_receive_items = function(platform, item_name, quantity)
        return TransferRequest.can_receive_items(platform, item_name, quantity)
    end
})
