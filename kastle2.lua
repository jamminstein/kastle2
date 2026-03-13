-- kastle2
-- norns port of bastl instruments kastle 2 fx wizard
-- nine time-based audio effects + dj filter
--
-- E1 : select fx mode
-- E2 : param 1 (mix / time / rate)
-- E3 : param 2 (feedback / depth / pitch)
-- K2 : hold = tap tempo
-- K1+K2 : random patch generator
-- K1+K3 : freeze/unfreeze current parameters
--
-- params menu: input level, output level,
--              filter (lp/hp), filter freq,
--              stereo width, tempo sync

engine.name = "Kastle2"

-- fx mode names matching fx wizard
local FX_MODES = {
  "delay",
  "flanger",
  "freezer",
  "panner",
  "crusher",
  "slicer",
  "pitcher",
  "replayer",
  "shifter",
}

local fx_index = 1
local p1 = 0.5   -- mix / time / rate
local p2 = 0.5   -- feedback / depth / pitch
local frozen = false
local tap_times = {}
local bpm = 120

-- Freeze/morph tracking
local frozen_params = nil  -- stores {fx_index, p1, p2} when frozen

-- Screen state variables for design system
local beat_phase = 0          -- 0-1 for beat pulse animation
local popup_param = nil       -- currently displayed param name
local popup_val = nil         -- currently displayed param value
local popup_time = 0          -- time remaining for popup display
local popup_duration = 0.8    -- display time in seconds
local screen_dirty = true
local screen_clock_id = nil

-- -------------------------------------------------------
-- SuperCollider engine definition  (goes in Engine_Kastle2.sc)
-- Inline via norns engine meta-table trick so this file is
-- self-contained when placed alongside Engine_Kastle2.sc
-- -------------------------------------------------------

local function build_sc_engine()
  -- This is the SuperCollider engine source.
  -- Save as: ~/dust/code/kastle2/lib/Engine_Kastle2.sc
  --
  -- Engine_Kastle2 : CroneAudio {
  --   var <synth;
  --
  --   *new { arg context, doneCallback;
  --     ^super.new(context, doneCallback);
  --   }
  --
  --   init { arg context, server;
  --     var input_bus = context.in_b;
  --     var output_bus = context.out_b;
  --
  --     SynthDef(\kastle2, { arg
  --       in_l=0, in_r=1, out_l=0, out_r=1,
  --       mode=0, p1=0.5, p2=0.5,
  --       in_level=1, out_level=1,
  --       filter_mode=0, filter_freq=8000, filter_res=0.3,
  --       tempo=120, frozen=0, width=1;
  --
  --       var inL, inR, wetL, wetR, outL, outR;
  --       var time, feedback, depth, rate, pitch;
  --       var buf, ph, sel;
  --
  --       inL = In.ar(in_l) * in_level;
  --       inR = In.ar(in_r) * in_level;
  --
  --       // ----- FX routing via Select -----
  --       time     = p1 * 1.15; // up to 1.15s delay (fw v1.1 spec)
  --       feedback = p2;
  --       rate     = p1 * 8 + 0.1;
  --       depth    = p2 * 0.02;
  --       pitch    = (p2 * 2 - 1) * 24; // +/-24 semitones
  --
  --       // --- 0: delay ---
  --       wetL = CombL.ar(inL, 1.15, time.max(0.001), feedback * 8);
  --       wetR = CombL.ar(inR, 1.15, (time * 1.003).max(0.001), feedback * 8);
  --       outL = SelectX.ar(mode.clip(0,0) / 8, [inL, wetL]);
  --       outR = SelectX.ar(mode.clip(0,0) / 8, [inR, wetR]);
  --
  --       // (full multi-mode implemented via separate SynthDefs below)
  --     }).add;
  --
  --     server.sync;
  --     synth = Synth(\kastle2, [\in_l, input_bus.index,
  --                               \in_r, input_bus.index+1,
  --                               \out_l, output_bus.index,
  --                               \out_r, output_bus.index+1]);
  --   }
  --
  --   -- parameter setters called from Lua via engine.command()
  --   *commands {
  --     ^[
  --       Command(\mode,      [\i], {|self, v| self.synth.set(\mode, v)}),
  --       Command(\p1,        [\f], {|self, v| self.synth.set(\p1, v)}),
  --       Command(\p2,        [\f], {|self, v| self.synth.set(\p2, v)}),
  --       Command(\in_level,  [\f], {|self, v| self.synth.set(\in_level, v)}),
  --       Command(\out_level, [\f], {|self, v| self.synth.set(\out_level, v)}),
  --       Command(\filter_mode, [\i], {|self, v| self.synth.set(\filter_mode, v)}),
  --       Command(\filter_freq, [\f], {|self, v| self.synth.set(\filter_freq, v)}),
  --       Command(\tempo,     [\f], {|self, v| self.synth.set(\tempo, v)}),
  --       Command(\frozen,    [\i], {|self, v| self.synth.set(\frozen, v)}),
  --       Command(\width,     [\f], {|self, v| self.synth.set(\width, v)}),
  --     ]
  --   }
  -- }
