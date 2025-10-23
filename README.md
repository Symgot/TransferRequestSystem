# Transfer Request System

A standalone Factorio mod that enables automatic item transfers between space platforms in the same orbit.

## Features

- **Automatic Transfers**: Platforms can request items from other platforms in the same orbit
- **Configurable Requests**: Set minimum quantity (threshold) and requested quantity (maximum)
- **UPS-Friendly**: Batched processing with configurable transfer limits
- **Deadlock Prevention**: Intelligent system prevents circular dependencies
- **Storage Validation**: Checks available storage space before transfers
- **Transfer Rules**: Optional integration with SpaceShipMod for ship-type restrictions
  - ✅ Station ↔ Station transfers allowed
  - ✅ Station ↔ Ship transfers allowed
  - ❌ Ship ↔ Ship transfers forbidden (when SpaceShipMod is installed)
- **Remote Interface**: Other mods can interact with this system via remote calls

## Usage

### Basic Usage (without GUI)

Use the remote interface to manage requests:

```lua
-- Get a platform
local platform = game.forces.player.platforms[1]

-- Register a request for iron plates
remote.call("TransferRequestSystem", "register_request", 
    platform, "iron-plate", 100, 1000)
-- This will request iron plates when available
-- Minimum 100 (only transfer if source has at least 100)
-- Requested 1000 (transfer up to 1000)

-- Remove a request
remote.call("TransferRequestSystem", "remove_request", 
    platform, "iron-plate")
```

### With SpaceShipMod

When used with SpaceShipMod, you get a full GUI:
1. Click on a cargo landing pad on your space platform
2. Select an item to request
3. Set minimum quantity (threshold)
4. Set requested quantity (maximum)
5. Click "Add Request"

Items will automatically transfer from other platforms in the same orbit.

### With CircuitRequestController

Combine with the CircuitRequestController mod for circuit network control:
1. Place a Circuit Request Controller on your platform
2. Connect circuit wires to send item signals
3. The controller will automatically create transfer requests based on signals

## Requirements

- **Factorio**: Version 2.0.0 or higher
- **Space Age DLC**: Required for space platform functionality
- **Dependencies**: None (works standalone)
- **Optional**: CircuitRequestController for circuit network control
- **Optional**: SpaceShipMod for full GUI support and ship-type restrictions

## How It Works

1. **Request Registration**: A platform registers requests for specific items
2. **Orbit Detection**: System checks which platforms are in the same orbit
3. **Source Validation**: Finds platforms with the requested items (above minimum threshold)
4. **Transfer Validation**: Checks storage space and transfer rules
5. **Cargo Pod Transfer**: Uses cargo pods to transfer items between platforms
6. **Cooldown Management**: Prevents spam with configurable cooldown periods

## Remote Interface

```lua
-- Register a transfer request
remote.call("TransferRequestSystem", "register_request", 
    platform, item_name, minimum_quantity, requested_quantity)

-- Remove a transfer request
remote.call("TransferRequestSystem", "remove_request", 
    platform, item_name)

-- Get all requests for a platform
local requests = remote.call("TransferRequestSystem", "get_requests", platform)

-- Get specific request data
local request = remote.call("TransferRequestSystem", "get_request", 
    platform, item_name)

-- Check if platform can receive items
local can_receive, reason = remote.call("TransferRequestSystem", "can_receive_items", 
    platform, item_name, quantity)
```

## Configuration

The system has several constants that can be adjusted in `transfer-request.lua`:
- `TICK_INTERVAL`: Process requests every N ticks (default: 60 = 1 second)
- `MAX_TRANSFERS_PER_TICK`: Maximum transfers per tick for UPS (default: 10)
- `TRANSFER_COOLDOWN`: Cooldown between transfers (default: 300 ticks = 5 seconds)

## License

GPL-3.0
