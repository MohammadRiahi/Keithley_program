--[[Last Updated: $Date: 2020/03/06 $ $Change: 189427 $ 
	
	Copyright � Keithley Instruments, LLC.  All rights reserved.

	Part of the Keithley Instruments Potentiostat System.
	Users are permitted to modify but not distribute the software without prior written permission from Keithley.
	
	THIS SOFTWARE IS PROVIDED �AS-IS,� WITHOUT ANY EXPRESS OR IMPLIED WARRANTIES OF ANY KIND, INCLUDING 
	BUT NOT LIMITED TO THE IMPLIED WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, AND 
	NON-INFRINGEMENT OF INTELLECTUAL PROPERTY. IN NO EVENT SHALL KEITHLEY INSTRUMENTS, ITS AFFILIATES, 
	OFFICERS, EMPLOYEES, DIRECTORS, AGENTS, SUPPLIERS, OR OTHER THIRD PARTIES BE LIABLE FOR ANY DIRECT, 
	INDIRECT, INCIDENTAL, PUNITIVE, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES ARISING IN ANY WAY OUT 
	OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
	
	This test script enables select Keithley SourceMeter � Instrument to perform square wave voltammetry.  
	When the test script is executed, the user is prompted to enter the test parameters on the display of 
	the instrument.   As the test is executed, a voltammogram is plotted in real time on the home screen.

	Using this test script requires the Model 2450, 2460, or 2461 to have firmware 1.5.0 or greater.  
	The latest firmware can be found on the Keithley website, tek.com/keithley.

]]

--The variables to be used throughout the entirety of this code are as follows:
changelist = "$Change: 189427 $"
local MIN_EC_FRAMEWORK_VERSION = "1.5"
local terminalOption = smu.TERMINALS_FRONT
SAVED_SETUP_BASE_FILENAME = "KI_"..localnode.model.."-EC_SWV_Setup"
SCRIPT_TITLE = "Square Wave Voltammetry"
X_UNIT = "V"
Y_UNIT = "A"

local SAMPLE_WINDOW_DEFAULT = 1e-3

local pulsePeriod
local pulseWidth
local settleDelay
local cycleCount
local sweepDirection
local voltageLimit

local swvData = {
	E = {},
	Ifwd = {},
	Irev = {},
	Inet = {},
	t = {}
}

--=========================================================================================
-- (Private) Script Utility Functions  (Intended for use by this script only.  DO NOT CALL)
--=========================================================================================

function experimentInitialize(fpMode, rpTerminals)
	smu.source.offmode = smu.OFFMODE_HIGHZ
	eventlog.clear()
	eventlog.suppress(eventlog.SEV_ALL)
	
	-- If the rpTerminals parameter is true then the rear panel terminals will be used.
	if rpTerminals then
		terminalOption = smu.TERMINALS_REAR
	else
		terminalOption = smu.TERMINALS_FRONT
	end
	smu.terminals = terminalOption
	
	if eocBuffer == nil then
		eocBuffer = buffer.make(10000)
	end
	
	eocBuffer.clear()
	eocBuffer.fillmode = buffer.FILL_CONTINUOUS
	
	collectgarbage()

end


--[[function measureEOC()
	-checks with the user that the chemical set up is ready for the measurement
	-sets all of the SMU parameters necessary for making the Eoc measurement
	-makes the measurement
	-prompts the user to approve of it
--]]
function measureEOC()
	-- Not used by SWV, retained to preserve compatibility with EC framework references.
end


--[[function experimentSetup()
	This function does the following:
	-collects the "numberOfVertices" from the user
	-collects the magnitude of the vertices using the references from the user, stored in "vertexPotential"
	-collects the "sourceRate" from the user
	-collects the "numberOfCycles" from the user
	-collects the "currentLimit" from the user based on the model number
	-calculates the "cycleRange" for use in collecting more user inputs
	-collects the "data.samplingUnits" from the user
	-collects the corresponding magnitude for the data.samplingUnits
	-uses the magnitude, the cycle range, and other values to calculate the value for measureVoltage/CurrentDifference

	]]