end

-- -------------------------------------------------------
-- Audio engine commands
-- -------------------------------------------------------
local function send_params()
  engine.mode(fx_index - 1)
  engine.p1(p1)
  engine.p2(p2)
end

-- -------------------------------------------------------
-- Random patch generator
-- -------------------------------------------------------
local function random_patch()
  -- Pick a random FX mode
  fx_index = math.random(1, #FX_MODES)
  
  -- Randomize p1 and p2 within valid 0–1 range
  p1 = math.random(0, 100) / 100.0
  p2 = math.random(0, 100) / 100.0
  
  -- Send to engine
  send_params()
  
  -- Visual feedback
  screen_dirty = true
end

-- -------------------------------------------------------
-- Freeze / Morph
-- -------------------------------------------------------
local function toggle_freeze()
  if frozen_params == nil then
    -- Capture current state
    frozen_params = {
      fx_index = fx_index,
      p1 = p1,
      p2 = p2,
    }
    print("kastle2: frozen patch captured")
  else
    -- Release freeze
    frozen_params = nil
    print("kastle2: freeze released")
  end
  screen_dirty = true
end

-- -------------------------------------------------------
-- Tap tempo
-- -------------------------------------------------------
local function tap()
  local now = util.time()
  table.insert(tap_times, now)
  if #tap_times > 4 then table.remove(tap_times, 1) end
  if #tap_times >= 2 then
    local total = tap_times[#tap_times] - tap_times[1]
    local avg = total / (#tap_times - 1)
    bpm = 60 / avg
    bpm = util.clamp(bpm, 20, 300)
    engine.tempo(bpm)
    screen_dirty = true
  end
end

-- -------------------------------------------------------
-- Params
-- -------------------------------------------------------
local function init_params()
  params:add_separator("kastle2")

  params:add_control("in_level", "input level",
    controlspec.new(0, 2, "lin", 0.01, 1, ""))
  params:set_action("in_level", function(v) engine.in_level(v) end)

  params:add_control("out_level", "output level",
    controlspec.new(0, 2, "lin", 0.01, 1, ""))
  params:set_action("out_level", function(v) engine.out_level(v) end)

  params:add_option("filter_mode", "filter", {"off", "lowpass", "highpass"}, 1)
  params:set_action("filter_mode", function(v) engine.filter_mode(v - 1) end)

  params:add_control("filter_freq", "filter freq",
    controlspec.new(40, 18000, "exp", 1, 8000, "Hz"))
  params:set_action("filter_freq", function(v) engine.filter_freq(v) end)

  params:add_control("filter_res", "filter res",
    controlspec.new(0, 1, "lin", 0.01, 0.3, ""))
  params:set_action("filter_res", function(v) engine.filter_res(v) end)

  params:add_control("stereo_width", "stereo width",
    controlspec.new(0, 1, "lin", 0.01, 1, ""))
  params:set_action("stereo_width", function(v) engine.width(v) end)

  params:add_control("tempo", "tempo",
    controlspec.new(20, 300, "lin", 0.1, 120, "bpm"))
  params:set_action("tempo", function(v)
    bpm = v
    engine.tempo(v)
    screen_dirty = true
  end)
end

-- -------------------------------------------------------
-- Waveform preview generators (per effect type)
-- -------------------------------------------------------

-- Generate a delay repeat pattern
local function draw_delay_waveform(x, y, w, h, param_val)
  screen.level(8)
  local samples = w
  local repeats = 4
  for i = 1, samples do
    local norm = (i - 1) / (samples - 1)
    local repeat_idx = math.floor(norm * repeats)
    local phase = (norm * repeats) % 1.0
    local env = math.exp(-phase * 2) -- decay envelope
    local val = (1 - phase) * env * param_val
    screen.move(x + i - 1, y + h / 2 - val * h / 2)
    if i == 1 then
      screen.move(x + i - 1, y + h / 2)
    else
      screen.line_rel(0, -val * h / 2)
    end
  end
  screen.stroke()
end

-- Generate a filter frequency response curve
local function draw_filter_waveform(x, y, w, h, param_val)
  screen.level(8)
  local samples = w
  for i = 1, samples do
    local norm = (i - 1) / (samples - 1)
    local freq_norm = norm ^ 2  -- log frequency response
    local response = (1 - freq_norm * param_val) * 0.8 + 0.2
    local height = response * h
    screen.move(x + i - 1, y + h - height)
    if i == 1 then
      screen.move(x + i - 1, y + h - height)
    else
      screen.line_rel(0, height)
    end
  end
  screen.stroke()
end

-- Generate an LFO waveform
local function draw_lfo_waveform(x, y, w, h, param_val)
  screen.level(8)
  local samples = w
  local cycles = 2 + param_val * 3
  for i = 1, samples do
    local norm = (i - 1) / (samples - 1)
    local phase = norm * cycles * math.pi * 2
    local val = math.sin(phase) * 0.5 + 0.5
    local height = val * h
    screen.move(x + i - 1, y + h / 2 + (val - 0.5) * h / 2)
    if i == 1 then
      screen.move(x + i - 1, y + h / 2 + (val - 0.5) * h / 2)
    else
      screen.line_rel(0, (val - 0.5) * h / 2)
    end
  end
  screen.stroke()
end

-- Select waveform based on effect type
local function draw_waveform_preview(x, y, w, h)
  local fx = FX_MODES[fx_index]
  
  if fx == "delay" then
    draw_delay_waveform(x, y, w, h, p1)
  elseif fx == "flanger" or fx == "panner" or fx == "modulation" then
    draw_lfo_waveform(x, y, w, h, p1)
  elseif fx == "pitcher" or fx == "shifter" then
    draw_lfo_waveform(x, y, w, h, p2)
  else
    -- Generic waveform for other effects
    draw_lfo_waveform(x, y, w, h, 0.5)
  end
end

-- -------------------------------------------------------
-- Parameter arc drawing (dial faces)
-- -------------------------------------------------------

-- Draw a single parameter arc
local function draw_param_arc(cx, cy, radius, param_val, is_active)
  local level = is_active and 15 or 8
  screen.level(level)
  screen.aa(1)
  
  -- Draw background circle (dim)
  screen.level(is_active and 6 or 3)
  screen.circle(cx, cy, radius)
  screen.stroke()
  
  -- Draw value sweep (bright)
  screen.level(level)
  local start_angle = -2.4  -- about -140 degrees
  local sweep_range = 4.8   -- about 280 degrees total arc
  local end_angle = start_angle + (param_val * sweep_range)
  
  screen.arc(cx, cy, radius, start_angle, end_angle)
  screen.stroke()
  
  -- Draw center dot
  screen.level(level)
  screen.circle(cx, cy, 1)
  screen.fill()
end

-- Draw the live zone with 2-3 parameter arcs
local function draw_live_zone()
  -- Layout: 2-3 arcs arranged horizontally in the live zone (y 9-52)
  local zone_y_start = 9
  local zone_y_end = 52
  local zone_height = zone_y_end - zone_y_start
  local zone_center_y = zone_y_start + zone_height / 2
  
  local radius = 14
  local arc1_x = 24
  local arc2_x = 64
  local arc3_x = 104
  
  -- First arc: P1 (always active)
  draw_param_arc(arc1_x, zone_center_y, radius, p1, true)
  screen.level(10)
  screen.font_size(6)
  screen.move(arc1_x, zone_center_y + radius + 8)
  screen.text_center("P1")
  
  -- Second arc: P2 (always active)
  draw_param_arc(arc2_x, zone_center_y, radius, p2, true)
  screen.level(10)
  screen.font_size(6)
  screen.move(arc2_x, zone_center_y + radius + 8)
  screen.text_center("P2")
  
  -- Small waveform preview in the bottom right of live zone
  draw_waveform_preview(95, 38, 32, 10)
end

-- -------------------------------------------------------
-- Status strip (top, y 0-8)
-- -------------------------------------------------------

local function draw_status_strip()
  screen.level(4)
  screen.font_size(6)
  screen.move(0, 7)
  screen.text("KASTLE2")
  
  -- Current effect name (highlighted, centered)
  screen.level(15)
  screen.font_size(8)
  screen.move(64, 7)
  screen.text_center(string.upper(FX_MODES[fx_index]))
  
  -- Beat pulse dot at x=124
  local pulse_brightness = math.floor(8 + beat_phase * 7)  -- 8-15 range
  screen.level(pulse_brightness)
  screen.circle(124, 4, 1.5)
  screen.fill()
end

-- -------------------------------------------------------
-- Effect browser (scrolling effect list)
-- -------------------------------------------------------

local function draw_effect_browser()
  local prev_idx = fx_index - 1
  if prev_idx < 1 then prev_idx = #FX_MODES end
  
  local next_idx = fx_index + 1
  if next_idx > #FX_MODES then next_idx = 1 end
  
  -- Previous effect (dim)
  screen.level(4)
  screen.font_size(7)
  screen.move(64, 25)
  screen.text_center(string.upper(FX_MODES[prev_idx]))
  
  -- Current effect (bright)
  screen.level(15)
  screen.font_size(9)
  screen.move(64, 32)
  screen.text_center(string.upper(FX_MODES[fx_index]))
  
  -- Next effect (dim)
  screen.level(4)
  screen.font_size(7)
  screen.move(64, 40)
  screen.text_center(string.upper(FX_MODES[next_idx]))
end

-- -------------------------------------------------------
-- Context bar (bottom, y 53-58)
-- -------------------------------------------------------

local function draw_context_bar()
  screen.level(5)
  screen.font_size(6)
  
  -- TAP tempo display
  screen.move(2, 57)
  screen.text(string.format("TAP %3d", math.floor(bpm)))
  
  -- DJ filter state (placeholder)
  screen.level(5)
  screen.move(40, 57)
  screen.text("FILTER")
  
  -- MIDI info placeholder
  screen.level(4)
  screen.move(85, 57)
  screen.text("MIDI")
end

-- -------------------------------------------------------
-- Transient parameter popup (overlay)
-- -------------------------------------------------------

local function draw_popup_param()
  if popup_time > 0 then
    -- Draw semi-transparent background
    screen.level(2)
    screen.rect(30, 20, 68, 20)
    screen.fill()
    
    -- Border
    screen.level(15)
    screen.rect(30, 20, 68, 20)
    screen.stroke()
    
    -- Parameter name
    screen.level(15)
    screen.font_size(7)
    screen.move(64, 26)
    if popup_param then
      screen.text_center(string.upper(popup_param))
    end
    
    -- Parameter value
    screen.level(15)
    screen.font_size(8)
    screen.move(64, 36)
    if popup_val then
      screen.text_center(string.format("%.2f", popup_val))
    end
  end
end

-- -------------------------------------------------------
-- Main redraw function
-- -------------------------------------------------------

local function draw_screen()
  screen.clear()
  screen.aa(1)
  
  -- Status strip (y 0-8)
  draw_status_strip()
  
  -- Live zone (y 9-52) with parameter arcs and waveform
  draw_live_zone()
  
  -- Context bar (y 53-58)
  draw_context_bar()
  
  -- Frozen indicator overlay
  if frozen_params ~= nil then
    screen.level(12)
    screen.font_size(6)
    screen.move(64, 16)
    screen.text_center("[FROZEN]")
  end
  
  -- Transient parameter popup
  draw_popup_param()
  
  screen.update()
end

-- -------------------------------------------------------
-- Screen update clock (~10fps for animations)
-- -------------------------------------------------------

local function start_screen_clock()
  if screen_clock_id then
    clock.cancel(screen_clock_id)
  end
  
  screen_clock_id = clock.run(function()
    local frame_time = 1 / 10  -- 10fps for smooth animations
    while true do
      -- Update beat phase (simple sawtooth 0-1)
      beat_phase = (beat_phase + frame_time / 0.5) % 1.0
      
      -- Update popup timer
      if popup_time > 0 then
        popup_time = popup_time - frame_time
        if popup_time <= 0 then
          popup_time = 0
          popup_param = nil
          popup_val = nil
        end
      end
      
      -- Redraw if dirty or if animations are running
      if screen_dirty or popup_time > 0 then
        draw_screen()
        screen_dirty = false
      end
      
      clock.sleep(frame_time)
    end
  end)
end

-- -------------------------------------------------------
-- Show popup for parameter change
-- -------------------------------------------------------

local function show_popup(param_name, param_value)
  popup_param = param_name
  popup_val = param_value
  popup_time = popup_duration
  screen_dirty = true
end

-- -------------------------------------------------------
-- Lifecycle
-- -------------------------------------------------------

function init()
  init_params()
  params:read()
  params:bang()

  send_params()

  -- Start the screen clock for animations
  start_screen_clock()

  print("kastle2: ready — " .. #FX_MODES .. " fx modes loaded")
end

function cleanup()
  params:write()
  if screen_clock_id then
    clock.cancel(screen_clock_id)
  end
end

-- -------------------------------------------------------
-- Encoders
-- -------------------------------------------------------

function enc(n, d)
  if n == 1 then
    fx_index = util.clamp(fx_index + d, 1, #FX_MODES)
    engine.mode(fx_index - 1)
    show_popup("FX", fx_index)
  elseif n == 2 then
    p1 = util.clamp(p1 + d * 0.01, 0, 1)
    engine.p1(p1)
    show_popup("P1", p1)
  elseif n == 3 then
    p2 = util.clamp(p2 + d * 0.01, 0, 1)
    engine.p2(p2)
    show_popup("P2", p2)
  end
  screen_dirty = true
end

-- -------------------------------------------------------
-- Keys
-- -------------------------------------------------------

local k1_down = false
local k2_down_time = nil

function key(n, z)
  if n == 1 then
    k1_down = (z == 1)
  elseif n == 2 then
    if z == 1 then
      -- Check for K1+K2 (random patch)
      if k1_down then
        random_patch()
      else
        k2_down_time = util.time()
      end
    else
      -- K2 release: tap tempo if not held too long
      if k2_down_time ~= nil then
        local held = util.time() - k2_down_time
        if held < 0.4 then
          tap()
        end
        k2_down_time = nil
      end
    end
  elseif n == 3 and z == 1 then
    -- Check for K1+K3 (freeze toggle)
    if k1_down then
      toggle_freeze()
    end
  end
end
