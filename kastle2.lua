-- kastle2: bastl kastle-inspired synthesizer
-- norns port with sequencer, lfo, dj filter
--
-- E1 mode select (1-9)
-- E2 param 1 (per mode)
-- E3 param 2 (per mode)
-- K2 play/stop
-- K3 randomize sequence
-- K1+E2 lfo rate
-- K1+E3 dj filter
-- K1+K2 save favorite
-- K1+K3 load next favorite

engine.name = "PolyPerc"
local musicutil = require "musicutil"
local g = grid.connect()

-- state
local MODE_NAMES = {
  "PHASE DIST", "FM BELL", "FORMANT", "NOISE",
  "WAVEFOLD", "RING MOD", "SUBHARM", "CHAOS", "DRONE"
}
local MODE_P1 = {
  "pitch", "ratio", "formant", "color",
  "fold", "ring freq", "sub div", "rate", "detune"
}
local MODE_P2 = {
  "depth", "decay", "resonance", "density",
  "drive", "mix", "octave", "feedback", "spread"
}

local mode = 1
local param1 = 50
local param2 = 50
local playing = false
local step = 1
local k1_held = false
local beat_flash = 0

-- sequencer
local seq_pitch = {0, 3, 5, 7, 10, 12, 7, 5}
local seq_gate = {1, 1, 1, 1, 1, 1, 1, 1}
local seq_root = 48
local seq_rate = 3
local RATE_NAMES = {"1/4", "1/8", "1/16", "1/32"}
local RATE_DIVS = {1, 0.5, 0.25, 0.125}

-- lfo
local lfo_shape = 1
local lfo_rate = 2.0
local lfo_depth = 50
local lfo_phase = 0
local LFO_SHAPES = {"sine", "tri", "saw", "sqr"}

-- dj filter
local dj_filter = 50

-- favorites
local favorites = {}
local fav_slot = 1

-- midi
local midi_out_device = nil
local midi_out_channel = 1
local opxy_device = nil
local opxy_channel = 2

-- clock ids
local clock_ids = {}

-- grid state
local grid_connected = false

------------------------------------------------------------
-- MODE ENGINE CONFIGS
------------------------------------------------------------

local function apply_mode()
  local cutoffs = {1200, 3000, 800, 6000, 1500, 2000, 600, 4000, 500}
  local releases = {0.3, 1.5, 0.4, 0.1, 0.5, 0.6, 0.8, 0.2, 3.0}
  local pws = {0.5, 0.3, 0.7, 0.5, 0.2, 0.4, 0.6, 0.1, 0.5}

  local c = cutoffs[mode] or 1200
  local r = releases[mode] or 0.5
  local pw = pws[mode] or 0.5

  -- param1 modulates cutoff
  local p1_mod = (param1 / 100)
  c = c * (0.3 + p1_mod * 1.4)

  -- param2 modulates release and pw
  local p2_mod = (param2 / 100)
  r = r * (0.2 + p2_mod * 2.0)
  pw = util.clamp(pw + (p2_mod - 0.5) * 0.4, 0.05, 0.95)

  engine.cutoff(util.clamp(c, 60, 18000))
  engine.release(util.clamp(r, 0.01, 5.0))
  engine.pw(pw)
  engine.amp(0.6)
end

------------------------------------------------------------
-- LFO
------------------------------------------------------------

local function lfo_value()
  local p = lfo_phase
  if lfo_shape == 1 then
    return math.sin(p * 2 * math.pi)
  elseif lfo_shape == 2 then
    if p < 0.5 then return p * 4 - 1
    else return 3 - p * 4 end
  elseif lfo_shape == 3 then
    return p * 2 - 1
  else
    if p < 0.5 then return 1 else return -1 end
  end
end

local function run_lfo()
  while true do
    clock.sleep(1 / 30)
    lfo_phase = lfo_phase + (lfo_rate / 30)
    if lfo_phase >= 1 then lfo_phase = lfo_phase - 1 end
    -- apply lfo to cutoff
    local base_cut = 1200
    local mod = lfo_value() * (lfo_depth / 100) * 2000
    local dj = (dj_filter - 50) / 50
    local dj_mod = 0
    if dj < 0 then
      dj_mod = dj * 4000
    elseif dj > 0 then
      dj_mod = dj * 6000
    end
    engine.cutoff(util.clamp(base_cut + mod + dj_mod, 60, 18000))
  end