function experimentSetup()
	if data.startPotential == nil then return false, "Start potential not supplied" end
	if data.endPotential == nil then return false, "End potential not supplied" end
	if data.pulseAmplitude == nil then return false, "Pulse amplitude not supplied" end
	if data.stepPotential == nil then return false, "Step potential not supplied" end
	if data.frequency == nil then return false, "Frequency not supplied" end
	if data.equilibrationTime == nil then return false, "Equilibration time not supplied" end
	if data.currentLimit == nil then return false, "Current limit not supplied" end
	if data.highCapacitance == nil then return false, "High Capacitance Mode not supplied" end

	if data.stepPotential <= 0 then return false, "Step potential must be greater than zero" end
	if data.frequency <= 0 then return false, "Frequency must be greater than zero" end
	if data.pulseAmplitude <= 0 then return false, "Pulse amplitude must be greater than zero" end

	local span = data.endPotential - data.startPotential
	sweepDirection = 1
	if span < 0 then sweepDirection = -1 end

	cycleCount = math.floor((math.abs(span) / data.stepPotential) + 0.5)
	if cycleCount < 1 then return false, "Number of cycles must be at least 1" end

	pulsePeriod = 1 / data.frequency
	pulseWidth = pulsePeriod / 2

	local sampleWindow = SAMPLE_WINDOW_DEFAULT
	if pulseWidth <= sampleWindow then
		sampleWindow = pulseWidth * 0.5
	end
	data.sampleWindow = sampleWindow

	settleDelay = pulseWidth - data.sampleWindow
	if settleDelay < 0 then settleDelay = 0 end

	voltageLimit = math.max(math.abs(data.startPotential), math.abs(data.endPotential)) + math.abs(data.pulseAmplitude)

	if not verify_power_limits(voltageLimit, instr.FUNC_DC_VOLTAGE, I_RANGES.range[data.currentLimit]) then
		display.input.prompt(display.BUTTONS_OK, "Voltage exceeds power limits. Reduce Es/Ef/Esw or increase current range.")
		test_cleanup()
		exit()
	end

	return true, "experimentSetup completed successfully"
end -- function experimentSetup()


