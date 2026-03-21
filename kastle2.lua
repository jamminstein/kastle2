-- kastle2 for norns
--
-- a norns port of the bastl instruments kastle 2 fx wizard
-- 9 real-time effects + visual feedback
--
-- k1: shift (hold)
-- k2: prev mode
-- k3: next mode
-- e1: select effect parameter
-- e2/e3: adjust effect values
-- enc(1) rotated 2x: toggle favorite mode save/load
--
-- grid: 16 touch-sensitive pads for effect selection & MIDI CC learn
--
engine.name = "PolyPerc"

local MusicUtil = require "musicutil"

-- State structure
local state = {
  mode = 1,
  effect_params = {},
  fav_modes = {},
  param_index = 1,
  fav_learn_mode = false,
  fav_learn_cc = nil,
  midi_device = nil,
}

-- Effect list: 9 audio effects
local effects = {
  { name = "DELAY", params = {"time", "feedback", "mix"} },
  { name = "FLANGER", params = {"rate", "depth", "feedback"} },
  { name = "FREEZER", params = {"buffer_size", "freeze_rate", "mix"} },
  { name = "PANNER", params = {"rate", "depth", "mix"} },
  { name = "CRUSHER", params = {"bits", "rate", "mix"} },
  { name = "SLICER", params = {"rate", "depth", "mix"} },
  { name = "PITCHER", params = {"shift", "formant", "mix"} },
  { name = "REPLAYER", params = {"playback_rate", "reverse", "mix"} },
  { name = "SHIFTER", params = {"pitch_shift", "feedback", "mix"} }
}

-- Favorite slots
local favorite_names = {"FAV1", "FAV2", "FAV3", "FAV4"}
local selected_fav = 1

-- Grid connection
local g = grid.connect()

-- Screen state
local popup_time = 0
local popup_msg = ""
local beat_phase = 0

-- ─── INITIALIZATION ───────────────────────────────────────────
function init()
  -- Initialize effect parameters for all 9 modes
  for i = 1, 9 do
    state.effect_params[i] = {0.5, 0.5, 0.5}
  end

  -- Initialize 4 favorite slots with default values
  for i = 1, 4 do
    state.fav_modes[i] = {mode = i, params = {0.5, 0.5, 0.5}}
  end

  -- MIDI setup
  state.midi_device = midi.connect(1)
  state.midi_device.event = function(data)
    midi_handler(data)
  end

  -- Screen refresh clock
  clock.run(function()
    while true do
      clock.sleep(1/15)
      beat_phase = (beat_phase + 1) % 240
      popup_time = math.max(0, popup_time - 1)
      redraw()
    end
  end)

  -- Parameters for external control mapping
  params:add_separator("kastle2_effects", "KASTLE2 EFFECTS")

  for i = 1, 9 do
    local effect_name = effects[i].name
    params:add_group(effect_name, 3)
    for j, param_name in ipairs(effects[i].params) do
      params:add_control("e"..i.."_p"..j, param_name,
        controlspec.new(0, 1, 'lin', 0.01, 0.5))
      params:set_action("e"..i.."_p"..j, function(v)
        state.effect_params[i][j] = v
        mark_redraw()
      end)
    end
  end

  -- Favorite mode parameters
  params:add_separator("favorites", "FAVORITE MODES")
  for i = 1, 4 do
    params:add_trigger("load_fav_"..i, "Load FAV" .. i)
    params:set_action("load_fav_"..i, function() load_favorite(i) end)

    params:add_trigger("save_fav_"..i, "Save FAV" .. i)
    params:set_action("save_fav_"..i, function() save_favorite(i) end)
  end

  -- Set initial dirty flag
  dirty = true
  redraw()
end

-- ─── REDRAW MANAGEMENT ────────────────────────────────────────
local dirty = true
function mark_redraw()
  dirty = true
end

-- ─── EFFECT MODE DISPLAY ──────────────────────────────────────
function redraw()
  if not dirty then return end
  dirty = false

  screen.clear()
  screen.level(15)
  screen.move(64, 10)
  screen.text_center("KASTLE2")

  -- Mode name display (current selected effect)
  screen.level(12)
  screen.move(64, 22)
  screen.text_center(effects[state.mode].name)

  -- DJ Filter visualization
  draw_dj_filter()

  -- Parameter display
  draw_parameters()

  -- Favorite mode indicators
  draw_favorites()

  -- MIDI CC learn indicator
  if state.fav_learn_mode then
    screen.level(15)
    screen.move(64, 50)
    screen.text_center("WAITING FOR CC...")
  end

  -- Popup notification
  if popup_time > 0 then
    screen.level(12)
    screen.move(64, 56)
    screen.text_center(popup_msg)
  end

  screen.update()
end

