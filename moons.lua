-- moons
-- v1.0.0
-- a monome norns clone of 5moons
-- encoder 1: select track
-- encoder 2: vol
-- key 2: toggle rec
-- key 3: toggle (un)mute
-- key 1 + key 3: clear all buffers

engine.name = nil

local sc = softcut
local VOICES = 5
local tracks = {}
local current_track = 1
local rec_mode = 1 -- 1: IMMEDIATE, 2: LISTEN
local rec_modes = { "IMMEDIATE", "LISTEN" }
local input_threshold = 0.02
local k1_held = false

function init()
	audio.level_adc_cut(1)
	audio.level_cut(1)
	sc.reset()

	-- parameters
	params:add_option("rec_mode", "Rec Mode", rec_modes, 1)
	params:set_action("rec_mode", function(val)
		rec_mode = val
		params:write()
		redraw()
	end)

	params:add_number("input_threshold", "Input Threshold", 0, 100, 2)
	params:set_action("input_threshold", function(val)
		input_threshold = val / 100
		params:write()
	end)

	-- set defaults and load saved parameters
	params:read()

	local buf_len = 60

	for i = 1, VOICES do
		tracks[i] = {
			recording = false,
			waiting_for_input = false,
			rec_start = 0,
			loop_len = 0,
			level = 1.0,
			muted = false,
			buf_start = (i - 1) * buf_len,
		}

		sc.enable(i, 1)
		sc.buffer(i, 1)
		sc.level(i, tracks[i].level)
		sc.pan(i, 0.0)
		sc.rate(i, 1.0)
		sc.rec(i, 0)
		sc.rec_level(i, 1.0)
		sc.pre_level(i, 0.0)
		sc.loop(i, 0)
		sc.position(i, tracks[i].buf_start)
		sc.fade_time(i, 0.1)
		sc.play(i, 0) -- initially not playing

		sc.level_input_cut(1, i, 1.0)
		sc.level_input_cut(2, i, 1.0)
	end

	-- setup input level polling for LISTEN mode
	local input_poll = poll.set("amp_in_l")
	input_poll.time = 0.05
	input_poll.callback = function(val)
		for i = 1, VOICES do
			if tracks[i].waiting_for_input and val > input_threshold then
				start_actual_recording(i)
			end
		end
	end
	input_poll:start()
end

function cleanup() end

function start_actual_recording(v)
	local t = tracks[v]
	t.waiting_for_input = false
	t.recording = true
	t.rec_start = util.time()
	sc.rec(v, 1)
	sc.play(v, 1)
	redraw()
end

function enc(n, d)
	local t = tracks[current_track]
	local v = current_track
	if n == 1 then
		current_track = util.clamp(current_track + d, 1, VOICES)
	elseif n == 2 then
		t.level = util.clamp(t.level + d / 50, 0, 1.5)
		if not t.muted then
			sc.level(v, t.level)
		end
	end
	redraw()
end

function clear_all_buffers()
	for i = 1, VOICES do
		local t = tracks[i]
		-- stop recording and playback
		sc.play(i, 0)
		sc.rec(i, 0)
		sc.loop(i, 0)
		-- reset track state
		t.recording = false
		t.waiting_for_input = false
		t.rec_start = 0
		t.loop_len = 0
		t.muted = false
		sc.level(i, t.level)
		-- reset position
		sc.position(i, t.buf_start)
		sc.loop_start(i, t.buf_start)
		sc.loop_end(i, t.buf_start + 60)
	end
	redraw()
end

function key(n, z)
	-- track k1 state
	if n == 1 then
		k1_held = (z == 1)
		return
	end

	if z == 0 then
		return
	end

	-- k1 + k3: clear all buffers
	if n == 3 and k1_held then
		clear_all_buffers()
		return
	end

	local t = tracks[current_track]
	local v = current_track

	if n == 2 then
		if not t.recording and not t.waiting_for_input then
			-- prepare for recording
			sc.play(v, 0)
			sc.rec(v, 0)
			sc.loop(v, 0)
			sc.position(v, t.buf_start)
			sc.loop_start(v, t.buf_start)
			sc.loop_end(v, t.buf_start + 60)
			-- mute current track during recording
			sc.level(v, 0)

			if rec_mode == 1 then
				-- IMMEDIATE mode: start recording now
				start_actual_recording(v)
			else
				-- LISTEN mode: wait for input
				t.waiting_for_input = true
			end
		else
			-- stop recording, start loop playback
			t.waiting_for_input = false
			t.recording = false
			t.loop_len = util.time() - t.rec_start
			t.loop_len = math.min(math.max(t.loop_len, 0.1), 60)
			sc.rec(v, 0)
			sc.loop_start(v, t.buf_start)
			sc.loop_end(v, t.buf_start + t.loop_len)
			sc.position(v, t.buf_start)
			sc.loop(v, 1)
			-- restore volume (unless manually muted)
			if not t.muted then
				-- manual muted will jump back to loop begin
				sc.position(v, t.buf_start)
				sc.level(v, t.level)
			end
			sc.play(v, 1)
		end
	end

	if n == 3 then
		t.muted = not t.muted
		if t.muted then
			sc.level(v, 0)
		else
			sc.level(v, t.level)
		end
	end

	redraw()
end

function redraw()
	screen.clear()

	for i = 1, VOICES do
		-- scroll effect: calculate y position relative to current track
		local offset = i - current_track
		local y = 32 + offset * 10
		local t = tracks[i]

		-- only draw tracks that are visible on screen
		if y >= 10 and y <= 60 then
			if i == current_track then
				screen.level(15)
			else
				screen.level(5)
			end

			screen.move(5, y)
			if i == current_track then
				screen.text(">")
			end

			screen.move(15, y)
			if t.recording then
				screen.text("track " .. i .. " : RECORDING...")
			elseif t.waiting_for_input then
				screen.text("track " .. i .. " : WAITING...")
			elseif t.loop_len > 0 then
				if t.muted then
					screen.text(string.format("track %d : MUTE (%.2f)", i, t.level))
				else
					screen.text(string.format("track %d : %.2f", i, t.level))
				end
			else
				if t.muted then
					screen.text("track " .. i .. " : MUTE")
				else
					screen.text("track " .. i .. " : empty")
				end
			end
		end
	end
	screen.update()
end
