#!/usr/bin/env python3
"""Generates the app's sound effects into assets/sounds/ (16-bit mono WAV, 44.1 kHz).

The brief: minimal, soft and a little bassy — never sharp or high-pitched. Every sound is built
from warm "mallet" tones: a sine with a touch of its octave and twelfth, a short sub-octave for
body, a gentle attack (no clicks), an exponential decay and a low-pass filter that rounds off
the top end. Nothing goes above about 600 Hz fundamental.

    python3 tool/generate_sounds.py        # from mobile/
"""

import math
import struct
import wave
from pathlib import Path

RATE = 44_100
OUT = Path(__file__).resolve().parent.parent / "assets" / "sounds"


def mallet(
    freq: float,
    dur: float,
    *,
    attack: float = 0.008,
    decay: float = 9.0,
    sub: float = 0.18,
    bright: float = 0.22,
    bend: float = 0.0,
) -> list[float]:
    """One soft struck tone. ``bend`` glides the pitch (in octaves) over the note."""
    n = int(dur * RATE)
    out = []
    phase = 0.0
    for i in range(n):
        t = i / RATE
        f = freq * (2 ** (bend * t / dur))
        phase += 2 * math.pi * f / RATE
        env = min(1.0, t / attack) * math.exp(-decay * t)
        # The overtones fade faster than the fundamental: the attack has a little shape, the
        # tail is pure and round.
        over = math.exp(-decay * 2.5 * t)
        s = (
            math.sin(phase)
            + bright * over * math.sin(2 * phase)
            + 0.06 * over * math.sin(3 * phase)
            + sub * math.exp(-decay * 1.4 * t) * math.sin(phase / 2)
        )
        out.append(s * env)
    return out


def swell(freqs: list[float], dur: float, *, attack: float = 0.09, decay: float = 3.2) -> list[float]:
    """A soft chord that fades in and out, for bigger moments."""
    n = int(dur * RATE)
    out = []
    for i in range(n):
        t = i / RATE
        env = (1 - math.exp(-t / (attack / 3))) * math.exp(-decay * t)
        s = sum(
            math.sin(2 * math.pi * f * t) + 0.12 * math.sin(4 * math.pi * f * t) for f in freqs
        )
        out.append(s * env / len(freqs))
    return out


def mix(length: float, *parts: tuple[float, list[float], float]) -> list[float]:
    """Places (start seconds, samples, gain) parts on one track."""
    track = [0.0] * int(length * RATE)
    for start, samples, gain in parts:
        offset = int(start * RATE)
        for i, s in enumerate(samples):
            if offset + i < len(track):
                track[offset + i] += s * gain
    return track


def lowpass(samples: list[float], cutoff: float) -> list[float]:
    """Two passes of a one-pole low-pass: rounds off anything sharp."""
    a = math.exp(-2 * math.pi * cutoff / RATE)
    for _ in range(2):
        y = 0.0
        filtered = []
        for x in samples:
            y = (1 - a) * x + a * y
            filtered.append(y)
        samples = filtered
    return samples


def finish(samples: list[float], *, peak: float = 0.55, fade: float = 0.04) -> list[float]:
    """Normalises to ``peak`` (soft, with headroom) and fades the last ``fade`` seconds."""
    top = max(abs(s) for s in samples) or 1.0
    k = peak / top
    n = len(samples)
    tail = int(fade * RATE)
    return [s * k * (min(1.0, (n - i) / tail) if tail else 1.0) for i, s in enumerate(samples)]


def write(name: str, samples: list[float]) -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    with wave.open(str(OUT / f"{name}.wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, s)) * 32767)) for s in samples))


# Notes (Hz).
A2, C3, E3, F3, G3, A3, B3 = 110.0, 130.81, 164.81, 174.61, 196.0, 220.0, 246.94
C4, D4, E4, G4, A4, C5 = 261.63, 293.66, 329.63, 392.0, 440.0, 523.25

SOUNDS = {
    # A right answer: two warm notes stepping up a fifth.
    "correct": lambda: lowpass(
        mix(0.62, (0.0, mallet(D4, 0.3, decay=11), 0.8), (0.085, mallet(A4, 0.53, decay=7), 0.9)),
        1800,
    ),
    # A wrong answer: a low, muted bump that settles down. Not a buzzer.
    "wrong": lambda: lowpass(
        mix(
            0.5,
            (0.0, mallet(A3, 0.22, decay=13, bright=0.12), 0.85),
            (0.07, mallet(F3, 0.43, decay=8, bright=0.1, bend=-0.08), 0.9),
        ),
        1100,
    ),
    # A question ran out of time: one soft low tock, falling slightly.
    "timeout": lambda: lowpass(mallet(E3, 0.38, decay=9, bright=0.1, bend=-0.12), 1000),
    # A countdown second (3, 2, 1) and the start ("go").
    "tick": lambda: lowpass(mallet(G3, 0.16, decay=22, bright=0.15), 1400),
    "go": lambda: lowpass(mix(0.42, (0.0, mallet(C4, 0.42, decay=8), 1.0)), 1600),
    # An opponent was found: a gentle chord that blooms.
    "found": lambda: lowpass(
        mix(
            0.95,
            (0.0, swell([C3, G3, E4], 0.95, attack=0.07, decay=3.6), 1.0),
            (0.0, mallet(G4, 0.6, decay=6, bright=0.1), 0.35),
        ),
        1600,
    ),
    # A win: a rising arpeggio, the last note left to ring.
    "win": lambda: lowpass(
        mix(
            1.3,
            (0.0, mallet(C4, 0.35, decay=9), 0.75),
            (0.1, mallet(E4, 0.35, decay=9), 0.75),
            (0.2, mallet(G4, 0.35, decay=9), 0.8),
            (0.3, mallet(C5, 1.0, decay=3.8, bright=0.12), 0.85),
            (0.3, swell([C3, G3], 1.0, attack=0.05, decay=3.0), 0.45),
        ),
        1900,
    ),
    # A loss: two notes that ease downward, kind rather than sad.
    "lose": lambda: lowpass(
        mix(
            0.95,
            (0.0, mallet(E4, 0.4, decay=8, bright=0.12), 0.75),
            (0.16, mallet(C4, 0.75, decay=4.5, bright=0.1), 0.8),
            (0.16, swell([A2, E3], 0.75, attack=0.05, decay=3.6), 0.4),
        ),
        1300,
    ),
    # A draw: one level, warm note.
    "draw": lambda: lowpass(
        mix(0.8, (0.0, mallet(D4, 0.8, decay=4.5, bright=0.12), 0.9), (0.0, swell([D4 / 2], 0.8), 0.35)),
        1400,
    ),
    # A practice set finished: three notes up, softer than a win.
    "complete": lambda: lowpass(
        mix(
            1.0,
            (0.0, mallet(G3, 0.3, decay=10), 0.75),
            (0.09, mallet(D4, 0.3, decay=10), 0.75),
            (0.18, mallet(G4, 0.82, decay=4.5, bright=0.12), 0.8),
        ),
        1700,
    ),
    # Something good landed (coins, XP, a level): a small soft chime.
    "reward": lambda: lowpass(
        mix(0.6, (0.0, mallet(E4, 0.3, decay=10), 0.7), (0.07, mallet(B3 * 2, 0.53, decay=6), 0.7)),
        1900,
    ),
}


def main() -> None:
    for name, build in SOUNDS.items():
        write(name, finish(build()))
        print(f"assets/sounds/{name}.wav")


if __name__ == "__main__":
    main()
