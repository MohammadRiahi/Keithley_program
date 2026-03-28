--[[
CV_Sweep_V_MeasI.tsp

Interactive cyclic voltammetry script for 2450 SMU family.
- Prompts parameters on instrument screen (no hard-coded run values required)
- Sources voltage and measures current
- Supports configurable number of cycles
- Overlays each cycle on the instrument graph
- Saves one timestamped CSV per run to /usb1/ when requested
]]

reset()

-- Defaults shown in prompts
local defaults = {
    start_voltage = -0.4,   -- V
    stop_voltage = 0.6,     -- V
    scan_rate_mv_s = 15.0,  -- mV/s
    sample_rate_sps = 100,  -- samples/s
    current_limit = 1e-3,   -- A
    num_cycles = 1
}

local params = {
    start_voltage = defaults.start_voltage,
    stop_voltage = defaults.stop_voltage,
    scan_rate = defaults.scan_rate_mv_s / 1000.0, -- V/s
    sample_rate = defaults.sample_rate_sps,
    current_limit = defaults.current_limit,
    num_cycles = defaults.num_cycles,
    save_to_usb = 0
}

local function prompt_parameters()
    local v

    v = display.input.number("Start potential (V)", display.NFORMAT_DECIMAL, defaults.start_voltage, -20, 20)
    if v == nil then return false end
    params.start_voltage = v

    v = display.input.number("Stop potential (V)", display.NFORMAT_DECIMAL, defaults.stop_voltage, -20, 20)
    if v == nil then return false end
    params.stop_voltage = v

    v = display.input.number("Scan rate (mV/s)", display.NFORMAT_DECIMAL, defaults.scan_rate_mv_s, 0.1, 3500)
    if v == nil then return false end
    params.scan_rate = v / 1000.0

    v = display.input.number("Samples per second", display.NFORMAT_DECIMAL, defaults.sample_rate_sps, 0.1, 100)
    if v == nil then return false end
    params.sample_rate = v

    v = display.input.number("Number of cycles", display.NFORMAT_INTEGER, defaults.num_cycles, 1, 100)
    if v == nil then return false end
    params.num_cycles = v

    v = display.input.number("Current limit (A)", display.NFORMAT_DECIMAL, defaults.current_limit, 1e-9, 1)
    if v == nil then return false end
    params.current_limit = v

    local save_ans = display.input.prompt(display.BUTTONS_YESNO, "Save CSV to USB?")
    if save_ans == display.BUTTON_YES then
        params.save_to_usb = 1
    else
        params.save_to_usb = 0
    end

    return true
end

local function config_smu(source_range)
    smu.source.func = smu.FUNC_DC_VOLTAGE
    smu.measure.func = smu.FUNC_DC_CURRENT
    smu.source.range = source_range
    smu.source.autorange = smu.OFF
    smu.source.ilimit.level = params.current_limit
    smu.source.readback = smu.OFF
    smu.source.offmode = smu.OFFMODE_HIGHZ

    smu.measure.range = params.current_limit
    smu.measure.autorange = smu.OFF
    smu.measure.nplc = 0.01
    smu.measure.sense = smu.SENSE_2WIRE
    smu.measure.autozero.enable = smu.OFF
end

local function build_source_list(start_v, stop_v, points_per_half)
    if smu.source.output == smu.ON then
        smu.source.output = smu.OFF
    end

    if smu.source.configlist.size("CV_SOURCE_LIST") > 0 then
        smu.source.configlist.delete("CV_SOURCE_LIST")
    end
    smu.source.configlist.create("CV_SOURCE_LIST")

    local step = (stop_v - start_v) / (points_per_half - 1)
    for i = 1, points_per_half do
        smu.source.level = start_v + step * (i - 1)
        smu.source.configlist.store("CV_SOURCE_LIST")
    end
    for i = 1, points_per_half do
        smu.source.level = stop_v - step * (i - 1)
        smu.source.configlist.store("CV_SOURCE_LIST")
    end
end

local function config_timer(interval_s, count)
    local N = 1
    trigger.timer[N].enable = 0
    trigger.timer[N].reset()
    trigger.timer[N].clear()
    trigger.timer[N].enable = 1
    trigger.timer[N].delay = interval_s
    trigger.timer[N].count = count
    trigger.timer[N].start.stimulus = trigger.EVENT_NOTIFY1
    trigger.timer[N].start.generate = trigger.OFF
end

