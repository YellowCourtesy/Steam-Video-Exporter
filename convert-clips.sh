#!/usr/bin/env bash
# =============================================================================
# process_clips.sh — Steam Clip Processor
# Combines, re-encodes, and names Steam game clips using ffmpeg.
# Dependencies: ffmpeg, coreutils (macOS), bash 4+
# =============================================================================

# --- Script version ---
script_version="1.2.2"

# ===========================================================================
# SECTION 1: ENVIRONMENT SETUP
# ===========================================================================

# Resolve the directory containing this script (works with symlinks too)
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Directory & file paths (all relative to script_dir by default) ---
clips_dir="${script_dir}/clips"           # Input: folder of clip subdirectories
output_dir="${script_dir}/Output"         # Output: final processed video files
steam_id_cache="${script_dir}/steam_id_cache.txt"  # TSV: id <tab> name <tab> source <tab> date
ffprobe_errors="${script_dir}/errors.txt"          # All ffprobe stream-integrity warnings, appended each run

# --- Encoding & debug configuration ---
# default_encoder: "copy" = stream copy (fast, no re-encode)
#                  "av1"  = re-encode with AV1 (smaller files, slower)
# This sets the default answer for the interactive AV1 prompt.
# To skip the prompt entirely, also set encoder_prompt=false below.
default_encoder="copy"

# Set to false to suppress the AV1 encoding prompt and use default_encoder as-is
encoder_prompt=true

# Debug mode controls verbosity and diagnostic output:
#   "off"     — no debug output (production default)
#   "lite"    — timing, rename, and chapter details logged
#   "default" — lite + set -x (trace every command)
#   "max"     — default + exhaustive environment audit at startup
debug_mode="off"

# Latest run log: all console output is tee'd here; cleared on each new run
latest_log="${script_dir}/latest.log"

# Temporary error log; PID-suffixed copies are written by parallel jobs
temp_errors="${script_dir}/temp_errors.txt"

# Space-separated list of files (non-recursive) to delete in step 4
files_to_delete=(
     "${script_dir}/gamerecording.pb"
     "${script_dir}/libraryfolder.vdf"
     "${script_dir}/.steam_app_list_cache.json"
     
)

# Space-separated list of directories (recursive) to delete in step 4
files_to_delete_recursive=(
     "${script_dir}/*.sync-conflict*"
)

# --- Colour helpers (ANSI) ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'   # No colour / reset

# --- Create required directories and files if they don't exist ---
mkdir -p "${clips_dir}"
mkdir -p "${output_dir}"
touch "${steam_id_cache}"
touch "${temp_errors}"
touch "${ffprobe_errors}"

# --- Clear and initialise latest.log, tee all output there ---
# Every debug mode (including "off") writes to latest.log so there's always
# a record of the most recent run. The file is truncated at the start.
: > "${latest_log}"
exec > >(tee -a "${latest_log}") 2>&1

# ---------------------------------------------------------------------------
# Detect operating system (Linux vs macOS)
# ---------------------------------------------------------------------------
os_type="$(uname -s)"
case "${os_type}" in
    Linux*)  os="linux" ;;
    Darwin*) os="macos" ;;
    *)
        echo -e "${RED}Unsupported OS: ${os_type}${NC}"
        exit 1
        ;;
esac

# ---------------------------------------------------------------------------
# Check required dependencies
# ---------------------------------------------------------------------------
missing_deps=0

# ffmpeg is required on both platforms
if ! command -v ffmpeg &>/dev/null; then
    echo -e "${RED}[ERROR] ffmpeg is not installed.${NC}"
    if [[ "${os}" == "macos" ]]; then
        echo "  Install with Homebrew:  brew install ffmpeg"
    else
        echo "  Install on Fedora:      sudo dnf install ffmpeg"
        echo "  (Enable RPM Fusion first if needed)"
    fi
    missing_deps=1
fi

# coreutils provides 'gsort' (sort -V support) on macOS
if [[ "${os}" == "macos" ]]; then
    if ! command -v gsort &>/dev/null; then
        echo -e "${RED}[ERROR] GNU coreutils (gsort) is not installed.${NC}"
        echo "  Install with Homebrew:  brew install coreutils"
        missing_deps=1
    fi
fi

# Stop immediately if any dependency is missing
if [[ "${missing_deps}" -ne 0 ]]; then
    echo -e "${RED}Please install the missing dependencies above and re-run the script.${NC}"
    exit 1
fi

# --- Optional dependency detection (not fatal, features degrade gracefully) ---
has_jq=false
has_curl=false

if command -v jq &>/dev/null; then
    has_jq=true
fi
if command -v curl &>/dev/null; then
    has_curl=true
fi

# Choose the correct natural-sort binary
if [[ "${os}" == "macos" ]]; then
    SORT_CMD="gsort"
else
    SORT_CMD="sort"
fi

# ---------------------------------------------------------------------------
# GPU detection — probe ffmpeg for hardware encoder availability.
# Sets: gpu_vendor (nvidia|amd|intel|apple|none)
#       av1_gpu_opts  — ffmpeg flags for AV1 GPU encode
#       copy_gpu_opts — ffmpeg flags for stream-copy with GPU muxing (or empty)
# All encode paths fall back to CPU if the GPU encoder probe fails.
# ---------------------------------------------------------------------------
gpu_vendor="none"
av1_gpu_opts=()      # Populated below if a supported GPU is found
copy_gpu_opts=()     # For -c copy jobs, GPU offers no real benefit; stays empty

detect_gpu() {
    # ---- macOS: Apple Silicon / AMD via VideoToolbox ----
    if [[ "${os}" == "macos" ]]; then
        # hevc_videotoolbox is always present; av1_videotoolbox appeared in macOS 14.
        # Probe by asking ffmpeg to list encoders.
        if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "av1_videotoolbox"; then
            gpu_vendor="apple"
            # av1_videotoolbox: quality 60 ≈ visually lossless, realtime allowed
            av1_gpu_opts=(-c:v av1_videotoolbox -q:v 60 -realtime 0 -c:a flac -compression_level 12)
            echo "[GPU] Apple VideoToolbox AV1 encoder detected."
            return 0
        fi
        echo "[GPU] No AV1-capable VideoToolbox encoder found; using CPU."
        return 1
    fi

    # ---- Linux: probe in priority order: NVIDIA → AMD → Intel ----

    # NVIDIA — check for the device node; lspci is a soft dependency, so
    # we also accept the presence of /dev/nvidia0 or nvidia-smi.
    local has_nvidia=false
    if [[ -e /dev/nvidia0 ]] || command -v nvidia-smi &>/dev/null; then
        has_nvidia=true
    elif command -v lspci &>/dev/null && lspci 2>/dev/null | grep -qi "NVIDIA"; then
        has_nvidia=true
    fi
    if [[ "${has_nvidia}" == "true" ]]; then
        # Confirm ffmpeg actually has the NVENC AV1 encoder (RTX 40xx+)
        if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "av1_nvenc"; then
            gpu_vendor="nvidia"
            # av1_nvenc: p7=slowest/best quality preset, cq 0=lossless-ish
            av1_gpu_opts=(-c:v av1_nvenc -preset p7 -rc vbr -cq 0 -c:a flac -compression_level 12)
            echo "[GPU] NVIDIA NVENC AV1 encoder detected."
            return 0
        elif ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "hevc_nvenc"; then
            # Older NVIDIA card — fall back to HEVC NVENC, still much faster than CPU AV1
            gpu_vendor="nvidia"
            av1_gpu_opts=(-c:v hevc_nvenc -preset p7 -rc vbr -cq 0 -c:a flac -compression_level 12)
            echo "[GPU] NVIDIA NVENC AV1 not available; using HEVC NVENC fallback."
            return 0
        fi
        echo "[GPU] NVIDIA GPU found but no usable NVENC encoder in this ffmpeg build."
    fi

    # AMD — check for /dev/dri/renderD* or lspci
    local has_amd=false
    if ls /dev/dri/renderD* &>/dev/null; then
        # VAAPI covers AMD (and Intel); check encoder name to disambiguate later
        has_amd=true
    fi
    if command -v lspci &>/dev/null && lspci 2>/dev/null | grep -qi "AMD\|ATI"; then
        has_amd=true
    fi
    if [[ "${has_amd}" == "true" ]]; then
        if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "av1_amf"; then
            gpu_vendor="amd"
            # AMF AV1: quality 0 = highest quality
            av1_gpu_opts=(-c:v av1_amf -quality 0 -c:a flac -compression_level 12)
            echo "[GPU] AMD AMF AV1 encoder detected."
            return 0
        elif ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "av1_vaapi"; then
            gpu_vendor="amd"
            # VAAPI AV1 (Mesa/RADV on AMD Navi or newer)
            av1_gpu_opts=(-vaapi_device /dev/dri/renderD128 -c:v av1_vaapi -global_quality 0 -c:a flac -compression_level 12)
            echo "[GPU] AMD VAAPI AV1 encoder detected."
            return 0
        fi
        echo "[GPU] AMD GPU found but no usable AV1 encoder in this ffmpeg build."
    fi

    # Intel — QSV (Quick Sync Video)
    local has_intel=false
    if command -v lspci &>/dev/null && lspci 2>/dev/null | grep -qi "Intel.*Graphics\|Intel.*VGA"; then
        has_intel=true
    elif [[ -e /dev/dri/renderD128 ]]; then
        has_intel=true
    fi
    if [[ "${has_intel}" == "true" ]]; then
        if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "av1_qsv"; then
            gpu_vendor="intel"
            av1_gpu_opts=(-c:v av1_qsv -global_quality 1 -c:a flac -compression_level 12)
            echo "[GPU] Intel QSV AV1 encoder detected."
            return 0
        fi
        echo "[GPU] Intel GPU found but no QSV AV1 encoder in this ffmpeg build."
    fi

    echo "[GPU] No supported GPU AV1 encoder found; using CPU (libsvtav1)."
    return 1
}

detect_gpu

# ---------------------------------------------------------------------------
# Apply debug mode
# ---------------------------------------------------------------------------
# Validate debug_mode value
case "${debug_mode}" in
    off|lite|default|max) ;;
    *)
        echo -e "${YELLOW}[WARN] Invalid debug_mode '${debug_mode}', falling back to 'off'${NC}"
        debug_mode="off"
        ;;
esac

