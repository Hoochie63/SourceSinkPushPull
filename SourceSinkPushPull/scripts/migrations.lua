-- SSPP by jagoly

local flib_migration = require("__flib__.migration")

--------------------------------------------------------------------------------

local migrations = {
    ["0.2.0"] = function()
        if storage.player_states then
            storage.player_guis = storage.player_states
            storage.player_states = nil
        end
        for _, station in pairs(storage.stations) do
            if station.stop.valid then
                station.network = station.stop.surface.name
            end
        end
        for _, entity in pairs(storage.entities) do
            if entity.valid then
                if entity.name == "sspp-provide-io" then
                    local json = helpers.json_to_table(entity.combinator_description) --[[@as table]]
                    local provide_items = {} ---@type {[ItemKey]: ProvideItem}
                    for item_key, item in pairs(json) do
                        if item[1] then goto skip end
                        provide_items[item_key] = { list_index = item.list_index, push = item.push, throughput = item.throughput, latency = item.latency, granularity = item.granularity }
                    end
                    entity.combinator_description = provide_items_to_combinator_description(provide_items)
                    ::skip::
                end
                if entity.name == "sspp-request-io" then
                    local json = helpers.json_to_table(entity.combinator_description) --[[@as table]]
                    local request_items = {} ---@type {[ItemKey]: RequestItem}
                    for item_key, item in pairs(json) do
                        if item[1] then goto skip end
                        request_items[item_key] = { list_index = item.list_index, pull = item.pull, throughput = item.throughput, latency = item.latency }
                    end
                    entity.combinator_description = request_items_to_combinator_description(request_items)
                    ::skip::
                end
            end
        end
    end,
    ["0.3.0"] = function()
        for _, network in pairs(storage.networks) do
            for _, class in pairs(network.classes) do
                if class.bypass_depot == nil then
                    class.bypass_depot = true
                end
            end
            if network.depot_haulers then
                network.to_depot_haulers = {}
                network.at_depot_haulers = {}
                for _, hauler_id in pairs(network.depot_haulers) do
                    local hauler = storage.haulers[hauler_id]
                    if hauler.train.valid then
                        if hauler.train.state == defines.train_state.wait_station then
                            list_append_or_create(network.at_depot_haulers, hauler.class, hauler.train.id)
                            hauler.at_depot = ""
                            hauler.to_depot = nil
                        else
                            list_append_or_create(network.to_depot_haulers, hauler.class, hauler.train.id)
                            hauler.to_depot = ""
                        end
                    end
                end
                network.depot_haulers = nil
            end
            if network.liquidate_haulers then
                network.to_depot_liquidate_haulers = {}
                network.at_depot_liquidate_haulers = {}
                for _, hauler_id in pairs(network.liquidate_haulers) do
                    local hauler = storage.haulers[hauler_id]
                    if hauler.train.valid then
                        if hauler.train.state == defines.train_state.wait_station then
                            list_append_or_create(network.at_depot_liquidate_haulers, hauler.to_liquidate, hauler.train.id)
                            hauler.at_depot = hauler.to_liquidate
                            hauler.to_liquidate = nil
                        else
                            list_append_or_create(network.to_depot_liquidate_haulers, hauler.to_liquidate, hauler.train.id)
                            hauler.to_depot = hauler.to_liquidate
                            hauler.to_liquidate = nil
                        end
                    end
                end
                network.liquidate_haulers = nil
            end
        end
    end,
    ["0.3.2"] = function()
        for _, network in pairs(storage.networks) do
            for _, class in pairs(network.classes) do
                class.list_index = nil
            end
            for _, item in pairs(network.items) do
                item.list_index = nil
            end
        end
    end,
    ["0.3.4"] = function()
        for _, station in pairs(storage.stations) do
            if station.stop.valid then
                station.stop.trains_limit = 4294967295
            end
        end
    end,
    ["0.3.5"] = function()
        for _, station in pairs(storage.stations) do
            if station.stop.valid then
                if station.provide_items then
                    for _, item in pairs(station.provide_items) do
                        item.list_index = nil
                    end
                end
                if station.request_items then
                    for _, item in pairs(station.request_items) do
                        item.list_index = nil
                    end
                end
            end
        end
        for _, network in pairs(storage.networks) do
            for _, class in pairs(network.classes) do
                class.item_slot_capacity = nil
                class.fluid_capacity = nil
            end
        end
    end,
    ["0.3.9"] = function()
        for _, station in pairs(storage.stations) do
            if station.stop.valid then
                if station.stop.trains_limit == 4294967295 then
                    station.stop.trains_limit = 10
                end
            end
        end
    end,
    ["0.3.12"] = function()
        for _, station in pairs(storage.stations) do
            if station.provide_items then
                for _, item in pairs(station.provide_items) do
                    if item.mode == nil then
                        item.mode = item.push and 5 or 2
                        item.push = nil
                    end
                end
            end
            if station.request_items then
                for _, item in pairs(station.request_items) do
                    if item.mode == nil then
                        item.mode = item.pull and 5 or 2
                        item.pull = nil
                    end
                end
            end
        end
    end,
    ["0.3.18"] = function()
        for _, network in pairs(storage.networks) do
            if not network.buffer_haulers then
                network.buffer_haulers = {}
            end
        end
    end,
    ["0.3.23"] = function()
        local function try_init_job(network, hauler_id, job_type)
            local hauler = storage.haulers[hauler_id]
            if not hauler.train.valid then return nil, nil end
            local job = { hauler = hauler_id, type = job_type, start_tick = game.tick } ---@type Job
            local job_index = network.job_index_counter + 1
            hauler.job = job_index
            network.job_index_counter = job_index
            network.jobs[job_index] = job
            return job, hauler
        end
        for _, network in pairs(storage.networks) do
            if not network.job_index_counter then
                network.job_index_counter = 0
                network.jobs = {}
                for item_key, hauler_ids in pairs(network.buffer_haulers) do
                    for _, hauler_id in pairs(hauler_ids) do
                        local job, hauler = try_init_job(network, hauler_id, item_key)
                        if job then ---@cast hauler -nil
                            job.provide_stop = storage.entities[hauler.to_provide.station]
                            if hauler.to_provide.phase ~= "TRAVEL" then
                                job.target_count = network.items[item_key].delivery_size
                                job.provide_arrive_tick = game.tick
                                if hauler.to_provide.phase == "DONE" then job.provide_done_tick = game.tick end
                            end
                        end
                    end
                end
                for item_key, hauler_ids in pairs(network.provide_haulers) do
                    for _, hauler_id in pairs(hauler_ids) do
                        local job, hauler = try_init_job(network, hauler_id, item_key)
                        if job then ---@cast hauler -nil
                            job.provide_stop = storage.entities[hauler.to_provide.station]
                            if hauler.to_provide.phase ~= "TRAVEL" then
                                job.target_count = network.items[item_key].delivery_size
                                job.provide_arrive_tick = game.tick
                                if hauler.to_provide.phase == "DONE" then job.provide_done_tick = game.tick end
                            end
                        end
                    end
                end
                for item_key, hauler_ids in pairs(network.request_haulers) do
                    for _, hauler_id in pairs(hauler_ids) do
                        local job, hauler = try_init_job(network, hauler_id, item_key)
                        if job then ---@cast hauler -nil
                            job.request_stop = storage.entities[hauler.to_request.station]
                            if hauler.to_request.phase ~= "TRAVEL" then
                                job.loaded_count = get_train_item_count(hauler.train, network.items[item_key].name, network.items[item_key].quality)
                                job.request_arrive_tick = game.tick
                                if hauler.to_request.phase == "DONE" then job.finish_tick = game.tick end
                            end
                        end
                    end
                end
                for _, hauler_ids in pairs(network.fuel_haulers) do
                    for _, hauler_id in pairs(hauler_ids) do
                        local job, hauler = try_init_job(network, hauler_id, "FUEL")
                        if job then ---@cast hauler -nil
                            if hauler.to_fuel == "TRANSFER" then
                                job.fuel_stop = hauler.train.station
                                job.fuel_arrive_tick = game.tick
                            end
                        end
                    end
                end
            end
        end
    end
}