local function build_trigger_model(target_buffer, list_count)
    trigger.model.load("Empty")

    local b = 1
    trigger.model.setblock(b, trigger.BLOCK_BUFFER_CLEAR, target_buffer)

    b = b + 1
    trigger.model.setblock(b, trigger.BLOCK_CONFIG_RECALL, "CV_SOURCE_LIST", 1)

    b = b + 1
    trigger.model.setblock(b, trigger.BLOCK_SOURCE_OUTPUT, smu.ON)

    b = b + 1
    trigger.model.setblock(b, trigger.BLOCK_NOTIFY, trigger.EVENT_NOTIFY1)

    b = b + 1
    local loop_start = b
    trigger.model.setblock(b, trigger.BLOCK_WAIT, trigger.EVENT_TIMER1)

    b = b + 1
    trigger.model.setblock(b, trigger.BLOCK_MEASURE_DIGITIZE, target_buffer, 1)

    b = b + 1
    trigger.model.setblock(b, trigger.BLOCK_CONFIG_NEXT, "CV_SOURCE_LIST")

    b = b + 1
    trigger.model.setblock(b, trigger.BLOCK_BRANCH_COUNTER, list_count, loop_start)

    b = b + 1
    trigger.model.setblock(b, trigger.BLOCK_SOURCE_OUTPUT, smu.OFF)
end

local function save_cycles_csv(cycle_buffers)
    if params.save_to_usb == 0 then
        print("CSV save skipped by user")
        return
    end

    if file.usbdriveexists() == 0 then
        print("USB drive not detected; CSV not saved")
        return
    end

    local filename = string.format("/usb1/CV_run_%s_%s.csv", localnode.model, os.date("%Y%m%d_%H%M%S", gettime()))
    local f = io.open(filename, "w+")
    if f == nil then
        print("Failed to create CSV: " .. filename)
        return
    end

    f:write("# Model," .. localnode.model .. "\n")
    if localnode.serialno ~= nil then
        f:write("# Serial," .. localnode.serialno .. "\n")
    end
    f:write(string.format("# Start_V,%g\n", params.start_voltage))
    f:write(string.format("# Stop_V,%g\n", params.stop_voltage))
    f:write(string.format("# ScanRate_V_per_s,%g\n", params.scan_rate))
    f:write(string.format("# SampleRate_sps,%g\n", params.sample_rate))
    f:write(string.format("# Cycles,%d\n", params.num_cycles))

    for c, buff in ipairs(cycle_buffers) do
        f:write(string.format("\n# Cycle,%d\n", c))
        f:write("Voltage_V,Current_A,Time_s\n")
        for i = 1, buff.n do
            f:write(string.format("%g,%g,%g\n", buff.sourcevalues[i], buff.readings[i], buff.relativetimestamps[i]))
        end
    end

    f:flush()
    f:close()
    print("Saved CSV: " .. filename)
end

local function run_cv()
    local half_scan_time_s = math.abs(params.stop_voltage - params.start_voltage) / params.scan_rate
    local points_per_half = math.floor(half_scan_time_s * params.sample_rate + 0.5)
    if points_per_half < 2 then points_per_half = 2 end

    local sample_interval_s = 1.0 / params.sample_rate
    local source_range = math.max(math.abs(params.start_voltage), math.abs(params.stop_voltage))
    if source_range < 0.2 then source_range = 0.2 end

    print(string.format("CV run: %g V -> %g V, %g mV/s, %g sps, %d cycles", params.start_voltage, params.stop_voltage, params.scan_rate * 1e3, params.sample_rate, params.num_cycles))

    config_smu(source_range)
    build_source_list(params.start_voltage, params.stop_voltage, points_per_half)

    local list_count = smu.source.configlist.size("CV_SOURCE_LIST")
    config_timer(sample_interval_s, list_count)

    display.clear(display.SCREEN_HOME)
    local home = display.create(display.ROOT, display.OBJ_SCREEN_HOME, "CV")
    local graph = display.create(home, display.OBJ_GRAPH, 30, 10, 600, 300)
    display.changescreen(home)

    local cycle_buffers = {}
    for c = 1, params.num_cycles do
        local buff = buffer.make(250000)
        buff.clear()
        buff.fillmode = buffer.FILL_CONTINUOUS

        build_trigger_model(buff, list_count)

        print(string.format("Starting cycle %d/%d", c, params.num_cycles))
        smu.measure.autozero.once()
        trigger.model.initiate()
        waitcomplete()

        table.insert(cycle_buffers, buff)
        display.graph.add(graph, buff)
        print(string.format("Cycle %d done, points=%d", c, buff.n))
        delay(0.05)
    end

    save_cycles_csv(cycle_buffers)
    print("CV complete")
end

if prompt_parameters() then
    run_cv()
else
    print("CV canceled")
end