end

------------------------------------------------------------
-- SEQUENCER
------------------------------------------------------------

local function note_hz(note_num)
  return musicutil.note_num_to_freq(note_num)
end

local function play_step()
  if seq_gate[step] == 1 then
    local nn = seq_root + seq_pitch[step]
    local hz = note_hz(nn)
    apply_mode()
    engine.hz(hz)
    -- midi out
    if midi_out_device then
      midi_out_device:note_on(nn, 100, midi_out_channel)
      clock.run(function()
        clock.sleep(0.05)
        midi_out_device:note_off(nn, 0, midi_out_channel)
      end)
    end
    -- op-xy out
    if opxy_device then
      opxy_device:note_on(nn, 100, opxy_channel)
      clock.run(function()
        clock.sleep(0.05)
        opxy_device:note_off(nn, 0, opxy_channel)
      end)
    end
  end
  beat_flash = 4
end

local function run_seq()
  while true do
    clock.sync(RATE_DIVS[seq_rate])
    if playing then
      play_step()
      step = step % 8 + 1
    end
  end
end

------------------------------------------------------------
-- SCREEN REDRAW TIMER
------------------------------------------------------------

local function run_redraw()
  while true do
    clock.sleep(1 / 15)
    if beat_flash > 0 then beat_flash = beat_flash - 1 end
    redraw()
    if grid_connected then grid_redraw() end
  end
end

------------------------------------------------------------
-- FAVORITES
------------------------------------------------------------

local function save_favorite(slot)
  favorites[slot] = {
    mode = mode,
    param1 = param1,
    param2 = param2,
    seq_pitch = {},
    seq_gate = {},
    lfo_shape = lfo_shape,
    lfo_rate = lfo_rate,
    lfo_depth = lfo_depth,
    dj_filter = dj_filter,
    seq_rate = seq_rate,
  }
  for i = 1, 8 do
    favorites[slot].seq_pitch[i] = seq_pitch[i]
    favorites[slot].seq_gate[i] = seq_gate[i]
  end
end

local function load_favorite(slot)
  local f = favorites[slot]
  if not f then return end
  mode = f.mode
  param1 = f.param1
  param2 = f.param2
  lfo_shape = f.lfo_shape
  lfo_rate = f.lfo_rate
  lfo_depth = f.lfo_depth
  dj_filter = f.dj_filter
  seq_rate = f.seq_rate
  for i = 1, 8 do
    seq_pitch[i] = f.seq_pitch[i]
    seq_gate[i] = f.seq_gate[i]
  end
  apply_mode()
end