--[[function experimentExecution()
	This function executes the test based on the test parameters store in the local script variables.
--]]
function experimentExecution(fpMode)
	local function sample_end_of_pulse(delayBeforeSample)
		if delayBeforeSample > 0 then
			delay(delayBeforeSample)
		end
		return smu.measure.read()
	end

	local function capture_for_graph(bufferRef, level)
		smu.source.level = level
		smu.measure.read(bufferRef)
	end

	-- Set up source and measure commands
	smu.source.func = smu.FUNC_DC_VOLTAGE
	smu.measure.func = smu.FUNC_DC_CURRENT
	smu.source.offmode = smu.OFFMODE_HIGHZ
	smu.measure.sense = smu.SENSE_2WIRE
	smu.source.range = voltageLimit
	smu.source.autorange = smu.OFF
	smu.source.readback = smu.OFF
	smu.source.ilimit.level = I_RANGES.range[data.currentLimit]
	smu.source.autodelay = smu.OFF
	smu.source.delay = 0
	
	if data.highCapacitance == get_index_from_value_enum(OFF_ON_HC, "On") then
		smu.source.highc = smu.ON
	else
		smu.source.highc = smu.OFF
	end
	
	smu.terminals = terminalOption
	smu.measure.range = I_RANGES.range[data.currentLimit]
	local nplc = data.sampleWindow * localnode.linefreq
	if nplc < 0.01 then
		smu.measure.nplc = 0.01
	elseif nplc < 10 then
		smu.measure.nplc = nplc
	else
		smu.measure.nplc = 10
	end
	smu.measure.autozero.once()

	-- cvBuffer is used for live graph updates on Run/Graph screen.
	if cvBuffer == nil then
		cvBuffer = buffer.make(100000)
	end
	cvBuffer.clear()
	cvBuffer.capacity = 100000
	cvBuffer.fillmode = buffer.FILL_CONTINUOUS
	display.graph.removeall(ui.home.graph)
	display.graph.add(ui.home.graph, cvBuffer)
	display.graph.drawstyle(ui.home.graph, display.STYLE_BOTH)
	display.graph.scalex(ui.home.graph, display.XSCALE_SMART)
	display.graph.scaley(ui.home.graph, display.YSCALE_SMART)
	
	eventlog.clear()
	collectgarbage()

	for i = 1, table.getn(swvData.E) do
		swvData.E[i] = nil
		swvData.Ifwd[i] = nil
		swvData.Irev[i] = nil
		swvData.Inet[i] = nil
		swvData.t[i] = nil
	end

	display.setstate(ui.home.start_stop, display.STATE_ENABLE)
	display.waitevent(0.001)	--Consume any previous events

	smu.source.output = smu.ON
	smu.source.level = data.startPotential
	if data.equilibrationTime > 0 then
		delay(data.equilibrationTime)
	end

	local startTime = timer.gettime()
	for n = 1, cycleCount do
		local event = display.waitevent(0.001)
		if event == ui.home.start_stop then
			test_cleanup()
			return false, "Stopped by user"
		end

		local E = data.startPotential + ((n - 1) * data.stepPotential * sweepDirection)
		local lowLevel = E - data.pulseAmplitude
		local highLevel = E + data.pulseAmplitude

		smu.source.level = lowLevel
		local Ir = sample_end_of_pulse(settleDelay)
		if math.abs(Ir) > I_RANGES.range[data.currentLimit] then
			test_cleanup()
			display.input.prompt(display.BUTTONS_OK, "Current exceeded selected range during reverse pulse.")
			return false, "Current limit exceeded"
		end

		smu.source.level = highLevel
		local Ifwd = sample_end_of_pulse(settleDelay)
		if math.abs(Ifwd) > I_RANGES.range[data.currentLimit] then
			test_cleanup()
			display.input.prompt(display.BUTTONS_OK, "Current exceeded selected range during forward pulse.")
			return false, "Current limit exceeded"
		end

		local Inet = Ifwd - Ir

		swvData.E[n] = E
		swvData.Ifwd[n] = Ifwd
		swvData.Irev[n] = Ir
		swvData.Inet[n] = Inet
		swvData.t[n] = timer.gettime() - startTime

		-- Log forward pulse current for live graph updates; net current is preserved in swvData.
		capture_for_graph(cvBuffer, highLevel)

		update_progress_bar(n / cycleCount * 100)
	end

	test_cleanup()
	return true,"CV test complete successfully"
end --function experimentExecution()


--[[function experimentSave()
	This function saves the test parameters and the collected data to the USB thumb drive.
--]]
function experimentSave()
	--these three tables contain the three things that will be written to the cells in the for loop below
	local textCells, valueCells, unitsCells
	local stringData = { }
	textCells = 	{"General Parameters", "\nSource Parameters", "Es", "Ef", "Esw", "dE", "f", "tp", "t_eq", "\nMeasure Parameters", "Current Range", "Sense", "\nCalculated Parameters", "Cycles", "Pulse period", "Pulse width", "Settle delay", "Sample window", "Source range"}
	valueCells = 	{"n/a", "n/a", data.startPotential, data.endPotential, data.pulseAmplitude, data.stepPotential, data.frequency, pulseWidth, data.equilibrationTime, "n/a", I_RANGES.range[data.currentLimit], "n/a", "n/a", cycleCount, pulsePeriod, pulseWidth, settleDelay, data.sampleWindow, smu.source.range}
	unitsCells = 	{"n/a", "n/a", "V", "V", "V", "V", "Hz", "s", "s", "n/a", "A", "2-wire", "n/a", "", "s", "s", "s", "s", "V"}
	for i = 1, 19 do
		if valueCells[i] ~= nil then
			if valueCells[i] ~= "n/a" and unitsCells[i] ~= "n/a" then
				table.insert(stringData, string.format("%s, %g, %s", textCells[i], valueCells[i], unitsCells[i]))
			else
				if valueCells[i] ~= "n/a" then
					table.insert(stringData, string.format("%s, %g", textCells[i], valueCells[i]))
				else
					if unitsCells[i] ~= "n/a" then
						table.insert(stringData, string.format("%s, %s", textCells[i], unitsCells[i]))
					else
						table.insert(stringData, string.format("%s", textCells[i]))
					end
				end
			end
		end
	end
	table.insert(stringData, "")

	table.insert(stringData, "\nRaw Data")
	table.insert(stringData, "E_staircase_V,If_A,Ir_A,I_net_A\n")
	for i = 1, table.getn(swvData.E) do
		table.insert(stringData, string.format("%g,%g,%g,%g", swvData.E[i], swvData.Ifwd[i], swvData.Irev[i], swvData.Inet[i]))
	end
	
	save_data_to_usb_with_prompt(stringData)
