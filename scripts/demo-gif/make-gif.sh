#!/bin/zsh
# Renders scene.html frame by frame and encodes docs/lina-demo.gif (3:2; SCALE=1.5 gives 1440×960).
# Needs ffmpeg and gstack's headless browser (~/.claude/skills/gstack/browse/dist/browse).
set -euo pipefail
cd "$(dirname "$0")"
B=${BROWSE:-$HOME/.claude/skills/gstack/browse/dist/browse}
FPS=${FPS:-15}
SCALE=${SCALE:-1.5}
W=$(( 960 * SCALE )); H=$(( 640 * SCALE ))
OUT=${OUT:-../../docs/lina-demo.gif}
FRAMES=$(mktemp -d)
trap 'rm -rf "$FRAMES"' EXIT

$B viewport ${W%.*}x${H%.*} >/dev/null
$B goto "file://$PWD/scene.html?scale=$SCALE" >/dev/null
sleep 1
duration=$($B js "DURATION")
count=$(( ${duration%.*} * FPS ))
echo "› ${W%.*}×${H%.*} at $FPS fps"
echo "› Rendering $count frames"
for (( i = 0; i < count; i++ )); do
  $B js "render($i / $FPS)" >/dev/null
  $B screenshot --viewport "$FRAMES/f$(printf %04d $i).png" >/dev/null
done

echo "› Encoding $OUT"
ffmpeg -loglevel error -y -framerate "$FPS" -i "$FRAMES/f%04d.png" \
  -vf "split[a][b];[a]palettegen=max_colors=256:stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle" \
  -loop 0 "$OUT"
ls -lh "$OUT" | awk '{print "✓ " $9 " · " $5}'
