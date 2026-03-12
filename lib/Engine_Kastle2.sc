// Engine_Kastle2.sc
// Save to: ~/dust/code/kastle2/lib/Engine_Kastle2.sc
//
// Nine fx modes matching Kastle 2 FX Wizard:
//   0  delay     1  flanger    2  freezer
//   3  panner    4  crusher    5  slicer
//   6  pitcher   7  replayer   8  shifter
//
// DJ-style LP/HP filter on output bus.

Engine_Kastle2 : CroneEngine {

  var <synth;
  var <fxBuf;

  *new { arg context, doneCallback;
    ^super.new(context, doneCallback);
  }

  alloc {
    var inBus  = context.in_b;
    var outBus = context.out_b;
    var bufSize = context.server.sampleRate * 2.0; // 2 s stereo buffer

    fxBuf = Buffer.alloc(context.server, bufSize.ceil.asInteger, 2);

    SynthDef(\kastle2_engine, { arg
        inL       = 0,    inR      = 1,
        outL      = 0,    outR     = 1,
        mode      = 0,
        p1        = 0.5,  p2       = 0.5,
        in_level  = 1.0,  out_level = 1.0,
        filter_mode = 0,  filter_freq = 8000, filter_res = 0.3,
        tempo     = 120,  frozen    = 0,
        width     = 1.0,
        buf       = 0;

      var srcL, srcR;
      var wetL, wetR;
      var outSigL, outSigR;
      var beatSec, time, feedback, depth, rate, pitchSemi;

      // ---- input ----
      srcL = In.ar(inL) * in_level;
      srcR = In.ar(inR) * in_level;

      beatSec  = 60.0 / tempo;
      time     = p1 * 1.15;               // 0–1.15 s
      feedback = p2 * 0.9;                // 0–0.9
      depth    = p2 * 0.012 + 0.001;      // flanger depth
      rate     = p1 * 8.0 + 0.05;        // lfo rate Hz
      pitchSemi = (p2 * 2 - 1) * 24;     // ±24 semitones

      // ==== Per-mode outputs using Select ========================

      wetL = Select.ar(mode, [
        // 0 delay
        CombL.ar(srcL + CombL.ar(srcL, 1.15, time.max(0.001), feedback * 6) * feedback,
                  1.15, time.max(0.001), -1),
        // 1 flanger
        srcL + DelayL.ar(srcL, 0.02,
          SinOsc.ar(rate, 0, depth, depth + 0.0005)) * 0.7,
        // 2 freezer (granular freeze via BufRd)
        Select.ar(frozen, [
          srcL,
          BufRd.ar(1, buf, Phasor.ar(0, BufRateScale.kr(buf), 0, BufFrames.kr(buf)), 0, 2)
        ]),
        // 3 panner
        srcL * SinOsc.ar(rate, 0, 0.5, 0.5) * width,
        // 4 bit crusher
        Latch.ar(srcL, Impulse.ar((p1 * 44000).max(100))) /
          (2 ** ((1 - p2) * 14 + 2).round) *
          (2 ** ((1 - p2) * 14 + 2).round),
        // 5 slicer
        srcL * (Impulse.ar(rate) > 0.5),
        // 6 pitcher (pitch shift up/down)
        PitchShift.ar(srcL, 0.1, pitchSemi.midiratio, 0, 0.001),
        // 7 replayer (looping delay with tempo-sync'd time)
        CombL.ar(srcL, 2, (beatSec * p1.linlin(0,1,0.25,2)).max(0.001), feedback * 12),
        // 8 shifter (frequency shift)
        FreqShift.ar(srcL, p1 * 400 - 200)
      ]);

      wetR = Select.ar(mode, [
        CombL.ar(srcR + CombL.ar(srcR, 1.15, (time*1.003).max(0.001), feedback*6)*feedback,
                  1.15, (time*1.003).max(0.001), -1),
        srcR + DelayL.ar(srcR, 0.02,
          SinOsc.ar(rate, pi, depth, depth + 0.0005)) * 0.7,
        Select.ar(frozen, [
          srcR,
          BufRd.ar(1, buf, Phasor.ar(0, BufRateScale.kr(buf), 0, BufFrames.kr(buf)), 0, 2)
        ]),
        srcR * SinOsc.ar(rate, pi, 0.5, 0.5) * width,
        Latch.ar(srcR, Impulse.ar((p1 * 44000).max(100))) /
          (2 ** ((1 - p2) * 14 + 2).round) *
          (2 ** ((1 - p2) * 14 + 2).round),
        srcR * (Impulse.ar(rate, 0.5) > 0.5),
        PitchShift.ar(srcR, 0.1, pitchSemi.midiratio, 0, 0.001),
        CombL.ar(srcR, 2, ((beatSec * p1.linlin(0,1,0.25,2)) * 1.003).max(0.001), feedback*12),
        FreqShift.ar(srcR, p1 * 400 - 200)
      ]);

      // ---- mix dry/wet (p1 controls mix on delay/flanger) -----
      outSigL = XFade2.ar(srcL, wetL, p1 * 2 - 1);
      outSigR = XFade2.ar(srcR, wetR, p1 * 2 - 1);

      // ---- DJ filter (off / LP / HP) --------------------------
      outSigL = Select.ar(filter_mode, [
        outSigL,
        LPF.ar(outSigL, filter_freq.clip(40, 20000)),
        HPF.ar(outSigL, filter_freq.clip(40, 20000))
      ]);
      outSigR = Select.ar(filter_mode, [
        outSigR,
        LPF.ar(outSigR, filter_freq.clip(40, 20000)),
        HPF.ar(outSigR, filter_freq.clip(40, 20000))
      ]);

      // ---- output ----
      outSigL = outSigL * out_level;
      outSigR = outSigR * out_level;

      // record into freeze buffer
      BufWr.ar([srcL, srcR], buf, Phasor.ar(0, BufRateScale.kr(buf), 0, BufFrames.kr(buf)));

      Out.ar(outL, outSigL);
      Out.ar(outR, outSigR);

    }).add;

    context.server.sync;

    synth = Synth(\kastle2_engine, [
      \inL,  inBus.index,
      \inR,  inBus.index + 1,
      \outL, outBus.index,
      \outR, outBus.index + 1,
      \buf,  fxBuf.bufnum
    ], context.xg);

    this.addCommand("mode", "i", { arg msg; synth.set(\mode, msg[1]) });
    this.addCommand("p1", "f", { arg msg; synth.set(\p1, msg[1]) });
    this.addCommand("p2", "f", { arg msg; synth.set(\p2, msg[1]) });
    this.addCommand("in_level", "f", { arg msg; synth.set(\in_level, msg[1]) });
    this.addCommand("out_level", "f", { arg msg; synth.set(\out_level, msg[1]) });
    this.addCommand("filter_mode", "i", { arg msg; synth.set(\filter_mode, msg[1]) });
    this.addCommand("filter_freq", "f", { arg msg; synth.set(\filter_freq, msg[1]) });
    this.addCommand("filter_res", "f", { arg msg; synth.set(\filter_res, msg[1]) });
    this.addCommand("tempo", "f", { arg msg; synth.set(\tempo, msg[1]) });
    this.addCommand("frozen", "i", { arg msg; synth.set(\frozen, msg[1]) });
    this.addCommand("width", "f", { arg msg; synth.set(\width, msg[1]) });
  }

  free {
    synth.free;
    fxBuf.free;
  }
}
