#!/bin/bash
source "${SCRIPTSDIR}/helper-functions.sh"

# Switch to workdir
cd "${STEAMAPPDIR}" || exit

### Function for gracefully shutdown
function kill_corekeeperserver {
    if [[ -n "$ckpid" ]]; then
        kill $ckpid
        wait $ckpid
    fi
    if [[ -n "$xvfbpid" ]]; then
        kill $xvfbpid
        wait $xvfbpid
    fi

    # Sends stop message
    if [[ "${DISCORD_SERVER_STOP_ENABLED,,}" == true ]]; then
        wait=true
        SendDiscordMessage "$DISCORD_SERVER_STOP_TITLE" "$DISCORD_SERVER_STOP_MESSAGE" "$DISCORD_SERVER_STOP_COLOR" "$wait"
    fi
}

trap kill_corekeeperserver EXIT

if [ -f "GameID.txt" ]; then rm GameID.txt; fi
if [ -f "GameInfo.txt" ]; then rm GameInfo.txt; fi

# Compile Parameters
# Populates `params` array with parameters.
# Creates `logfile` var with log file path.
source "${SCRIPTSDIR}/compile-parameters.sh"

# Create the log file and folder.
mkdir -p "${STEAMAPPDIR}/logs"
touch "$logfile"

# Start Xvfb
Xvfb :99 -screen 0 1x1x24 -nolisten tcp &
xvfbpid=$!

# Get the architecture using dpkg
architecture=$(dpkg --print-architecture)

# Optimize Unity for server performance
# Set job workers based on CPU core count to improve tick rate consistency
CORE_COUNT=$(nproc)
# For servers with fewer cores, use more aggressive allocation
if [ "$CORE_COUNT" -le 8 ]; then
    # Small servers: use core_count - 1 (leave 1 for system)
    WORKER_COUNT=$((CORE_COUNT - 1))
else
    # Larger servers: use 75% of cores
    WORKER_COUNT=$((CORE_COUNT * 3 / 4))
fi
# Ensure at least 4 workers, cap at 20 to avoid over-subscription
if [ "$WORKER_COUNT" -lt 4 ]; then
    WORKER_COUNT=4
elif [ "$WORKER_COUNT" -gt 20 ]; then
    WORKER_COUNT=20
fi
export UNITY_JOB_WORKER_COUNT=${WORKER_COUNT}

# Increase memory allocators to reduce fragmentation and allocation overhead
export UNITY_MEMORY_ALLOCATOR_SETTINGS="bucket-allocator-granularity=16,bucket-allocator-bucket-count=8,bucket-allocator-block-size=8388608,main-allocator-block-size=67108864,thread-allocator-block-size=67108864"

# Reduce graphics overhead
export UNITY_NO_GRAPHICS_API_WARNINGS=1
export __GL_SYNC_TO_VBLANK=0
export vblank_mode=0

LogAction "Optimizing Unity: ${WORKER_COUNT} job workers (${CORE_COUNT} cores available)"

# Update boot.config to set job worker count
BOOT_CONFIG="${STEAMAPPDIR}/CoreKeeperServer_Data/boot.config"
if [ -f "$BOOT_CONFIG" ]; then
    # Update or add job-worker-count in boot.config
    if grep -q "^job-worker-count=" "$BOOT_CONFIG"; then
        sed -i "s/^job-worker-count=.*/job-worker-count=${WORKER_COUNT}/" "$BOOT_CONFIG"
    else
        echo "job-worker-count=${WORKER_COUNT}" >> "$BOOT_CONFIG"
    fi
    LogAction "Updated boot.config: job-worker-count=${WORKER_COUNT}"
fi

# Start Core Keeper Server
if [ "$architecture" == "arm64" ]; then
    DISPLAY=:99 LD_LIBRARY_PATH="${STEAMCMDDIR}/linux64:${BOX64_LD_LIBRARY_PATH}:${LD_LIBRARY_PATH}" /usr/local/bin/box64 ./CoreKeeperServer "${params[@]}" &
else
    DISPLAY=:99 LD_LIBRARY_PATH="${LD_LIBRARY_PATH}:${STEAMCMDDIR}/linux64/" ./CoreKeeperServer "${params[@]}" &
fi
ckpid=$!

LogAction "Started server process with pid ${ckpid}"

# Monitor server logs for player join/leave, server start, and server stop
source "${SCRIPTSDIR}/logfile-parser.sh"
tail --pid "$ckpid" -f "$logfile" | LogParser &

wait $ckpid
