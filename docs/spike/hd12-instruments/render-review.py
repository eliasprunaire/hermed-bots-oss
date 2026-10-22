#!/usr/bin/env python3
"""Assemble les captures horodatées de la fenêtre XCUITest, sans accès à l'écran hôte."""
import json
import re
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
frames = [(name, float(stamp)) for name, stamp in re.findall(
    r"HV-VIDEO frame=(hd12-video-\d{3}) at=([0-9.]+)", (root / "xcodebuild.log").read_text())]
assert len(frames) >= 6, "parcours vidéo incomplet"
assert [name for name, _ in frames] == [f"hd12-video-{i:03d}" for i in range(len(frames))], "ordre des captures invalide"
assert 30 <= frames[-1][1] - frames[0][1] <= 60, "durée du parcours hors de 30 à 60 secondes"
lines = []
for i, (name, stamp) in enumerate(frames):
    shot = root / "shots" / (name + ".png")
    assert shot.is_file(), f"capture absente : {shot}"
    duration = frames[i + 1][1] - stamp if i + 1 < len(frames) else 0.5
    assert 0 < duration <= 60, "horodatages invalides"
    lines.extend([f"file 'shots/{name}.png'", f"duration {duration:.6f}"])
lines.append(f"file 'shots/{frames[-1][0]}.png'")
manifest = root / "hd12-video.ffconcat"
manifest.write_text("\n".join(lines) + "\n")
video = root / "hd12-review.mp4"
subprocess.run(["ffmpeg", "-n", "-v", "error", "-f", "concat", "-i", str(manifest),
                "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                "-movflags", "+faststart", str(video)], check=True)
probe = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                                           "-of", "json", str(video)]))
seconds = float(probe["format"]["duration"])
assert 30 <= seconds <= 60, "durée du film hors de 30 à 60 secondes"
print(f"HV-VIDEO fichier={video} captures={len(frames)} durée={seconds:.3f}s méthode=XCUITest-horodaté")
