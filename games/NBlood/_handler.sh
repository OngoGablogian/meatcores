#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Frontier Master-Daemon handler for MiSTer NBlood.
set -u

GAMEDIR="/media/fat/games/NBlood"
LOGDIR="/media/fat/logs/NBlood"
BINARY="$GAMEDIR/NBlood"
SAVEDIR="$GAMEDIR/Saves"
CFGFILE="$SAVEDIR/blood.cfg"

mkdir -p "$GAMEDIR" "$LOGDIR" "$SAVEDIR"

# NBlood writes save slots relative to its current directory when -game_dir is
# absolute. Preserve existing installs by copying legacy root-level state once,
# without replacing a save or configuration already in Saves/.
for legacy in "$GAMEDIR"/game*.sav "$GAMEDIR"/blood.cfg \
              "$GAMEDIR"/blood_cvars.cfg "$GAMEDIR"/blood_settings.cfg; do
    [ -f "$legacy" ] || continue
    name="${legacy##*/}"
    [ -e "$SAVEDIR/$name" ] || cp -p "$legacy" "$SAVEDIR/$name"
done

cd "$SAVEDIR" || exit 1

if [ ! -x "$BINARY" ]; then
    echo "NBlood Frontier: missing executable $BINARY" >> "$LOGDIR/nblood.log"
    exit 1
fi

# v1 retains SDL for NBlood's event/timer scaffolding but bypasses its final
# display and PCM backends. A dummy video driver avoids opening Linux fb/X/DRM.
export SDL_VIDEODRIVER=dummy
export MISTER_FRONTIER=1
# Lets MisterPlatform_PrefetchGameData() (mister_platform.c) find the data
# files to warm into the page cache; same directory passed below as
# -game_dir. Best-effort only; see MISTER_FRONTIER_NO_PREFETCH to disable.
export NBLOOD_GAME_DIR="$GAMEDIR"

# Create this empty file only while collecting a target-side performance trace.
# The bridge writes one summary per second to nblood.log and otherwise adds no
# timing calls to the presentation path.
if [ -e "$GAMEDIR/.frontier-perf" ]; then
    export MISTER_FRONTIER_PERF_LOG=1
fi

# 2026-09-03: the wall-clock present-rate gate (MISTER_FRONTIER_PRESENT_DIVISOR)
# that used to live in mister_video.c was removed rather than fixed further --
# on hardware it fought the FPGA's own single-vblank ack pacing whenever it
# skipped a publish (attempts=24 published=4 dropped=20 in one 1 s window),
# and it could not reduce render cost anyway since the frame was already fully
# rendered by the time it ran. Use .frontier-render below (320x240) to target
# a lower CPU cost instead; see docs/PERFORMANCE.md.

# Optional software render size, one line, "320x240" or "640x480" (default).
# Measured 2026-09-03: the classic renderer needs ~17 ms per 640x480 frame on
# the 800 MHz Cortex-A9 (about 49 fps in E1M1's start view, lower in combat),
# while 320x240 pixel-replicated by the bridge into the same 640x480 raster
# fits comfortably inside the 16.7 ms frame. The FPGA and DDR contract do not
# change; only the ARM render size does.
if [ -f "$GAMEDIR/.frontier-render" ]; then
    export MISTER_FRONTIER_RENDER="$(head -n 1 "$GAMEDIR/.frontier-render" | tr -d '[:space:]')"
fi

# Optional diagnostic launch arguments, one line, e.g. "-map E1M1 -nodemo" to
# start straight into a level for a frame-timing capture. Delete the file to
# return to the normal title-screen launch.
EXTRA_ARGS=""
if [ -f "$GAMEDIR/.frontier-args" ]; then
    EXTRA_ARGS="$(head -n 1 "$GAMEDIR/.frontier-args")"
fi

# Allow the freshly loaded FPGA design to settle, matching Frontier-family use.
sleep 1
mv -f "$LOGDIR/nblood.log" "$LOGDIR/nblood.prev.log" 2>/dev/null || true

# NBlood treats a slash-prefixed next argv token as another option, so absolute
# paths must be attached with '=' instead of supplied as separate arguments.
# Measured 2026-09-02: MiSTer Main alone keeps one Cortex-A9 core ~45% busy
# and the renderer saturates the other. Give the renderer CPU1 to itself; the
# audio mixer thread pins itself to CPU0 next to Main (driver_mister.cpp).
# shellcheck disable=SC2086
exec taskset 0x02 "$BINARY" -game_dir="$GAMEDIR" -cfg="$CFGFILE" $EXTRA_ARGS > "$LOGDIR/nblood.log" 2>&1