--------------------------------------------------------------------------------

---@param data ConfigurationChangedData
function on_config_changed(data)
    flib_migration.on_config_changed(data, migrations)

    -- remove invalid network items
    for _, network in pairs(storage.networks) do
        for item_key, _ in pairs(network.items) do
            if is_item_key_invalid(item_key) then network.items[item_key] = nil end
        end
        for job_index, job in pairs(network.jobs) do
            if job.item and is_item_key_invalid(job.item) then network.jobs[job_index] = nil end
        end
    end

    -- check entities
    for _, entity in pairs(storage.entities) do
        if not entity.valid then goto reboot end
    end
    -- check station items
    for _, station in pairs(storage.stations) do
        if station.provide_items then
            for item_key, _ in pairs(station.provide_items) do
                if is_item_key_invalid(item_key) then goto reboot end
            end
        end
        if station.request_items then
            for item_key, _ in pairs(station.request_items) do
                if is_item_key_invalid(item_key) then goto reboot end
            end
        end
    end
    -- check hauler trains and items
    for _, hauler in pairs(storage.haulers) do
        if not hauler.train.valid then goto reboot end
        if hauler.status_item and is_item_key_invalid(hauler.status_item) then goto reboot end
        if hauler.to_provide and is_item_key_invalid(hauler.to_provide.item) then goto reboot end
        if hauler.to_request and is_item_key_invalid(hauler.to_request.item) then goto reboot end
        if hauler.to_depot and hauler.to_depot ~= "" and is_item_key_invalid(hauler.to_depot) then goto reboot end
        if hauler.at_depot and hauler.at_depot ~= "" and is_item_key_invalid(hauler.at_depot) then goto reboot end
    end
    goto skip_reboot

    ::reboot::
    main.reboot()
    ::skip_reboot::

    storage.tick_state = "INITIAL"
end
