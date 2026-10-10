#!/usr/bin/env python3
"""Backchannel's notification tones, synthesized from scratch into app/Sounds/*.aiff.

    uv run --with numpy --with scipy --with pyloudnorm tools/sounds/tones.py

Every tone keeps to the same rules, taken from what makes alert sounds grate:
- Notes come from C major pentatonic, so no two notes clash, even across tones, and the
  only intervals are consonant ones (fourths, fifths, thirds, octaves).
- Fundamentals sit between 440 and 1050 Hz. Little energy reaches 2-5 kHz, where the ear
  is most sensitive and alarms live; upper partials ring briefly and quietly.
- Notes are 120-150 ms apart (60-90 ms reads as hurried). Mallets are soft, with no
  click, and decays are natural exponentials. Every tone is under a second and a half.
- One loudness: each tone peaks at the same momentary loudness (-20 LUFS, about Tri-tone's
  level), so switching tones never jumps in volume. Mono, because laptop speakers are.
"""
import os
import subprocess
import tempfile

import numpy as np
import pyloudnorm as pyln
from scipy.io import wavfile
from scipy.signal import butter, fftconvolve, resample_poly, sosfilt

SR = 48000
TARGET_LUFS = -20.0   # momentary (400 ms) maximum
CEILING_DBTP = -1.5
OUT = os.path.join(os.path.dirname(__file__), "..", "..", "app", "Sounds")

HZ = {"A4": 440.00, "C5": 523.25, "D5": 587.33, "E5": 659.26, "G5": 783.99,
      "A5": 880.00, "C6": 1046.50}

rng = np.random.default_rng(26)   # fixed, so a rebuild writes identical files


# MARK: building blocks

def secs(n):
    return np.arange(n) / SR


def decay(n, t60):
    """Exponential decay reaching -60 dB at t60 seconds."""
    return np.exp(-6.9078 * secs(n) / t60)


def onset(n, ms):
    """A raised-cosine fade-in, so a note never starts with a click."""
    e = np.ones(n)
    a = min(n, max(2, int(SR * ms / 1000)))
    e[:a] = np.sin(np.linspace(0, np.pi / 2, a)) ** 2
    return e


def outro(n, ms=15):
    """A short fade at the very end, so a note cut off while still ringing doesn't click."""
    e = np.ones(n)
    f = min(n, int(SR * ms / 1000))
    e[n - f:] = np.cos(np.linspace(0, np.pi / 2, f)) ** 2
    return e


def lowpass(x, hz, order=2):
    return sosfilt(butter(order, hz, "low", fs=SR, output="sos"), x)


def highpass(x, hz, order=2):
    return sosfilt(butter(order, hz, "high", fs=SR, output="sos"), x)


def modes(f0, parts, length, attack_ms=3.0):
    """A struck bar or bell: decaying partials, each (ratio, amplitude, t60)."""
    n = int(SR * length)
    t = secs(n)
    out = np.zeros(n)
    for ratio, amp, t60 in parts:
        f = f0 * ratio
        if f < SR * 0.45:
            out += amp * np.sin(2 * np.pi * f * t + rng.uniform(0, 2 * np.pi)) * decay(n, t60)
    return out * onset(n, attack_ms) * outro(n)


def mallet(ms, cutoff, level):
    """The felt or wood of the mallet: a few ms of low-passed noise under the attack."""
    n = int(SR * ms / 1000)
    x = rng.standard_normal(n) * np.linspace(1, 0, n) ** 2
    x = lowpass(x, cutoff, 4)
    return level * x / np.abs(x).max()


def room(x, t60=0.3, predelay_ms=9, wet=0.12, tone_hz=3500):
    """A small, dark room: just enough air that the tone doesn't sound pasted on."""
    n = int(SR * t60)
    ir = rng.standard_normal(n) * decay(n, t60)
    ir = lowpass(ir, tone_hz)
    ir /= np.sqrt((ir ** 2).sum())
    ir = np.concatenate([np.zeros(int(SR * predelay_ms / 1000)), ir])
    tail = fftconvolve(x, ir)[: len(x) + len(ir)]
    dry = np.concatenate([x, np.zeros(len(tail) - len(x))])
    return dry + wet * tail