# Helper: returns 0 (true) if the current debug level is at least the given level
debug_at_least() {
    local required="$1"
    case "${required}" in
        off)     return 0 ;;
        lite)    [[ "${debug_mode}" == "lite" || "${debug_mode}" == "default" || "${debug_mode}" == "max" ]] ;;
        default) [[ "${debug_mode}" == "default" || "${debug_mode}" == "max" ]] ;;
        max)     [[ "${debug_mode}" == "max" ]] ;;
    esac
}

# "default" and "max" enable bash trace (set -x)
if debug_at_least "default"; then
    set -x
    echo "Debug mode '${debug_mode}' enabled (set -x active)."
elif debug_at_least "lite"; then
    echo "Debug mode 'lite' enabled (verbose logging, no trace)."
fi

# ---------------------------------------------------------------------------
# Maximum debug: exhaustive environment audit
# ---------------------------------------------------------------------------
if debug_at_least "max"; then
    echo ""
    echo "========================================"
    echo "  DEBUG MAX: Environment Audit"
    echo "========================================"

    # --- System ---
    echo ""
    echo "--- System ---"
    echo "  Hostname       : $(hostname 2>/dev/null || echo 'unknown')"
    echo "  Kernel         : $(uname -srm 2>/dev/null || echo 'unknown')"
    echo "  OS release     : $(cat /etc/os-release 2>/dev/null | grep -E '^(PRETTY_NAME|VERSION)=' | head -n 2 || sw_vers 2>/dev/null || echo 'unknown')"
    echo "  Uptime         : $(uptime 2>/dev/null || echo 'unknown')"
    echo "  Date/Time      : $(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null)"
    echo "  Timezone       : $(date '+%Z (%:z)' 2>/dev/null)"
    echo "  Locale         : ${LANG:-unset} (LC_ALL=${LC_ALL:-unset})"

    # --- User & permissions ---
    echo ""
    echo "--- User & Permissions ---"
    echo "  User           : $(whoami 2>/dev/null || id -un 2>/dev/null || echo 'unknown')"
    echo "  UID/GID        : $(id 2>/dev/null || echo 'unknown')"
    echo "  HOME           : ${HOME:-unset}"
    echo "  Shell          : ${SHELL:-unset}"
    echo "  Umask          : $(umask)"

    # --- CPU & memory ---
    echo ""
    echo "--- CPU & Memory ---"
    if [[ "${os}" == "linux" ]]; then
        echo "  CPU model      : $(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo 'unknown')"
        echo "  CPU cores      : $(nproc 2>/dev/null || echo 'unknown') logical"
        echo "  CPU frequency  : $(grep -m1 'cpu MHz' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo 'unknown') MHz"
        echo "  Architecture   : $(uname -m 2>/dev/null || echo 'unknown')"
        echo "  Memory total   : $(free -h 2>/dev/null | awk '/^Mem:/{print $2}' || echo 'unknown')"
        echo "  Memory free    : $(free -h 2>/dev/null | awk '/^Mem:/{print $4}' || echo 'unknown')"
        echo "  Memory avail   : $(free -h 2>/dev/null | awk '/^Mem:/{print $7}' || echo 'unknown')"
        echo "  Swap total     : $(free -h 2>/dev/null | awk '/^Swap:/{print $2}' || echo 'unknown')"
        echo "  Swap used      : $(free -h 2>/dev/null | awk '/^Swap:/{print $3}' || echo 'unknown')"
        echo "  Load average   : $(cat /proc/loadavg 2>/dev/null || echo 'unknown')"
    elif [[ "${os}" == "macos" ]]; then
        echo "  CPU model      : $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'unknown')"
        echo "  CPU cores      : $(sysctl -n hw.logicalcpu 2>/dev/null || echo 'unknown') logical, $(sysctl -n hw.physicalcpu 2>/dev/null || echo '?') physical"
        echo "  Architecture   : $(uname -m 2>/dev/null || echo 'unknown')"
        echo "  Memory total   : $(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 )) GB"
        echo "  Load average   : $(sysctl -n vm.loadavg 2>/dev/null || uptime | sed 's/.*load averages: //' || echo 'unknown')"
    fi

    # --- Disk / Filesystem ---
    echo ""
    echo "--- Disk & Filesystem ---"
    echo "  script_dir filesystem:"
    df -h "${script_dir}" 2>/dev/null | tail -n 1 | awk '{printf "    Device: %s  Size: %s  Used: %s  Avail: %s  Use%%: %s  Mount: %s\n", $1,$2,$3,$4,$5,$6}' || echo "    unknown"
    echo "  output_dir filesystem:"
    df -h "${output_dir}" 2>/dev/null | tail -n 1 | awk '{printf "    Device: %s  Size: %s  Used: %s  Avail: %s  Use%%: %s  Mount: %s\n", $1,$2,$3,$4,$5,$6}' || echo "    unknown"
    if [[ "${os}" == "linux" && -d /dev/shm ]]; then
        echo "  /dev/shm (RAM disk):"
        df -h /dev/shm 2>/dev/null | tail -n 1 | awk '{printf "    Size: %s  Used: %s  Avail: %s  Use%%: %s\n", $2,$3,$4,$5}' || echo "    unknown"
    fi
    echo "  Clips dir size : $(du -sh "${clips_dir}" 2>/dev/null | cut -f1 || echo 'unknown')"
    echo "  Output dir size: $(du -sh "${output_dir}" 2>/dev/null | cut -f1 || echo 'unknown')"

    # --- Directory permissions ---
    echo ""
    echo "--- Directory Permissions ---"
    echo "  clips_dir  : $(ls -ld "${clips_dir}" 2>/dev/null | awk '{print $1, $3, $4}' || echo 'unknown')"
    echo "  output_dir : $(ls -ld "${output_dir}" 2>/dev/null | awk '{print $1, $3, $4}' || echo 'unknown')"
    echo "  script_dir : $(ls -ld "${script_dir}" 2>/dev/null | awk '{print $1, $3, $4}' || echo 'unknown')"
    echo "  clips_dir writable  : $([[ -w "${clips_dir}" ]] && echo 'yes' || echo 'NO')"
    echo "  output_dir writable : $([[ -w "${output_dir}" ]] && echo 'yes' || echo 'NO')"

    # --- Bash ---
    echo ""
    echo "--- Bash ---"
    echo "  Bash version   : ${BASH_VERSION}"
    echo "  Bash path      : ${BASH}"
    echo "  BASH_SOURCE     : ${BASH_SOURCE[0]}"
    echo "  Bash options   : ${SHELLOPTS}"
    echo "  Bash flags     : $-"
    echo "  BASHPID        : ${BASHPID}"
    echo "  PID ($$)       : $$"
    echo "  PPID           : ${PPID}"

    # --- ffmpeg deep inspection ---
    echo ""
    echo "--- ffmpeg ---"
    echo "  Path           : $(command -v ffmpeg 2>/dev/null || echo 'not found')"
    echo "  Version        : $(ffmpeg -version 2>/dev/null | head -n 1 || echo 'unknown')"
    echo "  Build config   : $(ffmpeg -version 2>/dev/null | grep 'configuration:' | head -n 1 || echo 'unknown')"
    echo "  libavcodec     : $(ffmpeg -version 2>/dev/null | grep 'libavcodec' | head -n 1 || echo 'unknown')"
    echo "  libavformat    : $(ffmpeg -version 2>/dev/null | grep 'libavformat' | head -n 1 || echo 'unknown')"
    echo "  libswscale     : $(ffmpeg -version 2>/dev/null | grep 'libswscale' | head -n 1 || echo 'unknown')"
    echo "  HW accel APIs  : $(ffmpeg -hide_banner -hwaccels 2>/dev/null | tail -n +2 | tr '\n' ', ' || echo 'none')"
    echo "  AV1 encoders   : $(ffmpeg -hide_banner -encoders 2>/dev/null | grep -i 'av1' | awk '{print $2}' | tr '\n' ', ' || echo 'none')"
    echo "  HEVC encoders  : $(ffmpeg -hide_banner -encoders 2>/dev/null | grep -i 'hevc' | awk '{print $2}' | tr '\n' ', ' || echo 'none')"
    echo "  H264 encoders  : $(ffmpeg -hide_banner -encoders 2>/dev/null | grep -i 'h264\|x264' | awk '{print $2}' | tr '\n' ', ' || echo 'none')"
    echo "  MKV muxer      : $(ffmpeg -hide_banner -muxers 2>/dev/null | grep -i 'matroska' | awk '{print $2}' | tr '\n' ', ' || echo 'not found')"
    echo "  FLAC encoder   : $(ffmpeg -hide_banner -encoders 2>/dev/null | grep -i 'flac' | awk '{print $2}' | tr '\n' ', ' || echo 'not found')"
    echo "  Concat demuxer : $(ffmpeg -hide_banner -demuxers 2>/dev/null | grep -i 'concat' | awk '{print $2}' | tr '\n' ', ' || echo 'not found')"

    # --- ffprobe ---
    echo ""
    echo "--- ffprobe ---"
    echo "  Path           : $(command -v ffprobe 2>/dev/null || echo 'not found')"
    echo "  Version        : $(ffprobe -version 2>/dev/null | head -n 1 || echo 'unknown')"

    # --- GPU deep inspection ---
    echo ""
    echo "--- GPU ---"
    echo "  Detected vendor: ${gpu_vendor}"
    echo "  av1_gpu_opts   : ${av1_gpu_opts[*]:-<empty>}"
    if [[ "${os}" == "linux" ]]; then
        if command -v lspci &>/dev/null; then
            echo "  VGA controllers:"
            lspci 2>/dev/null | grep -iE 'VGA|3D|Display' | while IFS= read -r line; do
                echo "    ${line}"
            done
        fi
        if command -v nvidia-smi &>/dev/null; then
            echo "  nvidia-smi:"
            nvidia-smi --query-gpu=name,driver_version,memory.total,memory.free,temperature.gpu,utilization.gpu \
                --format=csv,noheader 2>/dev/null | while IFS= read -r line; do
                echo "    ${line}"
            done || echo "    nvidia-smi query failed"
        fi
        echo "  /dev/dri nodes : $(ls /dev/dri/ 2>/dev/null | tr '\n' ', ' || echo 'none')"
        if command -v vainfo &>/dev/null; then
            echo "  VAAPI profiles : $(vainfo 2>/dev/null | grep -c 'VAProfile' || echo '0') profiles detected"
        fi
        if command -v vulkaninfo &>/dev/null; then
            echo "  Vulkan device  : $(vulkaninfo --summary 2>/dev/null | grep 'deviceName' | head -n 1 | sed 's/.*= //' || echo 'unknown')"
        fi
    elif [[ "${os}" == "macos" ]]; then
        echo "  GPU info       : $(system_profiler SPDisplaysDataType 2>/dev/null | grep -E 'Chipset Model|VRAM|Metal' | sed 's/^  */    /' || echo 'unknown')"
    fi

    # --- Other tools ---
    echo ""
    echo "--- Tool Versions ---"
    echo "  curl           : $(curl --version 2>/dev/null | head -n 1 || echo 'not installed')"
    echo "  jq             : $(jq --version 2>/dev/null || echo 'not installed')"
    echo "  sort           : $(${SORT_CMD} --version 2>/dev/null | head -n 1 || echo 'unknown')"
    echo "  grep           : $(grep --version 2>/dev/null | head -n 1 || echo 'unknown')"
    echo "  sed            : $(sed --version 2>/dev/null | head -n 1 || echo 'unknown / BSD')"
    echo "  awk            : $(awk --version 2>/dev/null | head -n 1 || echo 'unknown / BSD')"
    echo "  timeout        : $(timeout --version 2>/dev/null | head -n 1 || echo 'available (no --version)' 2>/dev/null || echo 'not found')"
    echo "  find           : $(find --version 2>/dev/null | head -n 1 || echo 'unknown / BSD')"
    echo "  cat            : $(cat --version 2>/dev/null | head -n 1 || echo 'available')"
    echo "  tee            : $(tee --version 2>/dev/null | head -n 1 || echo 'available')"
    echo "  mktemp         : $(mktemp --version 2>/dev/null | head -n 1 || echo 'available')"
    echo "  getconf        : $(command -v getconf &>/dev/null && echo 'available' || echo 'not found')"
    echo "  lspci          : $(command -v lspci &>/dev/null && echo 'available' || echo 'not found')"
    echo "  nvidia-smi     : $(command -v nvidia-smi &>/dev/null && echo 'available' || echo 'not found')"

    # --- Network (relevant for Steam API calls) ---
    echo ""
    echo "--- Network ---"
    echo "  DNS resolves store.steampowered.com : $(host store.steampowered.com 2>/dev/null | head -n 1 || getent hosts store.steampowered.com 2>/dev/null | head -n 1 || echo 'unable to check')"
    echo "  curl reachability (store API)       : $(curl -s -o /dev/null -w '%{http_code}' --max-time 5 'https://store.steampowered.com/api/appdetails?appids=730' 2>/dev/null || echo 'failed')"
    echo "  curl reachability (steamdb)         : $(curl -s -o /dev/null -w '%{http_code}' --max-time 5 'https://steamdb.info/api/GetAppDetails/?appid=730' 2>/dev/null || echo 'failed')"
    echo "  curl reachability (app list)        : $(curl -s -o /dev/null -w '%{http_code}' --max-time 5 'https://api.steampowered.com/ISteamApps/GetAppList/v2/' 2>/dev/null || echo 'failed')"

    # --- Environment variables ---
    echo ""
    echo "--- Relevant Environment Variables ---"
    echo "  PATH           : ${PATH}"
    echo "  TMPDIR         : ${TMPDIR:-unset}"
    echo "  XDG_RUNTIME_DIR: ${XDG_RUNTIME_DIR:-unset}"
    echo "  LD_LIBRARY_PATH: ${LD_LIBRARY_PATH:-unset}"
    echo "  DISPLAY        : ${DISPLAY:-unset}"
    echo "  WAYLAND_DISPLAY: ${WAYLAND_DISPLAY:-unset}"
    echo "  LIBVA_DRIVER_NAME: ${LIBVA_DRIVER_NAME:-unset}"
    echo "  TERM           : ${TERM:-unset}"

    # --- Clip directory inventory ---
    echo ""
    echo "--- Clip Inventory ---"
    local clip_count
    clip_count="$(find "${clips_dir}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
    echo "  Clip directories: ${clip_count}"
    if [[ "${clip_count}" -gt 0 ]]; then
        find "${clips_dir}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | while IFS= read -r d; do
            local dname dsize chunk_count
            dname="$(basename "${d}")"
            dsize="$(du -sh "${d}" 2>/dev/null | cut -f1)"
            chunk_count="$(find "${d}" -name '*.m4s' 2>/dev/null | wc -l)"
            echo "    ${dname} (${dsize}, ${chunk_count} .m4s files)"
        done
    fi

    # --- Cache state ---
    echo ""
    echo "--- Cache State ---"
    echo "  Cache file     : ${steam_id_cache}"
    echo "  Cache entries  : $(wc -l < "${steam_id_cache}" 2>/dev/null || echo '0')"
    echo "  ERROR entries  : $(grep -cP '\tERROR\t' "${steam_id_cache}" 2>/dev/null || echo '0')"
    echo "  Cache size     : $(du -h "${steam_id_cache}" 2>/dev/null | cut -f1 || echo '0')"

    # --- Process limits ---
    echo ""
    echo "--- Process Limits ---"
    echo "  Max open files : $(ulimit -n 2>/dev/null || echo 'unknown')"
    echo "  Max user procs : $(ulimit -u 2>/dev/null || echo 'unknown')"
    echo "  Max file size  : $(ulimit -f 2>/dev/null || echo 'unknown')"
    echo "  Max stack size : $(ulimit -s 2>/dev/null || echo 'unknown')"

    echo ""
    echo "========================================"
    echo "  End of Environment Audit"
    echo "========================================"
    echo ""
