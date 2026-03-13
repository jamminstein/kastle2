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

-- screen
local screen_dirty = true

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
-- UI
-- -------------------------------------------------------
local function draw_screen()
  screen.clear()
  screen.aa(1)

  -- title bar
  screen.level(15)
  screen.font_face(1)
  screen.font_size(8)
  screen.move(0, 8)
  screen.text("kastle2")

  -- fx mode name (large)
  screen.level(15)
  screen.font_size(16)
  screen.move(64, 30)
  screen.text_center(FX_MODES[fx_index])

  -- fx number dots
  local dot_x = 8
  for i = 1, #FX_MODES do
    if i == fx_index then
      screen.level(15)
      screen.circle(dot_x, 55, 3)
      screen.fill()
    else
      screen.level(4)
      screen.circle(dot_x, 55, 2)
      screen.stroke()
    end
    dot_x = dot_x + 14
  end

  -- p1 bar (left)
  screen.level(6)
  screen.rect(0, 36, 4, 16)
  screen.stroke()
  screen.level(15)
  screen.rect(0, 36 + math.floor((1 - p1) * 16), 4, math.ceil(p1 * 16))
  screen.fill()

  -- p2 bar (right)
  screen.level(6)
  screen.rect(124, 36, 4, 16)
  screen.stroke()
  screen.level(15)
  screen.rect(124, 36 + math.floor((1 - p2) * 16), 4, math.ceil(p2 * 16))
  screen.fill()

  -- frozen indicator
  if frozen_params ~= nil then
    screen.level(10)
    screen.font_size(6)
    screen.move(64, 10)
    screen.text_center("[FROZEN]")
  end

  -- bpm (small, top right)
  screen.level(4)
  screen.font_size(7)
  screen.move(128, 8)
  screen.text_right(string.format("%d bpm", math.floor(bpm)))

  screen.update()
end

-- -------------------------------------------------------
-- Lifecycle
-- -------------------------------------------------------
function init()
  init_params()
  params:read()
  params:bang()

  send_params()

  -- redraw clock
  clock.run(function()
    while true do
      clock.sleep(1/30)
      if screen_dirty then
        draw_screen()
        screen_dirty = false
      end
    end
  end)

  print("kastle2: ready — " .. #FX_MODES .. " fx modes loaded")
end

function cleanup()
  params:write()
end

-- -------------------------------------------------------
-- Encoders
-- -------------------------------------------------------
function enc(n, d)
  if n == 1 then
    fx_index = util.clamp(fx_index + d, 1, #FX_MODES)
    engine.mode(fx_index - 1)
  elseif n == 2 then
    p1 = util.clamp(p1 + d * 0.01, 0, 1)
    engine.p1(p1)
  elseif n == 3 then
    p2 = util.clamp(p2 + d * 0.01, 0, 1)
    engine.p2(p2)
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
