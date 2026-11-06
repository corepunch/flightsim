"""Build mono radio deliveries from the small, preserved Runway speech masters."""
import array
import json
import math
from pathlib import Path
import random
import subprocess
import tempfile
import wave

ROOT = Path(__file__).resolve().parent
OUTPUT = ROOT.parents[1] / "Audio" / "Radio"
RATE = 22050


def build(asset):
    with tempfile.TemporaryDirectory(prefix="kestrel-radio-") as temporary:
        decoded = Path(temporary) / "decoded.wav"
        subprocess.run(["afconvert", str(ROOT / "Masters" / asset["master"]),
                        str(decoded), "-f", "WAVE", "-d", f"LEI16@{RATE}", "-c", "1"], check=True)
        with wave.open(str(decoded), "rb") as source:
            samples = array.array("h", source.readframes(source.getnframes()))
    # Trim only edge silence; leave breaths and pauses inside the performance.
    audible = [i for i, value in enumerate(samples) if abs(value) > 300]
    if not audible:
        raise ValueError(f"Silent master: {asset['master']}")
    samples = samples[max(0, audible[0] - RATE // 25):min(len(samples), audible[-1] + RATE // 12)]
    rng = random.Random(asset["id"])
    high_pass = low_pass = second_low = previous = 0.0
    high_alpha = math.exp(-2 * math.pi * 650 / RATE)
    low_alpha = 1 - math.exp(-2 * math.pi * 2200 / RATE)
    filtered = []
    for value in samples:
        value /= 32768
        high_pass = high_alpha * (high_pass + value - previous)
        previous = value
        low_pass += low_alpha * (high_pass - low_pass)
        second_low += low_alpha * (low_pass - second_low)
        # Narrow receiver bandwidth and hard transmitter overdrive, not studio EQ.
        filtered.append(round(math.tanh(second_low * 9) * 63) / 63)
    rms = math.sqrt(sum(value * value for value in filtered) / len(filtered))
    gain = min(0.72 / max(abs(value) for value in filtered), 0.18 / rms)
    lead, tail = int(RATE * 0.095), int(RATE * 0.12)
    result = []
    previous_noise = crackle = 0.0
    for i in range(lead + len(filtered) + tail):
        at = i - lead
        in_voice = 0 <= at < len(filtered)
        envelope = min(1, max(0, at) / (RATE * 0.006), max(0, len(filtered) - at - 1) / (RATE * 0.008))
        voice = filtered[at] * gain * envelope if in_voice else 0
        # Audible receiver hiss, intermittent crackle and an opening/closing squelch.
        white = rng.uniform(-1, 1)
        hiss = white - previous_noise * 0.72
        previous_noise = white
        if rng.random() < 22 / RATE:
            crackle = rng.uniform(-0.22, 0.22)
        crackle *= 0.91
        noise = hiss * (0.042 if in_voice else 0.12) + crackle
        edge = min(1, i / (RATE * 0.004), (lead + len(filtered) + tail - i - 1) / (RATE * 0.006))
        result.append(round(max(-0.95, min(0.95, (voice + noise) * edge)) * 32767))
    destination = OUTPUT / asset["file"]
    with wave.open(str(destination), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(RATE)
        output.writeframes(array.array("h", result).tobytes())
    rms = math.sqrt(sum((value / 32768) ** 2 for value in result) / len(result))
    if not 1 < len(result) / RATE < 8 or rms < 0.015:
        raise ValueError(f"Invalid delivery: {asset['id']}")
    print(f"{asset['file']}: {len(result) / RATE:.2f}s, RMS {rms:.3f}")
    return {key: asset[key] for key in ("key", "text", "file")} | {"durationSeconds": len(result) / RATE}


if __name__ == "__main__":
    OUTPUT.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((ROOT / "manifest.json").read_text())
    catalog = {"language": manifest["language"], "lines": [build(asset) for asset in manifest["assets"]]}
    (OUTPUT / "catalog.json").write_text(json.dumps(catalog, indent=2) + "\n")