fi

# ---------------------------------------------------------------------------
# Resolve encoder selection
# ---------------------------------------------------------------------------
encoder="${default_encoder}"

# Optionally prompt the user to choose an encoder
if [[ "${encoder_prompt}" == "true" ]]; then
    echo "Select encoder:"
    echo "  1) copy  — stream copy, no re-encode (fast)"
    echo "  2) av1   — re-encode with AV1 (smaller files, slower)"
    if [[ "${default_encoder}" == "av1" ]]; then
        read -r -p "Encoder [1/2] (default: 2): " encoder_input
    else
        read -r -p "Encoder [1/2] (default: 1): " encoder_input
    fi
    case "${encoder_input}" in
        1) encoder="copy" ;;
        2) encoder="av1"  ;;
        "") ;;  # keep default_encoder
        *)
            echo -e "${YELLOW}[WARN] Invalid choice '${encoder_input}', using default: ${default_encoder}${NC}"
            ;;
    esac
fi

encode_av1=false
[[ "${encoder}" == "av1" ]] && encode_av1=true

echo ""
echo "Configuration:"
echo "  Version       : ${script_version}"
echo "  OS            : ${os}"
echo "  Debug mode    : ${debug_mode}"
echo "  Latest log    : ${latest_log}"
echo "  Encoder       : ${encoder}"
echo "  GPU vendor    : ${gpu_vendor}"
echo "  Clips dir     : ${clips_dir}"
echo "  Output dir    : ${output_dir}"
echo ""
echo "Dependencies:"
echo "  ffmpeg        : installed ($(ffmpeg -version 2>/dev/null | head -n 1 | sed 's/ffmpeg version //' | cut -d' ' -f1))"
echo "  jq            : $(if [[ "${has_jq}" == "true" ]]; then echo "installed ($(jq --version 2>&1))"; else echo -e "${YELLOW}missing — using grep fallback for JSON parsing${NC}"; fi)"
echo "  curl          : $(if [[ "${has_curl}" == "true" ]]; then echo "installed"; else echo -e "${YELLOW}missing — game name resolution disabled${NC}"; fi)"
if [[ "${os}" == "macos" ]]; then
echo "  gsort         : installed"
fi
echo ""

# ===========================================================================
# SECTION 2: MAIN PROCESSING LOOP  (parallel, max CPU_threads − 2 jobs)
# ===========================================================================

# --- Determine parallelism limit ---
cpu_threads="$(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 4)"
if [[ "${encode_av1}" == "true" ]]; then
    if [[ "${gpu_vendor}" != "none" ]]; then
        # GPU AV1 encoders (AMF, NVENC, VAAPI, QSV) typically support only
        # one or two concurrent sessions. Serialise to avoid overloading.
        max_jobs=1
    else
        # CPU AV1 (libsvtav1) is extremely memory- and compute-intensive.
        # Cap at 2 concurrent encodes to avoid starving the system.
        max_jobs=$(( cpu_threads > 8 ? 2 : 1 ))
    fi
    echo "Parallelism: ${max_jobs} concurrent job(s) — AV1 encode mode (${cpu_threads} logical CPUs detected)"
else
    max_jobs=$(( cpu_threads > 2 ? cpu_threads - 2 : 1 ))
    echo "Parallelism: ${max_jobs} concurrent jobs (${cpu_threads} logical CPUs detected)"
fi

# --- Trap: kill all child processes when this script exits ---
# This ensures no runaway background jobs remain if the script is killed.
cleanup() {
    echo -e "\n${YELLOW}[CLEANUP] Caught exit signal — terminating all child processes...${NC}"
    # Kill the entire process group
    kill -- -$$  2>/dev/null || true
    wait
}
trap cleanup EXIT INT TERM

# --- Collect clip directories ---
# Each subdirectory in clips_dir represents one output video file.
mapfile -t clip_dirs < <(find "${clips_dir}" -mindepth 1 -maxdepth 1 -type d | "${SORT_CMD}" -V)

if [[ "${#clip_dirs[@]}" -eq 0 ]]; then
    echo -e "${YELLOW}[WARN] No clip directories found in: ${clips_dir}${NC}"
fi

# ---------------------------------------------------------------------------
# Check for existing output files and prompt the user once for all of them.
# Options:
#   1) Reconvert   — delete existing outputs and re-process those clips
#   2) Merge       — keep existing video, but update thumbnails & chapters
#   3) Skip        — leave existing outputs untouched, only process new clips
# ---------------------------------------------------------------------------
existing_outputs=()
existing_clip_dirs=()
new_clip_dirs=()