end --function experimentSave()

--===============================================
-- (Public) KICV Front Panel Operation Functions
--===============================================
-- Call these functions to perform the CV test from the front panel.

--[[function KICV_RunFrontPanel()
	Starts the front panel operation of the script.  In front panel operation, the script will prompt the user to enter
	test parameters on the front panel of the instrument.
--]]
function KICV_RunFrontPanel()

	-- Initialize the instrument and script to test
	experimentInitialize(true)

	--[[Before accepting any sorts of commands or inputs regarding the experiment, the code must measure the Eoc for the 
		user to potentially reference throughout the experiment.
	
		The Eoc is the open circuit potential of the system, or the natural voltage response to 0A of current being drawn.
		This value is the voltaic center of the reactions occurring in the system.
	
		The function "measureEOC" is defined above, and only returns the value of the Eoc.]]
------------------------------------------------------------------------------------------------------------------------
	
	--[[Collect user inputs necessary to calculate experiment settings.
		the experiment.
	
		The function experimentSetup() collects the user input, uses this input to calculate the remaining parameters
		for executing the experiment, then copies these results to the matrix "parameters".
	]]
------------------------------------------------------------------------------------------------------------------------	
	local success, message = experimentSetup(true)
	if message == nil then message = "" end
	if not success then
		display.input.prompt(display.BUTTONS_OK, "Error: "..message)
		test_cleanup()
		return
	end

	----------------------------------------------------------------------------------------------------------------------

	experimentExecution(true)

end

function scan_event_handler(eventID, value)
	sync_ui_to_data(ui_data_event_table, eventID)
end

function measure_event_handler(eventID, value)
	sync_ui_to_data(ui_data_event_table, eventID)
end

function start_stop_event_handler(eventID)
	test_start()
	KICV_RunFrontPanel()
	test_cleanup()
end

local function create_screens()
	ui.scan = { }
	ui.scan.root = display.create(display.ROOT, display.OBJ_SCREEN, "Scan Settings")
	ui.measure = { }
	ui.measure.root = display.create(display.ROOT, display.OBJ_SCREEN, "Measure Settings")
	
end