def place(buf, x, at):
    i = int(SR * at)
    end = min(len(buf), i + len(x))
    buf[i:end] += x[: end - i]


# MARK: instruments

def marimba(f0, length=0.7, amp=1.0):
    # Rosewood bar, second mode tuned to ~4x and the third to ~10x; both die fast.
    body = modes(f0, [(1.0, 1.0, 0.50), (3.92, 0.08, 0.07), (9.24, 0.010, 0.02)], length, 3.0)
    body[: int(SR * 0.006)] += mallet(6, 2000, 0.05)
    return amp * body


def kalimba(f0, length=0.9, amp=1.0):
    # A clamped tine: overtone at 6.27x gives the ping; a little 2x from the box.
    body = modes(f0, [(1.0, 1.0, 0.75), (2.0, 0.04, 0.25), (6.27, 0.05, 0.05)], length, 2.5)
    body[: int(SR * 0.004)] += mallet(4, 2400, 0.04)
    return amp * body


def vibraphone(f0, length=1.2, amp=1.0, rate=5.2, depth=0.10):
    # Metal bar under yarn mallets: long, round fundamental and a slow shimmer from the motor.
    n = int(SR * length)
    body = modes(f0, [(1.0, 1.0, 1.4), (4.0, 0.045, 0.18), (10.0, 0.008, 0.04)], length, 4.0)
    ramp = np.clip(secs(n) / 0.12, 0, 1)
    body *= 1 - depth * ramp * (0.5 - 0.5 * np.cos(2 * np.pi * rate * secs(n)))
    body[: int(SR * 0.008)] += mallet(8, 900, 0.03)
    return amp * body


def bell(f0, length=1.0, amp=1.0):
    # A small, soft bell: mostly harmonic, with a faint inharmonic shimmer that fades first.
    body = modes(f0, [(1.0, 1.0, 0.9), (2.0, 0.09, 0.35), (3.0, 0.03, 0.15), (4.16, 0.012, 0.06)],
                 length, 3.0)
    body[: int(SR * 0.005)] += mallet(5, 1800, 0.025)
    return amp * body


def droplet(f_start, f_end, length=0.3, amp=1.0, rise=0.016, t60=0.15):
    # A bubble's resonance climbs as it reaches the surface; the pitch lands on f_end.
    n = int(SR * length)
    t = secs(n)
    f = f_end - (f_end - f_start) * np.exp(-t / rise)
    phase = 2 * np.pi * np.cumsum(f) / SR
    x = (np.sin(phase) + 0.06 * np.sin(2 * phase)) * decay(n, t60)
    return amp * x * onset(n, 1.5) * outro(n)


def woodblock(f0, length=0.25, amp=1.0):
    # Hollow wood: short, slightly inharmonic modes and more mallet than tone.
    body = modes(f0, [(1.0, 1.0, 0.10), (1.47, 0.30, 0.05), (2.09, 0.12, 0.03)], length, 1.2)
    body[: int(SR * 0.003)] += mallet(3, 2200, 0.08)
    return amp * body


# MARK: the tones

def nudge():
    # The default. Two marimba notes stepping up a fourth: "hey", not "alert".
    buf = np.zeros(int(SR * 0.95))
    place(buf, marimba(HZ["E5"], amp=0.72), 0.0)
    place(buf, marimba(HZ["A5"], length=0.8), 0.13)
    return room(buf)


def tine():
    # Kalimba, falling a fourth: settles rather than calls.
    buf = np.zeros(int(SR * 1.1))
    place(buf, kalimba(HZ["C6"], amp=0.8), 0.0)
    place(buf, kalimba(HZ["G5"]), 0.14)
    return room(buf)


def chime():
    # Three small bells up a major triad: the most noticeable, still consonant and slow.
    buf = np.zeros(int(SR * 1.3))
    for i, (note, amp) in enumerate([("E5", 0.62), ("G5", 0.74), ("C6", 1.0)]):
        place(buf, bell(HZ[note], amp=amp), 0.125 * i)
    return room(buf, wet=0.14)