for cdir in "${clip_dirs[@]}"; do
    cname="$(basename "${cdir}")"

    # Extract the YYYYMMDD_HHMMSS timestamp from the clip directory name.
    # Clip dirs are named like: clip_<appid>_YYYYMMDD_HHMMSS
    # After the appid, the remaining two underscore-separated segments are the timestamp.
    clip_timestamp="$(echo "${cname}" | grep -oP '[0-9]{8}_[0-9]{6}$' || true)"

    found_existing=""
    if [[ -n "${clip_timestamp}" ]]; then
        # Search output_dir for any .mkv whose name contains this timestamp.
        # This matches regardless of renaming stage: clip_368340_20260319_150818.mkv,
        # 368340_20260319_150818.mkv, or Cross_Code_20260319_150818.mkv all match.
        for candidate in "${output_dir}"/*"${clip_timestamp}"*.mkv; do
            if [[ -f "${candidate}" ]]; then
                found_existing="${candidate}"
                break
            fi
        done
    fi

    # Fallback: also check the literal expected name (handles edge cases)
    if [[ -z "${found_existing}" ]]; then
        if [[ "${encode_av1}" == "true" ]]; then
            literal="${output_dir}/${cname}_av1.mkv"
        else
            literal="${output_dir}/${cname}.mkv"
        fi
        [[ -f "${literal}" ]] && found_existing="${literal}"
    fi

    if [[ -n "${found_existing}" ]]; then
        existing_outputs+=("${found_existing}")
        existing_clip_dirs+=("${cdir}")
    else
        new_clip_dirs+=("${cdir}")
    fi
done

# duplicate_action: "reconvert" | "merge" | "skip"
duplicate_action="skip"

if [[ "${#existing_outputs[@]}" -gt 0 ]]; then
    echo ""
    echo -e "${YELLOW}Found ${#existing_outputs[@]} clip(s) already present in output directory:${NC}"
    for eo in "${existing_outputs[@]}"; do
        echo "  - $(basename "${eo}")"
    done
    echo ""
    echo "How should these be handled?"
    echo "  1) Reconvert  — delete and re-encode from source clips"
    echo "  2) Merge      — keep video, update thumbnails & chapter markers"
    echo "  3) Skip       — leave as-is, only process new clips (default)"
    read -r -p "Choice [1/2/3] (default: 3): " dup_input
    case "${dup_input}" in
        1) duplicate_action="reconvert" ;;
        2) duplicate_action="merge"     ;;
        3) duplicate_action="skip"      ;;
        "") duplicate_action="skip"     ;;
        *)
            echo -e "${YELLOW}[WARN] Invalid choice '${dup_input}', defaulting to skip.${NC}"
            duplicate_action="skip"
            ;;
    esac
    echo "[DUPLICATES] Action: ${duplicate_action} (${#existing_outputs[@]} file(s))"

    case "${duplicate_action}" in
        reconvert)
            # Delete existing outputs so process_clip will recreate them
            for eo in "${existing_outputs[@]}"; do
                rm -f "${eo}"
                echo "[DELETE] $(basename "${eo}") — will reconvert"
            done
            # All clip dirs are processed
            clip_dirs=("${new_clip_dirs[@]}" "${existing_clip_dirs[@]}")
            ;;
        skip)
            # Only process clips that don't have existing output
            clip_dirs=("${new_clip_dirs[@]}")
            if [[ "${#clip_dirs[@]}" -eq 0 ]]; then
                echo "[INFO] All clips already processed — nothing new to encode."
            fi
            ;;
        merge)
            # Process new clips normally; existing ones get metadata-only update below
            clip_dirs=("${new_clip_dirs[@]}")
            ;;
    esac
else
    echo "[INFO] No existing output files found — processing all clips."
fi

# --- Job counter for concurrency control ---
job_count=0
declare -a job_pids=()
declare -a job_exit_codes=()

# ---------------------------------------------------------------------------
# resolve_clip_timing(): Derive clip timing from folder name timestamps.
#
# Steam's recording folder names encode wall-clock timestamps:
#   clip_<appid>_YYYYMMDD_HHMMSS   — when the clip was saved (= recording end)
#   fg_<appid>_YYYYMMDD_HHMMSS     — when the recording buffer started (= clip start)
#   timeline_<appid>YYYYMMDD_HHMMSS — when the game session began
#
# The timeline JSON markers use session-relative milliseconds (session start = 0).
# By parsing HHMMSS from the timeline, fg, and clip folder names and computing
# deltas in seconds × 1000 we get the clip's session-relative window.
#
# Usage:  resolve_clip_timing <clip_dir> <video_dir> <timelines_dir>
# Sets global variables:
#   ct_timeline_name   — timeline JSON filename (without .json extension)
#   ct_clip_start_ms   — session-relative start time (ms)
#   ct_clip_end_ms     — session-relative end time (ms)
#   ct_clip_duration_ms — clip duration (ms)
# Returns 0 on success, 1 if required folder names can't be parsed.
# ---------------------------------------------------------------------------
resolve_clip_timing() {
    local clip_dir="$1"
    local video_dir="$2"
    local timelines_dir="$3"

    ct_timeline_name=""
    ct_clip_start_ms=""
    ct_clip_end_ms=""
    ct_clip_duration_ms=""

    # --- Find timeline name from the timelines/ directory ---
    # Pick the first (or only) .json file; its name encodes the session start time.
    local timeline_file=""
    if [[ -d "${timelines_dir}" ]]; then
        timeline_file="$(find "${timelines_dir}" -maxdepth 1 -name '*.json' -type f 2>/dev/null | head -n 1)"
    fi
    if [[ -z "${timeline_file}" ]]; then
        echo "[WARN] No timeline JSON found in ${timelines_dir}"
        return 1
    fi

    # Extract timeline name (without .json) and its HHMMSS
    local tl_basename
    tl_basename="$(basename "${timeline_file}" .json)"
    ct_timeline_name="${tl_basename}"

    # Timeline name format: timeline_<appid>YYYYMMDD_HHMMSS
    local tl_hhmmss="${tl_basename##*_}"   # last segment after underscore
    if [[ ! "${tl_hhmmss}" =~ ^[0-9]{6}$ ]]; then
        echo "[WARN] Cannot parse HHMMSS from timeline: ${tl_basename}"
        return 1
    fi
    local tl_secs=$(( 10#${tl_hhmmss:0:2} * 3600 + 10#${tl_hhmmss:2:2} * 60 + 10#${tl_hhmmss:4:2} ))

    # --- Find fg folder name to get recording start HHMMSS ---
    local fg_dir=""
    fg_dir="$(find "${video_dir}" -mindepth 1 -maxdepth 1 -type d -name 'fg_*' 2>/dev/null | head -n 1)"
    if [[ -z "${fg_dir}" ]]; then
        echo "[WARN] No fg_* directory found in ${video_dir}"
        return 1
    fi
    local fg_basename
    fg_basename="$(basename "${fg_dir}")"

    # fg folder format: fg_<appid>_YYYYMMDD_HHMMSS
    local fg_hhmmss="${fg_basename##*_}"
    if [[ ! "${fg_hhmmss}" =~ ^[0-9]{6}$ ]]; then
        echo "[WARN] Cannot parse HHMMSS from fg folder: ${fg_basename}"
        return 1
    fi
    local fg_secs=$(( 10#${fg_hhmmss:0:2} * 3600 + 10#${fg_hhmmss:2:2} * 60 + 10#${fg_hhmmss:4:2} ))

    # --- Get clip save time HHMMSS from the clip directory name ---
    local clip_basename
    clip_basename="$(basename "${clip_dir}")"

    # Clip folder format: clip_<appid>_YYYYMMDD_HHMMSS
    local clip_hhmmss="${clip_basename##*_}"
    if [[ ! "${clip_hhmmss}" =~ ^[0-9]{6}$ ]]; then
        echo "[WARN] Cannot parse HHMMSS from clip folder: ${clip_basename}"
        return 1
    fi
    local clip_secs=$(( 10#${clip_hhmmss:0:2} * 3600 + 10#${clip_hhmmss:2:2} * 60 + 10#${clip_hhmmss:4:2} ))

    # --- Handle midnight wraparound ---
    # If fg or clip timestamp is earlier than timeline (crossed midnight),
    # add 24 hours to the later timestamp.
    if (( fg_secs < tl_secs )); then
        fg_secs=$(( fg_secs + 86400 ))
    fi
    if (( clip_secs < tl_secs )); then
        clip_secs=$(( clip_secs + 86400 ))
    fi

    # --- Compute session-relative times in milliseconds ---
    ct_clip_start_ms=$(( (fg_secs - tl_secs) * 1000 ))
    ct_clip_end_ms=$(( (clip_secs - tl_secs) * 1000 ))
    ct_clip_duration_ms=$(( ct_clip_end_ms - ct_clip_start_ms ))

    if (( ct_clip_duration_ms <= 0 )); then
        echo "[WARN] Computed non-positive duration for ${clip_basename}: start=${ct_clip_start_ms}ms end=${ct_clip_end_ms}ms"
        return 1
    fi

    if debug_at_least "lite"; then
        echo "[TIMING] ${clip_basename}: start=${ct_clip_start_ms}ms end=${ct_clip_end_ms}ms duration=${ct_clip_duration_ms}ms (timeline=${ct_timeline_name})"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# build_ffmetadata(): Convert Steam timeline JSON → ffmpeg metadata file
#                     with chapter markers, filtered and offset to the clip's
#                     recording window.
#
# Usage:  build_ffmetadata <timelines_dir> <output_metadata_file> \
#                          <clip_start_ms> <clip_end_ms> <clip_duration_ms> \
#                          [timeline_name]
#
# Steam timeline format:
#   { "entries": [ { "time": "27037", "type": "usermarker", ... }, ... ] }
#   - "time" is milliseconds from the START OF THE GAME SESSION (not the clip)
#   - The full session timeline is dumped into every clip's timelines/ folder
#
# This function:
#   1. Finds the matching timeline JSON (by timeline_name if given, else all)
#   2. Extracts all entries with a time field (usermarkers, achievements, game events)
#   3. Filters to only markers within [clip_start_ms, clip_end_ms]
#   4. Offsets each marker by −clip_start_ms so times are clip-relative
#   5. Writes ffmetadata format with TIMEBASE=1/1000
#
# Returns 0 if chapters were written, 1 if no markers matched.
# ---------------------------------------------------------------------------
build_ffmetadata() {
    local timelines_dir="$1"
    local metadata_file="$2"
    local clip_start_ms="$3"
    local clip_end_ms="$4"
    local clip_duration_ms="$5"
    local timeline_name="${6:-}"

    # Collect timeline JSON files
    local timeline_files=()
    if [[ -d "${timelines_dir}" ]]; then
        if [[ -n "${timeline_name}" && -f "${timelines_dir}/${timeline_name}.json" ]]; then
            # Prefer the exact timeline referenced in clip.pb
            timeline_files=("${timelines_dir}/${timeline_name}.json")
        else
            # Fallback: use all JSON files in the directory
            mapfile -t timeline_files < <(find "${timelines_dir}" -maxdepth 1 -name '*.json' -type f 2>/dev/null | "${SORT_CMD}" -V)
        fi
    fi

    if [[ "${#timeline_files[@]}" -eq 0 ]]; then
        return 1
    fi

    # Extract timestamps and titles from timeline entries.
    # Supported types (all entries with a "time" field are included):
    #   "usermarker"  — manual player marker, title = "Marker N" (numbered)
    #   "achievement" — Steam achievement, title = achievement_name field
    #   Game events   — custom game-pushed markers via AddTimelineEvent,
    #                   title from .title field, fallback to .type
    # Each entry is stored as "time<TAB>title" for paired sorting.
    local all_entries=()
    for tf in "${timeline_files[@]}"; do
        local entries_from_file=()
        if command -v jq &>/dev/null; then
            # jq: extract time and a display title for every entry that has a time field
            mapfile -t entries_from_file < <(
                jq -r '
                    .entries[]?
                    | select(.time != null)
                    | if .type == "usermarker" then
                        "\(.time)\tusermarker"
                      elif .type == "achievement" then
                        "\(.time)\t\(.achievement_name // "Achievement")"
                      elif (.title // "") != "" then
                        "\(.time)\t\(.title)"
                      else
                        "\(.time)\t\(.type // "Event")"
                      end
                ' "${tf}" 2>/dev/null || true
            )
        else
            # grep fallback: extract all "time" values; titles will be generic
            mapfile -t entries_from_file < <(
                grep -oP '"time"\s*:\s*"\K[0-9]+' "${tf}" 2>/dev/null \
                    | while read -r t; do echo "${t}"$'\t'"marker"; done || true
            )
        fi
        all_entries+=("${entries_from_file[@]}")
    done

    # Filter to clip window, offset timestamps, keep paired titles
    local filtered_entries=()
    for entry in "${all_entries[@]}"; do
        [[ -z "${entry}" ]] && continue
        local t="${entry%%$'\t'*}"
        local title="${entry#*$'\t'}"
        [[ -z "${t}" ]] && continue
        if (( t >= clip_start_ms && t <= clip_end_ms )); then
            filtered_entries+=("$(( t - clip_start_ms ))"$'\t'"${title}")
        fi
    done

    if [[ "${#filtered_entries[@]}" -eq 0 ]]; then
        return 1
    fi

    # Sort by timestamp, deduplicate by time (keep first title for each time)
    mapfile -t sorted_entries < <(printf '%s\n' "${filtered_entries[@]}" | sort -t$'\t' -k1,1 -un)

    # Filter out empty entries
    local clean_entries=()
    for se in "${sorted_entries[@]}"; do
        [[ -n "${se}" ]] && clean_entries+=("${se}")
    done
    sorted_entries=("${clean_entries[@]}")

    if [[ "${#sorted_entries[@]}" -eq 0 ]]; then
        return 1
    fi

    # Build the ffmetadata file
    {
        echo ";FFMETADATA1"
        echo ""

        local num_markers="${#sorted_entries[@]}"
        local i
        local marker_count=0   # counter for numbering generic "Marker N" titles

        # Extract just the timestamps for START/END calculations
        local -a times=()
        for se in "${sorted_entries[@]}"; do
            times+=("${se%%$'\t'*}")
        done

        # If the first marker is not at time 0, create an initial chapter
        if [[ "${times[0]}" -gt 0 ]]; then
            echo "[CHAPTER]"
            echo "TIMEBASE=1/1000"
            echo "START=0"
            echo "END=$(( times[0] - 1 ))"
            echo "title=Start"
            echo ""
        fi

        for (( i = 0; i < num_markers; i++ )); do
            local start_ms="${times[${i}]}"
            local raw_title="${sorted_entries[${i}]#*$'\t'}"
            local end_ms

            if (( i + 1 < num_markers )); then
                end_ms=$(( times[i + 1] - 1 ))
            elif [[ -n "${clip_duration_ms}" && "${clip_duration_ms}" -gt "${start_ms}" ]]; then
                end_ms="${clip_duration_ms}"
            else
                end_ms=$(( start_ms + 1000 ))
            fi

            # Determine display title
            local display_title
            if [[ "${raw_title}" == "usermarker" || "${raw_title}" == "marker" ]]; then
                marker_count=$(( marker_count + 1 ))
                display_title="Marker ${marker_count}"
            else
                display_title="${raw_title}"
            fi

            echo "[CHAPTER]"
            echo "TIMEBASE=1/1000"
            echo "START=${start_ms}"
            echo "END=${end_ms}"
            echo "title=${display_title}"
            echo ""
        done
    } > "${metadata_file}"

    echo "[CHAPTERS] Generated ${num_markers} chapter marker(s) (filtered from session timeline)"
    return 0
}

# ---------------------------------------------------------------------------
# process_clip(): Convert one clip directory → one output file.
# Called in a subshell for each clip (parallel).
# ---------------------------------------------------------------------------
process_clip() {
    local clip_dir="$1"
    local clip_name
    clip_name="$(basename "${clip_dir}")"

    # Each job writes errors to its own temp file keyed by PID
    local err_file="${script_dir}/temp_errors_${clip_name}_$$.txt"

    # -----------------------------------------------------------------------
    # Locate the video/ and timelines/ subdirectories
    # -----------------------------------------------------------------------
    local video_dir="${clip_dir}/video"
    local timelines_dir="${clip_dir}/timelines"

    if [[ ! -d "${video_dir}" ]]; then
        echo "[ERROR] Missing video/ directory in ${clip_dir}" >> "${err_file}"
        return 1
    fi

    # -----------------------------------------------------------------------
    # Find init segments (video stream 0, audio stream 1)
    # Chunks live inside fg_* subdirectories under video/, and there may be
    # multiple fg_* folders per clip that are all part of the same output.
    # Use a glob through fg_*/ (one level deep) instead of recursive find.
    # The init segment is identical across fg_* dirs; just take the first.
    # -----------------------------------------------------------------------
    local video_init audio_init
    video_init="$(printf '%s\n' "${video_dir}"/*/init-stream0.m4s "${video_dir}"/init-stream0.m4s 2>/dev/null | head -n 1)"
    audio_init="$(printf '%s\n' "${video_dir}"/*/init-stream1.m4s "${video_dir}"/init-stream1.m4s 2>/dev/null | head -n 1)"

    # If the glob didn't match anything, printf returns the literal pattern
    if [[ ! -f "${video_init}" || ! -f "${audio_init}" ]]; then
        echo "[ERROR] ${clip_name}: Missing init segment(s). video='${video_init}' audio='${audio_init}'" >> "${err_file}"
        return 1
    fi

    # -----------------------------------------------------------------------
    # Collect and natural-sort chunk files across all fg_* subdirectories.
    # Glob through both video/fg_*/ and video/ (in case chunks are directly
    # in video/ without an fg_* wrapper) then sort everything together.
    # -----------------------------------------------------------------------
    mapfile -t video_chunks < <(printf '%s\n' "${video_dir}"/*/chunk-stream0-*.m4s "${video_dir}"/chunk-stream0-*.m4s 2>/dev/null | grep -v '\*' | "${SORT_CMD}" -V)
    mapfile -t audio_chunks < <(printf '%s\n' "${video_dir}"/*/chunk-stream1-*.m4s "${video_dir}"/chunk-stream1-*.m4s 2>/dev/null | grep -v '\*' | "${SORT_CMD}" -V)

    if [[ "${#video_chunks[@]}" -eq 0 ]]; then
        echo "[ERROR] ${clip_name}: No video chunks found." >> "${err_file}"
        return 1
    fi
    if [[ "${#audio_chunks[@]}" -eq 0 ]]; then
        echo "[ERROR] ${clip_name}: No audio chunks found." >> "${err_file}"
        return 1
    fi

    echo "[INFO] ${clip_name}: ${#video_chunks[@]} video chunks, ${#audio_chunks[@]} audio chunks"

    # -----------------------------------------------------------------------
    # Choose a RAM-backed temp directory to avoid disk I/O bottlenecks.
    # Linux:  /dev/shm is a tmpfs mount (pure RAM).
    # macOS:  Use the system RAM disk path via getconf, fall back to /tmp.
    # If neither is writable with enough space, fall back to script_dir.
    # -----------------------------------------------------------------------
    local ram_tmp
    if [[ "${os}" == "linux" && -d /dev/shm && -w /dev/shm ]]; then
        ram_tmp="/dev/shm"
    elif [[ "${os}" == "macos" ]]; then
        # macOS does not expose /dev/shm; use the per-user RAM-backed temp dir
        local mac_tmp
        mac_tmp="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo "/tmp")"
        ram_tmp="${mac_tmp%/}"   # strip trailing slash
    else
        ram_tmp="${script_dir}"
    fi

    # -----------------------------------------------------------------------
    # Determine output file path & encode settings
    # -----------------------------------------------------------------------
    local output_file
    local encode_mode   # "copy" or "av1"
    if [[ "${encode_av1}" == "true" ]]; then
        output_file="${output_dir}/${clip_name}_av1.mkv"
        encode_mode="av1"
    else
        output_file="${output_dir}/${clip_name}.mkv"
        encode_mode="copy"
    fi

    # -----------------------------------------------------------------------
    # Resolve clip timing from folder name timestamps.
    # Steam encodes wall-clock HHMMSS in the timeline, fg_*, and clip_*
    # folder names. By computing deltas from the timeline (session start)
    # we get the clip's session-relative start/end window in milliseconds.
    # This is used to filter/offset timeline markers into correct chapters.
    # -----------------------------------------------------------------------
    local has_timing=false
    if resolve_clip_timing "${clip_dir}" "${video_dir}" "${timelines_dir}"; then
        has_timing=true
    fi

    # -----------------------------------------------------------------------
    # Build chapter metadata from timeline files (if timing was resolved).
    # Without timing we cannot determine the clip's session window, so
    # chapters are skipped rather than risk placing markers at wrong times.
    # -----------------------------------------------------------------------
    local metadata_file="${ram_tmp}/.tmp_ffmetadata_${clip_name}_$$.txt"
    local has_chapters=false

    if [[ "${has_timing}" == "true" && -d "${timelines_dir}" ]]; then
        if build_ffmetadata "${timelines_dir}" "${metadata_file}" \
                "${ct_clip_start_ms}" "${ct_clip_end_ms}" \
                "${ct_clip_duration_ms}" "${ct_timeline_name}"; then
            has_chapters=true
        else
            echo "[INFO] ${clip_name}: No chapter markers fall within this clip's time window"
        fi
    fi

    # -----------------------------------------------------------------------
    # Locate thumbnail image for MKV cover art attachment.
    # Steam stores a thumbnail at video/thumbnail (JPEG, no extension).
    # ffmpeg can attach it as an MKV attachment with mimetype image/jpeg,
    # which players like VLC and mpv display as cover art.
    # -----------------------------------------------------------------------
    local thumbnail="${video_dir}/thumbnail"
    local has_thumbnail=false
    local thumbnail_opts=()
    if [[ -f "${thumbnail}" ]]; then
        has_thumbnail=true
        echo "[THUMB] ${clip_name}: Embedding thumbnail as cover art"
    fi

    # -----------------------------------------------------------------------
    # Build encode_opts based on mode and GPU availability.
    # For -c copy: no transcoding occurs so GPU acceleration is irrelevant;
    #   we use bash process substitution to pipe concat streams directly into
    #   ffmpeg without writing any temp file at all.
    # For AV1: write concatenated streams to RAM temp files, then encode.
    #   GPU path uses av1_gpu_opts (set by detect_gpu); CPU path uses libsvtav1.
    #
    # Input index tracking for ffmpeg -map_metadata and -map:
    #   Process substitution / concat demuxer mode:
    #     Input 0: video stream
    #     Input 1: audio stream
    #     Next input index depends on which optional inputs are added:
    #       +1 for metadata file (if has_chapters)
    #       Thumbnail is added via -attach, not as a numbered input.
    # -----------------------------------------------------------------------
    local ffmpeg_log="${ram_tmp}/.tmp_ffmpeg_${clip_name}_$$.log"
    local ffmpeg_exit=0

    # Build the optional ffmpeg args for metadata and thumbnail.
    # These are appended to every ffmpeg invocation below.
    local extra_input_opts=()    # args BEFORE output file (additional -i flags)
    local extra_output_opts=()   # args BEFORE output file (mapping, attachment)
    local metadata_input_idx=""

    if [[ "${has_chapters}" == "true" ]]; then
        # -f ffmetadata tells ffmpeg to parse the file as an ffmetadata stream
        # (chapter definitions, global tags, etc.). -map_metadata copies all
        # metadata — including chapters — from the metadata input into the
        # output container.
        extra_input_opts+=(-f ffmetadata -i "${metadata_file}")
        metadata_input_idx=2   # video=0, audio=1, metadata=2
        extra_output_opts+=(-map_metadata "${metadata_input_idx}")
    fi

    if [[ "${has_thumbnail}" == "true" ]]; then
        extra_output_opts+=(-attach "${thumbnail}" -metadata:s:t mimetype=image/jpeg -metadata:s:t filename=cover.jpg)
    fi

    if [[ "${encode_mode}" == "copy" ]]; then
        # -c copy: pure stream remux — no decode/encode work.
        # Pipe init+chunks directly into ffmpeg via process substitution.
        timeout 600 ffmpeg \
            -v error \
            -i <(cat "${video_init}" "${video_chunks[@]}") \
            -i <(cat "${audio_init}" "${audio_chunks[@]}") \
            "${extra_input_opts[@]}" \
            -map 0:v:0 \
            -map 1:a:0 \
            "${extra_output_opts[@]}" \
            -c copy \
            -y \
            "${output_file}" \
            2>"${ffmpeg_log}"
        ffmpeg_exit=$?

    else
        # AV1 encode: ffmpeg needs seekable input for GPU upload and
        # multi-pass analysis. Concatenate init+chunks into single temp
        # files in RAM, then feed them as regular inputs.
        # (The concat demuxer cannot handle fragmented .m4s chunks because
        # each chunk lacks the moov/tfhd headers needed to parse standalone.)
        local tmp_video="${ram_tmp}/.tmp_video_${clip_name}_$$.mp4"
        local tmp_audio="${ram_tmp}/.tmp_audio_${clip_name}_$$.mp4"

        cat "${video_init}" "${video_chunks[@]}" > "${tmp_video}"
        cat "${audio_init}" "${audio_chunks[@]}" > "${tmp_audio}"

        # Select GPU or CPU encoder
        local encode_opts_arr
        if [[ "${gpu_vendor}" != "none" && "${#av1_gpu_opts[@]}" -gt 0 ]]; then
            encode_opts_arr=("${av1_gpu_opts[@]}")
            echo "[ENCODE] ${clip_name}: using GPU (${gpu_vendor}) AV1"
        else
            # CPU fallback: libsvtav1 preset 13 = fastest, crf 0 = lossless
            encode_opts_arr=(-c:v libsvtav1 -preset 13 -crf 0 -c:a flac -compression_level 12)
            echo "[ENCODE] ${clip_name}: using CPU libsvtav1"
        fi

        # First attempt
        timeout 600 ffmpeg \
            -v error \
            -i "${tmp_video}" \
            -i "${tmp_audio}" \
            "${extra_input_opts[@]}" \
            -map 0:v:0 \
            -map 1:a:0 \
            "${extra_output_opts[@]}" \
            "${encode_opts_arr[@]}" \
            -y \
            "${output_file}" \
            2>"${ffmpeg_log}"
        ffmpeg_exit=$?

        # If GPU encode failed, retry with CPU libsvtav1
        if [[ "${ffmpeg_exit}" -ne 0 && "${gpu_vendor}" != "none" ]]; then
            echo -e "${YELLOW}[WARN] ${clip_name}: GPU encode failed (exit ${ffmpeg_exit}), retrying with CPU...${NC}"
            timeout 600 ffmpeg \
                -v error \
                -i "${tmp_video}" \
                -i "${tmp_audio}" \
                "${extra_input_opts[@]}" \
                -map 0:v:0 \
                -map 1:a:0 \
                "${extra_output_opts[@]}" \
                -c:v libsvtav1 -preset 13 -crf 0 -c:a flac -compression_level 12 \
                -y \
                "${output_file}" \
                2>"${ffmpeg_log}"
            ffmpeg_exit=$?
        fi

        rm -f "${tmp_video}" "${tmp_audio}"
    fi

    # -----------------------------------------------------------------------
    # Check for ffmpeg errors or timeout
    # -----------------------------------------------------------------------
    if [[ "${ffmpeg_exit}" -eq 124 ]]; then
        echo "[ERROR] ${clip_name}: ffmpeg timed out after 10 minutes." >> "${err_file}"
    elif [[ "${ffmpeg_exit}" -ne 0 ]]; then
        echo "[ERROR] ${clip_name}: ffmpeg exited with code ${ffmpeg_exit}." >> "${err_file}"
        # Append ffmpeg's own error output for context
        cat "${ffmpeg_log}" >> "${err_file}"
    fi

    # -----------------------------------------------------------------------
    # Probe the output file for stream integrity (header/container only).
    # Uses ffprobe instead of a full decode pass (ffmpeg -f null -) to avoid
    # re-reading the entire file. This catches container corruption, missing
    # streams, and metadata issues without the cost of full decode.
    # Warnings are written to the dedicated ffprobe_errors file (not the
    # per-job temp log) so they are preserved in one place after the run.
    # -----------------------------------------------------------------------
    if [[ -f "${output_file}" ]]; then
        local probe_log="${script_dir}/.tmp_probe_${clip_name}_$$.log"
        ffprobe -v error -show_entries stream=codec_type,codec_name,duration \
            -of default=noprint_wrappers=1 \
            "${output_file}" 2>"${probe_log}" >/dev/null
        local probe_exit=$?
        if [[ "${probe_exit}" -ne 0 ]] || [[ -s "${probe_log}" ]]; then
            # Append a labelled block to errors.txt so every clip's issues
            # are clearly separated and traceable by filename.
            {
                echo "--- [$(date '+%Y-%m-%d %H:%M:%S')] ffprobe: ${clip_name} ---"
                cat "${probe_log}"
                echo ""
            } >> "${ffprobe_errors}"
        fi
        rm -f "${probe_log}"
    fi

    # -----------------------------------------------------------------------
    # Cleanup remaining temp files for this job
    # -----------------------------------------------------------------------
    rm -f "${ffmpeg_log}"
    rm -f "${metadata_file}"

    return "${ffmpeg_exit}"
}