local function randomize_seq()
  local scales = {
    {0,2,3,5,7,8,10},
    {0,2,4,5,7,9,11},
    {0,3,5,6,7,10},
  }
  local sc = scales[math.random(1, 3)]
  for i = 1, 8 do
    local oct = math.random(0, 1) * 12
    seq_pitch[i] = sc[math.random(1, #sc)] + oct
    seq_gate[i] = (math.random() > 0.2) and 1 or 0
  end
end

------------------------------------------------------------
-- GRID
------------------------------------------------------------

local function grid_redraw()
  if not g then return end
  g:all(0)

  -- row 1: mode selector (9 buttons)
  for i = 1, 9 do
    g:led(i, 1, (i == mode) and 15 or 3)
  end

  -- rows 2-3: sequence pitch display
  for i = 1, 8 do
    local hi = (seq_pitch[i] >= 12) and 1 or 0
    local brightness = (i == step and playing) and 15 or 6
    if hi == 1 then
      g:led(i, 2, brightness)
      g:led(i, 3, 2)
    else
      g:led(i, 2, 2)
      g:led(i, 3, brightness)
    end
  end

  -- row 4: gate toggles
  for i = 1, 8 do
    g:led(i, 4, seq_gate[i] == 1 and 10 or 2)
  end

  -- row 5: lfo shape (1-4) + rate (9-16)
  for i = 1, 4 do
    g:led(i, 5, (i == lfo_shape) and 12 or 3)
  end
  local rate_led = util.clamp(math.floor(lfo_rate / 10 * 8) + 9, 9, 16)
  for i = 9, 16 do
    g:led(i, 5, (i <= rate_led) and 8 or 2)
  end

  -- row 6: favorites (8 slots)
  for i = 1, 8 do
    local br = 2
    if favorites[i] then br = 6 end
    if i == fav_slot then br = 15 end
    g:led(i, 6, br)
  end

  -- row 7: dj filter position (16 steps)
  local dj_pos = math.floor(dj_filter / 100 * 15) + 1
  for i = 1, 16 do
    if i == dj_pos then
      g:led(i, 7, 15)
    elseif i == 8 or i == 9 then
      g:led(i, 7, 4)
    else
      g:led(i, 7, 1)
    end
  end

  -- row 8: transport + rate
  g:led(1, 8, playing and 15 or 4)
  for i = 3, 6 do
    g:led(i, 8, (i - 2 == seq_rate) and 12 or 3)
  end

  g:refresh()
end

function g.key(x, y, z)
  if z == 0 then return end

  if y == 1 and x >= 1 and x <= 9 then
    mode = x
    apply_mode()
  elseif y == 4 and x >= 1 and x <= 8 then
    seq_gate[x] = 1 - seq_gate[x]
  elseif y == 5 and x >= 1 and x <= 4 then
    lfo_shape = x
  elseif y == 5 and x >= 9 and x <= 16 then
    lfo_rate = (x - 8) / 8 * 10
  elseif y == 6 and x >= 1 and x <= 8 then
    fav_slot = x
    load_favorite(x)
  elseif y == 7 and x >= 1 and x <= 16 then
    dj_filter = (x - 1) / 15 * 100
  elseif y == 8 and x == 1 then
    playing = not playing
    if playing then step = 1 end
  elseif y == 8 and x >= 3 and x <= 6 then
    seq_rate = x - 2
  end
end

------------------------------------------------------------
-- INIT
------------------------------------------------------------

function init()
  -- midi setup
  params:add_separator("kastle2", "KASTLE2")

  params:add_number("midi_device", "midi device", 1, 16, 1)
  params:set_action("midi_device", function(v)
    midi_out_device = midi.connect(v)
  end)
  params:add_number("midi_channel", "midi channel", 1, 16, 1)
  params:set_action("midi_channel", function(v) midi_out_channel = v end)

  params:add_number("opxy_device", "op-xy device", 1, 16, 2)
  params:set_action("opxy_device", function(v)
    opxy_device = midi.connect(v)
  end)
  params:add_number("opxy_channel", "op-xy channel", 1, 16, 2)
  params:set_action("opxy_channel", function(v) opxy_channel = v end)

  params:add_number("root_note", "root note", 24, 72, 48)
  params:set_action("root_note", function(v) seq_root = v end)

  params:add_number("lfo_depth_param", "lfo depth", 0, 100, 50)
  params:set_action("lfo_depth_param", function(v) lfo_depth = v end)

  -- connect devices
  midi_out_device = midi.connect(params:get("midi_device"))
  opxy_device = midi.connect(params:get("opxy_device"))

  -- init engine
  apply_mode()

  -- grid
  grid_connected = (g and g.device ~= nil)

  -- init favorites
  for i = 1, 8 do favorites[i] = nil end

  -- start clocks
  table.insert(clock_ids, clock.run(run_seq))
  table.insert(clock_ids, clock.run(run_lfo))
  table.insert(clock_ids, clock.run(run_redraw))
end

------------------------------------------------------------
-- INPUT
------------------------------------------------------------

function enc(n, d)
  if n == 1 then
    if k1_held then return end
    mode = util.clamp(mode + d, 1, 9)
    apply_mode()
  elseif n == 2 then
    if k1_held then
      lfo_rate = util.clamp(lfo_rate + d * 0.2, 0.1, 20)
    else
      param1 = util.clamp(param1 + d, 0, 100)
      apply_mode()
    end
  elseif n == 3 then
    if k1_held then
      dj_filter = util.clamp(dj_filter + d, 0, 100)
    else
      param2 = util.clamp(param2 + d, 0, 100)
      apply_mode()
    end
  end
end

function key(n, z)
  if n == 1 then
    k1_held = (z == 1)
    return
  end

  if z == 0 then return end

  if k1_held then
    if n == 2 then
      save_favorite(fav_slot)
    elseif n == 3 then
      fav_slot = fav_slot % 8 + 1
      load_favorite(fav_slot)
    end
  else
    if n == 2 then
      playing = not playing
      if playing then step = 1 end
    elseif n == 3 then
      randomize_seq()
    end
  end
end

------------------------------------------------------------
-- SCREEN
------------------------------------------------------------

function redraw()
  screen.clear()
  screen.aa(0)
  screen.font_face(1)

  -- top: mode name
  screen.level(15)
  screen.font_size(12)
  screen.move(64, 10)
  screen.text_center(MODE_NAMES[mode])

  -- param values
  screen.font_size(8)
  screen.level(8)
  screen.move(2, 20)
  screen.text(MODE_P1[mode] .. ":" .. param1)
  screen.move(126, 20)
  screen.text_right(MODE_P2[mode] .. ":" .. param2)

  -- sequence visualization (y=28 to y=42)
  local seq_y = 34
  for i = 1, 8 do
    local x = 8 + (i - 1) * 15
    -- step background
    if i == step and playing then
      screen.level(beat_flash > 0 and 15 or 10)
    else
      screen.level(seq_gate[i] == 1 and 6 or 2)
    end
    -- pitch bar
    local bar_h = math.floor(seq_pitch[i] / 24 * 14) + 2
    screen.rect(x, seq_y - bar_h, 11, bar_h)
    screen.fill()
    -- gate dot
    if seq_gate[i] == 0 then
      screen.level(2)
      screen.rect(x + 4, seq_y + 1, 3, 2)
      screen.fill()
    end
  end

  -- divider line
  screen.level(2)
  screen.move(0, 38)
  screen.line(128, 38)
  screen.stroke()

  -- bottom section: lfo mini waveform
  screen.level(6)
  local lfo_x = 2
  local lfo_y_base = 52
  for i = 0, 24 do
    local p = i / 24
    local val = 0
    if lfo_shape == 1 then
      val = math.sin(p * 2 * math.pi)
    elseif lfo_shape == 2 then
      if p < 0.5 then val = p * 4 - 1
      else val = 3 - p * 4 end
    elseif lfo_shape == 3 then
      val = p * 2 - 1
    else
      if p < 0.5 then val = 1 else val = -1 end
    end
    screen.pixel(lfo_x + i, lfo_y_base - math.floor(val * 5))
  end
  screen.fill()

  -- lfo label
  screen.level(4)
  screen.font_size(8)
  screen.move(2, 62)
  screen.text(LFO_SHAPES[lfo_shape])

  -- dj filter bar (center = neutral)
  local filt_x = 38
  local filt_w = 50
  local filt_center = filt_x + filt_w / 2
  local filt_pos = filt_x + math.floor(dj_filter / 100 * filt_w)
  screen.level(3)
  screen.rect(filt_x, 56, filt_w, 3)
  screen.fill()
  screen.level(15)
  screen.rect(filt_pos - 1, 54, 3, 7)
  screen.fill()
  -- center mark
  screen.level(6)
  screen.pixel(filt_center, 60)
  screen.fill()

  -- filter label
  screen.level(4)
  screen.move(52, 52)
  if dj_filter < 45 then
    screen.text_center("LP")
  elseif dj_filter > 55 then
    screen.text_center("HP")
  else
    screen.text_center("--")
  end

  -- bpm + rate
  screen.level(8)
  screen.move(126, 48)
  screen.text_right(RATE_NAMES[seq_rate])
  screen.move(126, 56)
  screen.text_right(math.floor(params:get("clock_tempo")) .. "bpm")

  -- play state + fav
  screen.move(126, 62)
  screen.level(playing and 15 or 4)
  screen.text_right(playing and ">" or "||")

  -- favorite slot indicator
  screen.level(favorites[fav_slot] and 10 or 3)
  screen.move(100, 62)
  screen.text_right("F" .. fav_slot)

  -- beat pulse
  if beat_flash > 2 then
    screen.level(15)
    screen.rect(0, 0, 2, 2)
    screen.fill()
  end

  screen.update()
end

------------------------------------------------------------
-- CLEANUP
------------------------------------------------------------

function cleanup()
  playing = false
  for i = 1, #clock_ids do
    clock.cancel(clock_ids[i])
  end
  -- midi all notes off
  if midi_out_device then
    for ch = 1, 16 do
      midi_out_device:cc(123, 0, ch)
    end
  end
  if opxy_device then
    for ch = 1, 16 do
      opxy_device:cc(123, 0, ch)
    end
  end
  -- grid clear
  if g then
    g:all(0)
    g:refresh()
  end
end