def glow():
    # One vibraphone note with its octave below: a single soft bloom.
    buf = np.zeros(int(SR * 1.3))
    place(buf, vibraphone(HZ["G5"]), 0.0)
    place(buf, vibraphone(HZ["G5"] / 2, amp=0.28, depth=0.06), 0.0)
    return room(buf, wet=0.10)


def drop():
    # Two water drops, the second higher and quieter. The shortest tone.
    buf = np.zeros(int(SR * 0.55))
    place(buf, droplet(HZ["A5"] * 0.55, HZ["A5"]), 0.0)
    place(buf, droplet(HZ["C6"] * 0.55, HZ["C6"], amp=0.5), 0.15)
    return room(buf, wet=0.16)


def hush():
    # No strike at all: an open fifth that swells in and fades, like a held breath.
    n = int(SR * 1.0)
    t = secs(n)
    x = np.zeros(n)
    for f, a in [(HZ["A4"], 0.7), (HZ["E5"], 0.45), (HZ["A5"], 0.25)]:
        x += a * np.sin(2 * np.pi * f * t + rng.uniform(0, 2 * np.pi))
    x *= onset(n, 45) * decay(n, 0.85) * outro(n)
    return room(lowpass(x, 3000), wet=0.10)


def tap():
    # Two taps on a wood block, up a minor third. For people who'd rather not hear a melody.
    buf = np.zeros(int(SR * 0.45))
    place(buf, woodblock(HZ["A5"], amp=0.8), 0.0)
    place(buf, woodblock(HZ["C6"]), 0.13)
    return room(buf, t60=0.22, wet=0.10)


TONES = {"Nudge": nudge, "Tine": tine, "Chime": chime, "Glow": glow,
         "Drop": drop, "Hush": hush, "Tap": tap}


# MARK: finishing

def momentary_max(x):
    """The loudest 400 ms window (EBU momentary loudness), in LUFS."""
    meter = pyln.Meter(SR, block_size=0.4)
    pad = np.concatenate([x, np.zeros(int(SR * 0.4))])
    win, hop = int(SR * 0.4), int(SR * 0.01)
    best = -120.0
    for i in range(0, len(pad) - win + 1, hop):
        seg = pad[i: i + win]
        if np.abs(seg).max() > 1e-6:
            best = max(best, meter.integrated_loudness(seg))
    return best


def true_peak_db(x):
    return 20 * np.log10(np.abs(resample_poly(x, 4, 1)).max() + 1e-12)


def finish(x):
    x = highpass(x, 140)          # nothing a laptop speaker would only rattle on
    x = lowpass(x, 7000)          # and nothing glassy on top
    x -= x.mean()
    # Trim the tail once it's 66 dB down, then fade the last 20 ms to true silence.
    level = np.abs(x) / np.abs(x).max()
    end = min(len(x), np.where(level > 10 ** (-66 / 20))[0][-1] + 1)
    x = x[:end]
    fade = int(SR * 0.02)
    x[-fade:] *= np.cos(np.linspace(0, np.pi / 2, fade)) ** 2
    x *= 10 ** ((TARGET_LUFS - momentary_max(x)) / 20)
    over = true_peak_db(x) - CEILING_DBTP
    if over > 0:
        x *= 10 ** (-over / 20)
    return x


def write_aiff(path, x):
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        wav = tmp.name
    wavfile.write(wav, SR, np.round(np.clip(x, -1, 1) * 32767).astype(np.int16))
    # Big-endian 16-bit linear PCM AIFF: the format macOS plays most reliably.
    subprocess.run(["afconvert", "-f", "AIFF", "-d", "BEI16@48000", wav, path], check=True)
    os.unlink(wav)


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    print(f"{'tone':8} {'length':>7} {'LUFS(M)':>8} {'dBTP':>6}")
    for name, make in TONES.items():
        x = finish(make())
        write_aiff(os.path.join(OUT, name + ".aiff"), x)
        print(f"{name:8} {len(x) / SR:6.2f}s {momentary_max(x):8.1f} {true_peak_db(x):6.1f}")