local function create_controls()
	--Setup ui.home controls
	display.settext(ui.home.version, "version "..get_version_number(changelist))
	display.settext(ui.home.root, SCRIPT_TITLE)
	display.setevent(ui.home.start_stop, display.EVENT_PRESS, "start_stop_event_handler(%id)")
	hide_home_stats()	--We're not using stats here, so hide them
	display.setevent(ui.home.save, display.EVENT_PRESS, "experimentSave()")

	--Create ui.menu controls
	local offset = 0 -- button offset
	if display.EVENT_ENDAPP then offset = 1 end
	--ui.menu.root = display.create(display.ROOT, display.OBJ_SCREEN_MENU, "Settings", "Views", "Save/Load", "System")
	display.create(ui.menu.root, display.OBJ_BUTTON_MENU, 0 + offset, 0 + offset, ui.measure.root, "Measure Settings", "meas_settings")
	display.create(ui.menu.root, display.OBJ_BUTTON_MENU, 0 + offset, 1 + offset, ui.scan.root, "Scan Settings", "CV_scan_settings")
	
	--Statistics are disabled for CV until reliable stats are defined
	--display.create(ui.menu.root, display.OBJ_BUTTON_MENU, 1 + offset, 0 + offset, ui.stats.root, "Statistics")
	display.create(ui.menu.root, display.OBJ_BUTTON_MENU, 1 + offset, 0 + offset, ui.home.root, "Run/Graph", "graph")
	display.create(ui.menu.root, display.OBJ_BUTTON_MENU, 1 + offset, 1 + offset, display.SCREEN_READING_TABLE, "Reading Table")
	
	display.create(ui.menu.root, display.OBJ_BUTTON_MENU, 2 + offset, 0 + offset, ui.save.root, "Save Settings", "save")
	display.create(ui.menu.root, display.OBJ_BUTTON_MENU, 2 + offset, 1 + offset, ui.load.root, "Load Settings", "load")
	
	display.create(ui.menu.root, display.OBJ_BUTTON_MENU, 3 + offset, 0 + offset, display.SCREEN_SYS_EVENT_LOG, "Event Log")
	
	--Create ui.scan controls
	ui.scan.start_potential = display.create(ui.scan.root, display.OBJ_EDIT_NUMBER, 200, 20, "Start Potential (Es)", "-20\21V to 20\21V", display.NFORMAT_DECIMAL, -0.10, -20, 20, "V")
	display.setevent(ui.scan.start_potential, display.EVENT_PRESS, "scan_event_handler(%id, %value)")
	table.insert(ui_data_event_table, {ui = "ui.scan.start_potential", data = "data.startPotential", event = "scan_event_handler"})

	ui.scan.end_potential = display.create(ui.scan.root, display.OBJ_EDIT_NUMBER, 200, option_height + 20, "End Potential (Ef)", "-20\21V to 20\21V", display.NFORMAT_DECIMAL, 0.45, -20, 20, "V")
	display.setevent(ui.scan.end_potential, display.EVENT_PRESS, "scan_event_handler(%id, %value)")
	table.insert(ui_data_event_table, {ui = "ui.scan.end_potential", data = "data.endPotential", event = "scan_event_handler"})

	ui.scan.pulse_amplitude = display.create(ui.scan.root, display.OBJ_EDIT_NUMBER, 200, option_height*2 + 20, "Pulse Amplitude (Esw)", "0.1\21mV to 5\21V", display.NFORMAT_DECIMAL, 0.025, 0.0001, 5, "V")
	display.setevent(ui.scan.pulse_amplitude, display.EVENT_PRESS, "scan_event_handler(%id, %value)")
	table.insert(ui_data_event_table, {ui = "ui.scan.pulse_amplitude", data = "data.pulseAmplitude", event = "scan_event_handler"})

	ui.scan.step_potential = display.create(ui.scan.root, display.OBJ_EDIT_NUMBER, 200, option_height*3 + 20, "Step Potential (dE)", "0.1\21mV to 5\21V", display.NFORMAT_DECIMAL, 0.005, 0.0001, 5, "V")
	display.setevent(ui.scan.step_potential, display.EVENT_PRESS, "scan_event_handler(%id, %value)")
	table.insert(ui_data_event_table, {ui = "ui.scan.step_potential", data = "data.stepPotential", event = "scan_event_handler"})

	ui.scan.frequency = display.create(ui.scan.root, display.OBJ_EDIT_NUMBER, 600, 20, "Frequency (f)", "0.1\21Hz to 1000\21Hz", display.NFORMAT_DECIMAL, 15, 0.1, 1000, "Hz")
	display.setevent(ui.scan.frequency, display.EVENT_PRESS, "scan_event_handler(%id, %value)")
	table.insert(ui_data_event_table, {ui = "ui.scan.frequency", data = "data.frequency", event = "scan_event_handler"})
	
	--Create ui.measure controls
	ui.measure.equilibration = display.create(ui.measure.root, display.OBJ_EDIT_NUMBER, 200, option_height*0 + 20, "Equilibration Time", "0 to 3600\21s", display.NFORMAT_DECIMAL, 5, 0, 3600, "s")
	display.setevent(ui.measure.equilibration, display.EVENT_PRESS, "measure_event_handler(%id, %value)")
	table.insert(ui_data_event_table, {ui = "ui.measure.equilibration", data = "data.equilibrationTime", event = "measure_event_handler"})
	
	ui.measure.current_range = create_edit_option(ui.measure.root, 600, option_height*0 + 20, "Current Range", I_RANGES.value[1].."..."..I_RANGES.value[table.getn(I_RANGES.value)], I_RANGES)
	table.insert(ui_data_event_table, {ui = "ui.measure.current_range", data = "data.currentLimit", event = "measure_event_handler"})
	display.setvalue(ui.measure.current_range, get_index_from_range(I_RANGES, 100e-6))
	measure_event_handler(ui.measure.current_range, 100e-6)
	display.setevent(ui.measure.current_range, display.EVENT_PRESS, "measure_event_handler(%id, %value)")
	
	ui.measure.high_capacitance = create_edit_option(ui.measure.root, 600, option_height*1 + 20, "High Capacitance", "Off or On", OFF_ON_HC)
	table.insert(ui_data_event_table, {ui = "ui.measure.high_capacitance", data = "data.highCapacitance", event = "measure_event_handler"})
	display.setvalue(ui.measure.high_capacitance, get_index_from_value_enum(OFF_ON_HC, "Off"))	--Set default range to Off
	measure_event_handler(ui.measure.high_capacitance, get_index_from_value_enum(OFF_ON_HC, "Off"))
	display.setevent(ui.measure.high_capacitance, display.EVENT_PRESS, "measure_event_handler(%id, %value)")
	
	sync_ui_to_data(ui_data_event_table)