# ---------------------------------------------------------------------------
# Dispatch clip processing jobs with concurrency control
# ---------------------------------------------------------------------------
for clip_dir in "${clip_dirs[@]}"; do
    # Wait if we've hit the max concurrent job limit
    while [[ "${job_count}" -ge "${max_jobs}" ]]; do
        # Wait for any one job to finish before spawning a new one
        wait -n 2>/dev/null || wait   # 'wait -n' is bash 4.3+; fall back to 'wait'
        job_count=$(( job_count - 1 ))
    done

    echo "[START] Processing: $(basename "${clip_dir}")"
    # Run in subshell background; capture PID
    (
        process_clip "${clip_dir}"
    ) &
    job_pids+=($!)
    job_count=$(( job_count + 1 ))
done

# Wait for all remaining jobs to finish
echo "Waiting for all encoding jobs to complete..."
for pid in "${job_pids[@]}"; do
    wait "${pid}"
    job_exit_codes+=($?)
done
echo "All encoding jobs finished."

# ---------------------------------------------------------------------------
# Merge pass: update thumbnails & chapter markers on existing output files
# (only runs when the user chose "merge" for duplicate handling)
# ---------------------------------------------------------------------------
if [[ "${duplicate_action}" == "merge" && "${#existing_clip_dirs[@]}" -gt 0 ]]; then
    echo ""
    echo "=== Merge: Updating thumbnails & chapters on ${#existing_clip_dirs[@]} existing file(s) ==="

    for (( _mi = 0; _mi < ${#existing_clip_dirs[@]}; _mi++ )); do
        cdir="${existing_clip_dirs[${_mi}]}"
        target="${existing_outputs[${_mi}]}"
        cname="$(basename "${cdir}")"

        [[ -f "${target}" ]] || continue
        echo "[MERGE] $(basename "${target}")"

        local_video_dir="${cdir}/video"
        local_timelines_dir="${cdir}/timelines"

        # --- Resolve timing and build chapter metadata ---
        merge_metadata=""
        merge_has_chapters=false
        if [[ -d "${local_timelines_dir}" ]]; then
            if resolve_clip_timing "${cdir}" "${local_video_dir}" "${local_timelines_dir}"; then
                merge_meta_file="${script_dir}/.tmp_merge_meta_${cname}_$$.txt"
                if build_ffmetadata "${local_timelines_dir}" "${merge_meta_file}" \
                        "${ct_clip_start_ms}" "${ct_clip_end_ms}" \
                        "${ct_clip_duration_ms}" "${ct_timeline_name}"; then
                    merge_has_chapters=true
                    merge_metadata="${merge_meta_file}"
                fi
            fi
        fi

        # --- Check for thumbnail ---
        merge_thumbnail="${local_video_dir}/thumbnail"
        merge_has_thumbnail=false
        [[ -f "${merge_thumbnail}" ]] && merge_has_thumbnail=true

        # If there's nothing to merge, skip
        if [[ "${merge_has_chapters}" == "false" && "${merge_has_thumbnail}" == "false" ]]; then
            echo "[MERGE] $(basename "${target}"): No new chapters or thumbnail to merge — skipping"
            rm -f "${merge_metadata}"
            continue
        fi

        # --- Re-mux: copy all streams, apply new metadata/thumbnail ---
        merge_tmp="${target}.merge_tmp_$$.mkv"
        merge_log="${script_dir}/.tmp_merge_ffmpeg_${cname}_$$.log"
        merge_input_opts=()
        merge_output_opts=()

        # Map only video and audio streams from the original file (input 0).
        # Using -map 0 would also copy existing attachments, which conflicts
        # with -attach when re-adding a thumbnail.
        merge_map_opts=(-map 0:v -map 0:a)

        # Input 0 is the existing file
        if [[ "${merge_has_chapters}" == "true" ]]; then
            merge_input_opts+=(-f ffmetadata -i "${merge_metadata}")
            # metadata input index = 1 (existing file = 0, metadata = 1)
            merge_output_opts+=(-map_metadata 1)
        fi

        if [[ "${merge_has_thumbnail}" == "true" ]]; then
            merge_output_opts+=(-attach "${merge_thumbnail}" -metadata:s:t mimetype=image/jpeg -metadata:s:t filename=cover.jpg)
        fi

        if timeout 120 ffmpeg \
                -nostdin \
                -v error \
                -i "${target}" \
                "${merge_input_opts[@]}" \
                "${merge_map_opts[@]}" \
                "${merge_output_opts[@]}" \
                -c copy \
                -y \
                "${merge_tmp}" 2>"${merge_log}"; then
            mv "${merge_tmp}" "${target}"
            echo "[MERGE] $(basename "${target}"): Updated successfully"
        else
            echo -e "${YELLOW}[WARN] $(basename "${target}"): Merge failed (exit $?) — original file unchanged${NC}"
            if [[ -s "${merge_log}" ]]; then
                echo -e "${YELLOW}$(cat "${merge_log}")${NC}"
            fi
            rm -f "${merge_tmp}"
        fi
        rm -f "${merge_metadata}" "${merge_log}"
    done
fi

# ===========================================================================
# SECTION 3: ADD GAME NAMES TO OUTPUT FILES AND SORT
# ===========================================================================

echo ""
echo "=== Step 3: Renaming output files with game names ==="

# ---------------------------------------------------------------------------
# 3a. Strip "clip_" or "fg_" prefixes from all files in output_dir
# ---------------------------------------------------------------------------
for f in "${output_dir}"/*; do
    [[ -f "${f}" ]] || continue
    base="$(basename "${f}")"
    dir="$(dirname "${f}")"
    # Remove leading "clip_" or "fg_" prefix (case-sensitive)
    new_base="${base#clip_}"
    new_base="${new_base#fg_}"
    if [[ "${new_base}" != "${base}" ]]; then
        mv "${f}" "${dir}/${new_base}"
        echo "[RENAME] ${base} → ${new_base}"
    fi
done

# ---------------------------------------------------------------------------
# 3b-pre. Remove garbage files with duplicated extensions (.mkv.mkv, etc.)
# These can accumulate from previous failed runs. Delete them before we scan
# so they are never picked up by the SteamID map or rename loop.
# ---------------------------------------------------------------------------
for f in "${output_dir}"/*; do
    [[ -f "${f}" ]] || continue
    base="$(basename "${f}")"
    # Detect filenames with more than one dot-separated extension that is
    # identical to the last extension, e.g. "foo.mkv.mkv" or "foo.mkv.mkv.mkv"
    ext="${base##*.}"                 # e.g. "mkv"
    stripped="${base%.*}"             # e.g. "foo.mkv"
    if [[ "${stripped##*.}" == "${ext}" ]]; then
        echo "[CLEANUP] Removing garbage duplicate-extension file: ${base}"
        rm -f "${f}"
    fi
done

# ---------------------------------------------------------------------------
# 3b. Extract SteamIDs from filenames.
# Convention: first numeric segment before the first "_" is the SteamID.
# e.g.  730_20240101_some_clip.mkv  →  SteamID = 730
# ---------------------------------------------------------------------------
declare -A steam_id_to_files   # map: steam_id → newline-separated list of files

for f in "${output_dir}"/*; do
    [[ -f "${f}" ]] || continue
    base="$(basename "${f}")"
    # Extract leading numeric segment
    steam_id="$(echo "${base}" | grep -oE '^[0-9]+' || true)"
    [[ -z "${steam_id}" ]] && continue
    # Append this file to the map entry for that ID
    steam_id_to_files["${steam_id}"]="${steam_id_to_files[${steam_id}]+${steam_id_to_files[${steam_id}]}$'\n'}${f}"
done

# ---------------------------------------------------------------------------
# 3c. Process each unique SteamID (sequentially — single thread for cache
#     access and rate-limit safety)
# ---------------------------------------------------------------------------

# Lock file for exclusive access to steam_id_cache
cache_lock="${steam_id_cache}.lock"

# Rate-limit: minimum seconds between external API calls
rate_limit_sec=1

# ---------------------------------------------------------------------------
# Helper functions for SteamID resolution
# ---------------------------------------------------------------------------

# Helper: acquire exclusive lock (busy-wait with short sleep)
acquire_lock() {
    while ! mkdir "${cache_lock}" 2>/dev/null; do
        sleep 0.1
    done
}

# Helper: release lock
release_lock() {
    rmdir "${cache_lock}" 2>/dev/null || true
}

# Helper: look up a SteamID in the local cache.
# Returns the game name if found and source != ERROR, empty string otherwise.
# ERROR entries are treated as misses so they get retried every run.
lookup_cache() {
    local id="$1"
    local line source
    line="$(grep -P "^${id}\t" "${steam_id_cache}" | head -n 1 || true)"
    if [[ -n "${line}" ]]; then
        # TSV: id <tab> name <tab> source <tab> date
        source="$(echo "${line}" | cut -f3)"
        if [[ "${source}" == "ERROR" ]]; then
            echo ""
        else
            echo "${line}" | cut -f2
        fi
    else
        echo ""
    fi
}

# Helper: query the Steam Store API for a single app ID.
# Response JSON: {"<id>":{"success":true,"data":{"name":"Game Name",...}}}
# Sets global variables: fetched_name, fetched_source
fetch_from_steam_store() {
    local id="$1"
    fetched_name=""
    fetched_source=""

    local store_response
    store_response="$(curl -s --max-time 30 \
        "https://store.steampowered.com/api/appdetails?appids=${id}" || true)"

    if [[ -n "${store_response}" ]]; then
        if command -v jq &>/dev/null; then
            fetched_name="$(echo "${store_response}" | jq -r ".[\"${id}\"].data.name // empty" 2>/dev/null || true)"
        else
            fetched_name="$(echo "${store_response}" | grep -oP '"name"\s*:\s*"\K[^"]+' | head -n 1 || true)"
        fi
        if [[ -n "${fetched_name}" && "${fetched_name}" != "null" ]]; then
            fetched_source="steamstore"
            return 0
        fi
    fi
    return 1
}

# Helper: query the SteamDB API for a single app ID.
# Response JSON: {"data":{"name":"Game Name",...},...}
# Sets global variables: fetched_name, fetched_source
fetch_from_steamdb() {
    local id="$1"
    fetched_name=""
    fetched_source=""

    local steamdb_response
    steamdb_response="$(curl -s --max-time 30 \
        "https://steamdb.info/api/GetAppDetails/?appid=${id}" || true)"

    if [[ -n "${steamdb_response}" ]]; then
        if command -v jq &>/dev/null; then
            fetched_name="$(echo "${steamdb_response}" | jq -r '.data.name // empty' 2>/dev/null || true)"
        else
            fetched_name="$(echo "${steamdb_response}" | grep -oP '"name"\s*:\s*"\K[^"]+' | head -n 1 || true)"
        fi
        if [[ -n "${fetched_name}" && "${fetched_name}" != "null" ]]; then
            fetched_source="steamdb"
            return 0
        fi
    fi
    return 1
}

# Sanitise a game name so it's safe as a filename component.
# Keeps: letters, digits, hyphen, underscore, period, apostrophe, comma,
#        ampersand, parentheses, and exclamation mark (normal writing chars).
# Everything else (spaces, slashes, colons, emoji, control chars, etc.) → '_'
# Then collapse runs of underscores and trim leading/trailing underscores.
sanitise_name() {
    echo "$1" \
        | sed "s/[^a-zA-Z0-9_.,'&!()-]/_/g" \
        | tr -s '_' \
        | sed 's/^_//; s/_$//'
}

# ---------------------------------------------------------------------------
# Helper: write a resolved name to the cache (replaces any prior entry)
# ---------------------------------------------------------------------------
write_cache() {
    local id="$1" name="$2" source="$3"
    local entry_date
    entry_date="$(date '+%Y-%m-%d')"
    acquire_lock
    local tmp="${steam_id_cache}.tmp.$$"
    grep -vP "^${id}\t" "${steam_id_cache}" > "${tmp}" || true
    mv "${tmp}" "${steam_id_cache}"
    printf '%s\t%s\t%s\t%s\n' "${id}" "${name}" "${source}" "${entry_date}" \
        >> "${steam_id_cache}"
    release_lock
}

# ---------------------------------------------------------------------------
# 3c-i. First pass: try Steam Store API → SteamDB for each cache miss.
# IDs that still fail are collected for the bulk app-list fallback.
# ---------------------------------------------------------------------------
steam_list_cache="${script_dir}/.steam_app_list_cache.json"
declare -A resolved_names   # map: steam_id → game_name (resolved this run)
ids_still_unresolved=()     # IDs that need the bulk fallback

for steam_id in "${!steam_id_to_files[@]}"; do
    echo "[STEAM] Processing ID: ${steam_id}"

    game_name=""

    # --- Check cache first ---
    acquire_lock
    game_name="$(lookup_cache "${steam_id}")"
    release_lock

    if [[ -n "${game_name}" ]]; then
        echo "[CACHE HIT] ${steam_id} → ${game_name}"
        resolved_names["${steam_id}"]="${game_name}"
        continue
    fi

    echo "[CACHE MISS] ${steam_id} — querying APIs..."
    sleep "${rate_limit_sec}"

    # Try Steam Store API first
    if fetch_from_steam_store "${steam_id}"; then
        game_name="${fetched_name}"
        echo "[FETCH] ${steam_id} → ${game_name} (via ${fetched_source})"
        write_cache "${steam_id}" "${game_name}" "${fetched_source}"
        resolved_names["${steam_id}"]="${game_name}"
        continue
    fi

    sleep "${rate_limit_sec}"

    # Try SteamDB second
    if fetch_from_steamdb "${steam_id}"; then
        game_name="${fetched_name}"
        echo "[FETCH] ${steam_id} → ${game_name} (via ${fetched_source})"
        write_cache "${steam_id}" "${game_name}" "${fetched_source}"
        resolved_names["${steam_id}"]="${game_name}"
        continue
    fi

    echo "[MISS] ${steam_id} — both APIs failed, deferring to bulk fallback"
    ids_still_unresolved+=("${steam_id}")
done

# ---------------------------------------------------------------------------
# 3c-ii. Bulk fallback: download the full Steam app list ONLY if there are
# unresolved IDs remaining. Downloaded at most once per run.
# ---------------------------------------------------------------------------
if [[ "${#ids_still_unresolved[@]}" -gt 0 ]]; then
    echo "[FALLBACK] ${#ids_still_unresolved[@]} ID(s) unresolved — downloading Steam app list..."

    # Download the app list (always fresh — not cached across runs)
    curl -s --max-time 60 \
        "https://api.steampowered.com/ISteamApps/GetAppList/v2/" \
        -o "${steam_list_cache}" || true

    if [[ -f "${steam_list_cache}" ]]; then
        declare -A bulk_names

        if command -v jq &>/dev/null; then
            # Single jq pass for all unresolved IDs
            jq_id_array="$(printf '%s\n' "${ids_still_unresolved[@]}" | jq -R 'tonumber' | jq -s '.')"

            while IFS=$'\t' read -r resolved_id resolved_name; do
                [[ -n "${resolved_id}" && -n "${resolved_name}" ]] || continue
                bulk_names["${resolved_id}"]="${resolved_name}"
            done < <(
                jq -r --argjson ids "${jq_id_array}" \
                    '[.applist.apps[] | select(.appid as $a | $ids | index($a))] | .[] | "\(.appid)\t\(.name)"' \
                    "${steam_list_cache}" 2>/dev/null || true
            )
        else
            # grep fallback when jq is absent
            for sid in "${ids_still_unresolved[@]}"; do
                resolved="$(grep -oP '"appid":\s*'"${sid}"'\s*,\s*"name":\s*"\K[^"]+' \
                    "${steam_list_cache}" | head -n 1 || true)"
                if [[ -n "${resolved}" ]]; then
                    bulk_names["${sid}"]="${resolved}"
                fi
            done
        fi

        echo "[FALLBACK] Resolved ${#bulk_names[@]} name(s) from Steam app list"

        # Write resolved names to cache and resolved_names map
        for sid in "${ids_still_unresolved[@]}"; do
            if [[ -n "${bulk_names[${sid}]+_}" && -n "${bulk_names[${sid}]}" ]]; then
                echo "[FALLBACK] ${sid} → ${bulk_names[${sid}]}"
                write_cache "${sid}" "${bulk_names[${sid}]}" "steamapi"
                resolved_names["${sid}"]="${bulk_names[${sid}]}"
            else
                echo -e "${YELLOW}[WARN] Could not resolve SteamID: ${sid} (all sources exhausted)${NC}"
                write_cache "${sid}" "ERROR" "ERROR"
            fi
        done

        # Clean up the bulk download — not cached across runs
        rm -f "${steam_list_cache}"
    else
        echo -e "${YELLOW}[WARN] Failed to download Steam app list${NC}"
        # Mark all remaining IDs as errors
        for sid in "${ids_still_unresolved[@]}"; do
            echo -e "${YELLOW}[WARN] Could not resolve SteamID: ${sid}${NC}"
            write_cache "${sid}" "ERROR" "ERROR"
        done
    fi
fi

# ---------------------------------------------------------------------------
# 3c-iii. Rename files using resolved names
# ---------------------------------------------------------------------------
for steam_id in "${!steam_id_to_files[@]}"; do
    game_name="${resolved_names[${steam_id}]:-}"

    if [[ -z "${game_name}" ]]; then
        echo "[SKIP RENAME] No game name resolved for ${steam_id} — filenames unchanged"
        continue
    fi
    safe_name="$(sanitise_name "${game_name}")"
    while IFS= read -r filepath; do
        [[ -z "${filepath}" ]] && continue
        [[ -f "${filepath}" ]] || continue
        dir="$(dirname "${filepath}")"
        base="$(basename "${filepath}")"
        ext="${base##*.}"           # extension only, e.g. "mkv"
        base_noext="${base%.*}"     # filename without extension, e.g. "206440_20260321_143021"
        # Only act on files whose name still starts with the raw numeric SteamID
        if [[ "${base_noext}" =~ ^[0-9]+ ]]; then
            # Strip the SteamID prefix, prepend the game name
            remainder="${base_noext#${steam_id}}"   # e.g. "_20260321_143021"
            new_base="${safe_name}${remainder}"      # e.g. "Tribes_Ascend_20260321_143021"
            # Collapse any accidental double underscores and trim edge underscores
            new_base="$(echo "${new_base}" | sed 's/__*/_/g; s/^_//; s/_$//')"
            new_base="${new_base}.${ext}"            # re-append extension exactly once
            if [[ "${base}" != "${new_base}" ]]; then
                mv "${filepath}" "${dir}/${new_base}"
                if debug_at_least "lite"; then
                    echo "[RENAMED] ${base} → ${new_base}"
                fi
            fi
        fi
    done <<< "${steam_id_to_files[${steam_id}]}"
done

# ---------------------------------------------------------------------------
# 3d. Sort steam_id_cache:
#   1. Normal entries       — sorted by source then game name
#   2. Demo / playtest      — sorted the same, after a blank line
#   3. ERROR entries        — sorted by ID, after another blank line
# ---------------------------------------------------------------------------
if [[ -s "${steam_id_cache}" ]]; then
    echo "[CACHE] Sorting ${steam_id_cache}..."

    tmp_normal="${steam_id_cache}.normal.$$"
    tmp_demo="${steam_id_cache}.demo.$$"
    tmp_error="${steam_id_cache}.error.$$"

    # Bucket 3: ERROR source lines (source field == "ERROR")
    grep -P "\tERROR\t" "${steam_id_cache}" \
        | "${SORT_CMD}" -t$'\t' -k1,1 \
        > "${tmp_error}" || true

    # Bucket 2: demo/playtest lines that are NOT errors
    grep -ivP "\tERROR\t" "${steam_id_cache}" \
        | grep -iP '\bdemo\b|\bplaytest\b' \
        | "${SORT_CMD}" -t$'\t' -k3,3 -k2,2 \
        > "${tmp_demo}" || true

    # Bucket 1: everything else (normal, resolved, non-demo)
    grep -ivP "\tERROR\t" "${steam_id_cache}" \
        | grep -ivP '\bdemo\b|\bplaytest\b' \
        | "${SORT_CMD}" -t$'\t' -k3,3 -k2,2 \
        > "${tmp_normal}" || true

    # Reassemble: normal → [blank] demo → [blank] errors
    {
        cat "${tmp_normal}"
        if [[ -s "${tmp_demo}" ]]; then
            echo ""
            cat "${tmp_demo}"
        fi
        if [[ -s "${tmp_error}" ]]; then
            echo ""
            cat "${tmp_error}"
        fi
    } > "${steam_id_cache}.new.$$"

    mv "${steam_id_cache}.new.$$" "${steam_id_cache}"
    rm -f "${tmp_normal}" "${tmp_demo}" "${tmp_error}"
    echo "[CACHE] Sort complete."
fi

# ===========================================================================
# SECTION 4: SANITIZATION  (delete files and directories)
# ===========================================================================

echo ""
echo "=== Step 4: Sanitization ==="

# Delete individual files (non-recursive)
for f in "${files_to_delete[@]}"; do
    if [[ -f "${f}" ]]; then
        rm -f "${f}"
        echo "[DELETE] ${f}"
    fi
done

# Delete directories (recursive)
for d in "${files_to_delete_recursive[@]}"; do
    if [[ -d "${d}" ]]; then
        rm -rf "${d}"
        echo "[DELETE RECURSIVE] ${d}"
    fi
done

# ===========================================================================
# SECTION 5: EXIT — Merge errors, report, and finish
# ===========================================================================

echo ""
echo "=== Step 5: Finalizing ==="

# ---------------------------------------------------------------------------
# Merge all per-job temp error files into the main temp_errors file
# ---------------------------------------------------------------------------
shopt -s nullglob   # glob expands to nothing if no matches
temp_error_files=("${script_dir}"/temp_errors_*.txt)

if [[ "${#temp_error_files[@]}" -gt 0 ]]; then
    for ef in "${temp_error_files[@]}"; do
        # Each file is appended to the main log, separated by a blank line
        echo "" >> "${temp_errors}"
        cat "${ef}" >> "${temp_errors}"
    done
fi

# ---------------------------------------------------------------------------
# Print any collected errors in red
# ---------------------------------------------------------------------------
if [[ -s "${temp_errors}" ]]; then
    echo -e "${RED}=== ERRORS ENCOUNTERED ===${NC}"
    while IFS= read -r line; do
        echo -e "${RED}${line}${NC}"
    done < "${temp_errors}"
fi

# ---------------------------------------------------------------------------
# Delete all temp error files (per-job + master)
# ---------------------------------------------------------------------------
rm -f "${script_dir}"/temp_errors_*.txt
rm -f "${temp_errors}"

# ---------------------------------------------------------------------------
# Final completion message
# ---------------------------------------------------------------------------
echo -e "${GREEN}"
echo "============================================"
echo "  Clip processing complete!"
echo "  Output files: ${output_dir}"
echo "============================================"
echo -e "${NC}"

# Disable the cleanup trap — we're exiting cleanly
trap - EXIT INT TERM
exit 0
