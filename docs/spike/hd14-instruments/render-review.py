#!/usr/bin/env python3
"""Assemble uniquement les captures XCUITest horodatées de la VM."""
import json
from pathlib import Path
import re
import subprocess
import sys

root = Path(sys.argv[1]).resolve()
frames = re.findall(r'HV-VIDEO frame=(hd14-video-\d{3}) at=([0-9.]+)', (root / 'testRecordedReview.log').read_text())
assert len(frames) >= 6
assert [name for name, _ in frames] == [f'hd14-video-{i:03d}' for i in range(len(frames))]
assert 30 <= float(frames[-1][1]) - float(frames[0][1]) <= 60
lines = []
for i, (name, stamp) in enumerate(frames):
    assert (root / 'shots' / (name + '.png')).is_file()
    duration = float(frames[i + 1][1]) - float(stamp) if i + 1 < len(frames) else .5
    assert 0 < duration <= 60
    lines += [f"file 'shots/{name}.png'", f'duration {duration:.6f}']
lines += [f"file 'shots/{frames[-1][0]}.png'"]
manifest = root / 'hd14-review.ffconcat'
manifest.write_text('\n'.join(lines) + '\n')
video = root / 'hd14-review.mp4'
subprocess.run(['ffmpeg', '-y', '-v', 'error', '-f', 'concat', '-i', str(manifest), '-vf', 'pad=ceil(iw/2)*2:ceil(ih/2)*2', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', str(video)], check=True)
seconds = float(json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'json', str(video)]))['format']['duration'])
assert 30 <= seconds <= 60
print(f'HV-VIDEO fichier={video} durée={seconds:.3f}s méthode=XCUITest-horodaté')