end

local function create_global_tables()
	--NOTE: Use find and replace when changing *.value strings to avoid breaking lookups

	REFERENCE_TYPES = {
		value = {"Eref", "Eoc"}
	}
	
	SAMPLE_UNITS = {
		value = {"points/cycle", "points/test", "points/s", "s/point"},
		abbreviation = {"pts/cycle", "pts/test", "pts/s", "s/pt"}
	}
	
	OFF_ON_HC = {
		value = {"Off", "On"}
	}
	
	if localnode.model == "2450" then
		I_RANGES = {
			value = {"10\21\20A", "100\21\20A", "1\21mA", "10\21mA", "100\21mA", "1\21A"},
			range = {10e-6, 100e-6, 1e-3, 10e-3, 100e-3, 1},
			v_limit = {210, 210, 210, 210, 210, 21}
		}
		V_RANGES = {
			value = {"20\21mV", "200\21mV", "2\21V", "20\21V"},
			range = {20e-3, 200e-3, 2, 20},
			i_limit = {1.05, 1.05, 1.05, 1.05}
		}
	elseif localnode.model == "2460" or localnode.model == "2461" then
		I_RANGES = {
			value = {"1\21mA", "10\21mA", "100\21mA", "1\21A", "4\21A", "5\21A", "7\21A"},
			range = {1e-3, 10e-3, 100e-3, 1, 4, 5, 7},
			v_limit = {105, 105, 105, 105, 21, 10.5, 7.35}
		}
		V_RANGES = {
			value = {"200\21mV", "2\21V", "7\21V", "10\21V", "20\21V"},
			range = {200e-3, 2, 7, 10, 20},
			i_limit = {7.35, 7.35, 7.35, 5.25, 4.2}
		}
	end
end

--==============================
-- Script Execution Begins Here!
--==============================
-- When you run the script, all the functions and local variables above will be loaded into memory but, script execution
-- really begins here.

local function main()
	if not EC_FRAMEWORK_VERSION then
		if EC_Framework then
			EC_Framework.run()
		elseif file.usbdriveexists() == 1 then
			EC_Framework = script.load("/usb1/EC_Framework.tsp")
			if EC_Framework then
				EC_Framework.run()
			end
		end
		
		if not EC_Framework then
			print("Unable to load EC_Framework.tsp!")
			display.input.prompt(display.BUTTONS_OK, "Unable to load EC_Framework.tsp!")
			exit()
		end
	end
	
	if EC_FRAMEWORK_VERSION < MIN_EC_FRAMEWORK_VERSION then
		print("EC_Framework version "..MIN_EC_FRAMEWORK_VERSION.." or greater required, please update.")
		display.input.prompt(display.BUTTONS_OK, "EC_Framework version "..MIN_EC_FRAMEWORK_VERSION.." or greater required, please update.")
		exit()
	end
	
	reset()
	smu.source.offmode = smu.OFFMODE_HIGHZ
	smu.measure.sense = smu.SENSE_4WIRE
	
	init_toplevel()
	data.vertexPotential = { }
	create_global_tables()
	
	create_top_screens()
	create_screens()
	create_loading_screen()
	
	create_top_controls()
	create_controls()
	
	destroy_loading_screen()
	
	
end
main()