function draw_dj_filter()
  -- Visualize frequency sweep using delay mix as reference
  local mix = state.effect_params[state.mode][3]
  local freq_y = 30 + (mix * 10)

  screen.level(8)
  screen.rect(10, 30, 108, 15)
  screen.stroke()

  screen.level(12)
  screen.move(10, freq_y)
  screen.line(118, freq_y)
  screen.stroke()

  -- Frequency markers
  screen.level(4)
  for x = 10, 118, 27 do
    screen.move(x, 25)
    screen.line(x, 46)
    screen.stroke()
  end
end

function draw_parameters()
  local effect = effects[state.mode]
  local params = state.effect_params[state.mode]

  screen.level(8)
  screen.move(2, 58)

  for i, param_name in ipairs(effect.params) do
    local val = params[i]
    local label = string.format("%s: %.2f", param_name, val)
    if i == state.param_index then
      screen.level(15)
    else
      screen.level(4)
    end
    screen.move(2 + (i-1) * 40, 58)
    screen.text(label)
  end
end

function draw_favorites()
  -- Show favorite mode indicators
  screen.level(4)
  for i = 1, 4 do
    local x = 20 + (i-1) * 27
    local bright = (i == selected_fav) and 12 or 4
    screen.level(bright)
    screen.move(x, 44)
    screen.text_center(favorite_names[i])
  end
end

-- ─── ENCODER CONTROL ──────────────────────────────────────────
function enc(n, d)
  if n == 1 then
    -- E1: rotate to navigate modes
    state.mode = ((state.mode - 1 + d) % 9) + 1
    state.param_index = 1
    mark_redraw()
  elseif n == 2 then
    -- E2: navigate parameters
    state.param_index = ((state.param_index - 1 + d) % 3) + 1
    mark_redraw()
  elseif n == 3 then
    -- E3: adjust parameter value
    local effect = effects[state.mode]
    local idx = state.param_index
    state.effect_params[state.mode][idx] = util.clamp(state.effect_params[state.mode][idx] + d * 0.01, 0, 1)
    mark_redraw()
  end
end

-- ─── KEY CONTROL ──────────────────────────────────────────────
function key(n, z)
  if n == 1 and z == 1 then
    -- K1: favorite mode manager
    show_popup("SELECT FAVORITE")
  elseif n == 2 and z == 1 then
    -- K2: previous mode
    state.mode = ((state.mode - 2) % 9) + 1
    mark_redraw()
  elseif n == 3 and z == 1 then
    -- K3: next mode
    state.mode = (state.mode % 9) + 1
    mark_redraw()
  end
end

-- ─── GRID INTERFACE ───────────────────────────────────────────
function grid_key(x, y, z)
  if z == 1 then
    -- Grid press: select effect mode (row 1-3 = modes 1-9)
    if y <= 3 then
      local mode_idx = (y - 1) * 3 + x
      if mode_idx >= 1 and mode_idx <= 9 then
        state.mode = mode_idx
        mark_redraw()
      end
    elseif y == 4 then
      -- Row 4: favorite mode controls
      selected_fav = x
      mark_redraw()
    elseif y == 5 then
      -- Row 5: MIDI CC learn mode toggle
      if x == 1 then
        state.fav_learn_mode = not state.fav_learn_mode
        if state.fav_learn_mode then
          show_popup("LEARN MODE ON")
        else
          show_popup("LEARN MODE OFF")
        end
      end
    end
  end
end

if g and g.device then
  g.key = grid_key
end

-- ─── MIDI CC LEARN ────────────────────────────────────────────
function midi_handler(data)
  local msg = midi.to_msg(data)

  if state.fav_learn_mode and msg.type == "cc" then
    -- Learn MIDI CC for favorite mode control
    state.fav_learn_cc = msg.cc
    show_popup("CC " .. msg.cc .. " MAPPED")
    state.fav_learn_mode = false
  end
end

-- ─── FAVORITE MODES ───────────────────────────────────────────
function save_favorite(slot)
  state.fav_modes[slot] = {
    mode = state.mode,
    params = {state.effect_params[state.mode][1], state.effect_params[state.mode][2], state.effect_params[state.mode][3]}
  }
  show_popup("SAVED TO " .. favorite_names[slot])
end

function load_favorite(slot)
  local fav = state.fav_modes[slot]
  if fav then
    state.mode = fav.mode
    state.effect_params[state.mode] = {fav.params[1], fav.params[2], fav.params[3]}
    show_popup("LOADED " .. favorite_names[slot])
    mark_redraw()
  end
end

-- ─── POPUP NOTIFICATION ───────────────────────────────────────
function show_popup(msg)
  popup_msg = msg
  popup_time = 60  -- ~4s at 15 FPS
  mark_redraw()
end

function cleanup()
  clock.cancel_all()
  if state.midi_device then
    state.midi_device.event = nil
  end
end
