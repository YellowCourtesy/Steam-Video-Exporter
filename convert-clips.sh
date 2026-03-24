#!/usr/bin/env bash
# =============================================================================
# process_clips.sh — Steam Clip Processor
# Combines, re-encodes, and names Steam game clips using ffmpeg.
# Dependencies: ffmpeg, coreutils (macOS), bash 4+
# =============================================================================

# ===========================================================================
# SECTION 1: ENVIRONMENT SETUP
# ===========================================================================

# Resolve the directory containing this script (works with symlinks too)
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Directory & file paths (all relative to script_dir by default) ---
clips_dir="${script_dir}/clips"           # Input: folder of clip subdirectories
output_dir="${script_dir}/CONVERTED"         # Output: final processed video files
steam_id_cache="${script_dir}/steam_id_cache.txt"  # TSV: id <tab> name <tab> source <tab> date
ffprobe_errors="${script_dir}/errors.txt"          # All ffprobe stream-integrity warnings, appended each run

# If set to "true", AV1 re-encode is forced on without asking the user
av1_forced="false"

# If set to "true", AV1 re-encode is forced off without asking the user
# (av1_forced takes precedence if both are somehow set to "true")
av1_disabled="false"

# If set to "true", debug mode is enabled without asking the user
debug_mode_forced="false"

# If set to "true", the debug mode prompt is suppressed and debug stays off
# (debug_mode_forced takes precedence if both are somehow set to "true")
debug_mode_disabled="false"

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
# Interactive prompts
# (Skipped for individual options when their force/disable flag is set above)
# ---------------------------------------------------------------------------

# 1. Debug mode
# debug_mode_forced=true   → always on, no prompt
# debug_mode_disabled=true → always off, no prompt (forced wins if both true)
# otherwise                → ask the user (default no)
if [[ "${debug_mode_forced}" == "true" ]]; then
    debug_mode=true
    set -x
    echo "Debug mode enabled (forced)."
elif [[ "${debug_mode_disabled}" == "true" ]]; then
    debug_mode=false
else
    read -r -p "Enable debug mode? [y/N]: " debug_input
    debug_input="${debug_input,,}"   # lowercase
    if [[ "${debug_input}" == "y" || "${debug_input}" == "yes" ]]; then
        debug_mode=true
        set -x   # Print each command before executing
        echo "Debug mode enabled."
    else
        debug_mode=false
    fi
fi

# 2. AV1 re-encode
# av1_forced=true  → always encode with AV1, no prompt
# av1_disabled=true → never encode with AV1, no prompt (av1_forced wins if both true)
# otherwise        → ask the user (default yes)
encode_av1=true   # Default: yes
if [[ "${av1_forced}" == "true" ]]; then
    encode_av1=true
    echo "AV1 encoding enabled (forced)."
elif [[ "${av1_disabled}" == "true" ]]; then
    encode_av1=false
    echo "AV1 encoding disabled (forced off)."
else
    read -r -p "Re-encode output files with AV1 to save space? [Y/n]: " av1_input
    av1_input="${av1_input,,}"
    if [[ "${av1_input}" == "n" || "${av1_input}" == "no" ]]; then
        encode_av1=false
    fi
fi

echo ""
echo "Configuration:"
echo "  OS            : ${os}"
echo "  Debug mode    : ${debug_mode}"
echo "  AV1 encode    : ${encode_av1}"
echo "  GPU vendor    : ${gpu_vendor}"
echo "  Clips dir     : ${clips_dir}"
echo "  Output dir    : ${output_dir}"
echo ""

# ===========================================================================
# SECTION 2: MAIN PROCESSING LOOP  (parallel, max CPU_threads − 2 jobs)
# ===========================================================================

# --- Determine parallelism limit ---
cpu_threads="$(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 4)"
max_jobs=$(( cpu_threads > 2 ? cpu_threads - 2 : 1 ))
echo "Parallelism: ${max_jobs} concurrent jobs (${cpu_threads} logical CPUs detected)"

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

# --- Job counter for concurrency control ---
job_count=0
declare -a job_pids=()
declare -a job_exit_codes=()

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
    # Build encode_opts based on mode and GPU availability.
    # For -c copy: no transcoding occurs so GPU acceleration is irrelevant;
    #   we use bash process substitution to pipe concat streams directly into
    #   ffmpeg without writing any temp file at all.
    # For AV1: write concatenated streams to RAM temp files, then encode.
    #   GPU path uses av1_gpu_opts (set by detect_gpu); CPU path uses libsvtav1.
    # -----------------------------------------------------------------------
    local ffmpeg_log="${ram_tmp}/.tmp_ffmpeg_${clip_name}_$$.log"
    local ffmpeg_exit=0

    if [[ "${encode_mode}" == "copy" ]]; then
        # -c copy: pure stream remux — no decode/encode work.
        # Pipe init+chunks directly into ffmpeg via process substitution.
        # This avoids ALL temp files; data flows init→chunks→ffmpeg in RAM.
        timeout 600 ffmpeg \
            -v error \
            -i <(cat "${video_init}" "${video_chunks[@]}") \
            -i <(cat "${audio_init}" "${audio_chunks[@]}") \
            -map 0:v:0 \
            -map 1:a:0 \
            -c copy \
            -y \
            "${output_file}" \
            2>"${ffmpeg_log}"
        ffmpeg_exit=$?

    else
        # AV1 encode: ffmpeg needs seekable input for GPU upload and
        # multi-pass analysis. Use the concat demuxer with a file list
        # instead of cat-ing everything into a single temp file. This
        # avoids doubling RAM usage and eliminates the sequential cat step.
        local concat_video="${ram_tmp}/.tmp_concat_video_${clip_name}_$$.txt"
        local concat_audio="${ram_tmp}/.tmp_concat_audio_${clip_name}_$$.txt"

        # Build concat demuxer file lists (init segment first, then chunks)
        {
            printf "file '%s'\n" "${video_init}"
            printf "file '%s'\n" "${video_chunks[@]}"
        } > "${concat_video}"
        {
            printf "file '%s'\n" "${audio_init}"
            printf "file '%s'\n" "${audio_chunks[@]}"
        } > "${concat_audio}"

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

        # First attempt: GPU (or CPU if gpu_vendor==none)
        timeout 600 ffmpeg \
            -v error \
            -f concat -safe 0 -i "${concat_video}" \
            -f concat -safe 0 -i "${concat_audio}" \
            -map 0:v:0 \
            -map 1:a:0 \
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
                -f concat -safe 0 -i "${concat_video}" \
                -f concat -safe 0 -i "${concat_audio}" \
                -map 0:v:0 \
                -map 1:a:0 \
                -c:v libsvtav1 -preset 13 -crf 0 -c:a flac -compression_level 12 \
                -y \
                "${output_file}" \
                2>"${ffmpeg_log}"
            ffmpeg_exit=$?
        fi

        rm -f "${concat_video}" "${concat_audio}"
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
    # (tmp_video/tmp_audio are removed inside the AV1 branch above)
    # -----------------------------------------------------------------------
    rm -f "${ffmpeg_log}"

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
# 3c-pre. Pre-download Steam app list and batch-resolve all cache misses.
# Instead of invoking jq on the 50 MB JSON once per cache miss, we:
#   1. Collect all SteamIDs that are not in the cache (or are ERROR entries).
#   2. Download the app list once (if not already cached).
#   3. Run a single jq pass to extract names for ALL needed IDs at once.
# This turns N × O(50 MB) into 1 × O(50 MB).
# ---------------------------------------------------------------------------
steam_list_cache="${script_dir}/.steam_app_list_cache.json"

# Collect IDs that need resolution
declare -A prefetched_names   # map: steam_id → game_name (from batch lookup)
ids_needing_lookup=()

for steam_id in "${!steam_id_to_files[@]}"; do
    cached_name="$(lookup_cache "${steam_id}")"
    if [[ -z "${cached_name}" ]]; then
        ids_needing_lookup+=("${steam_id}")
    fi
done

# If there are cache misses, pre-download the app list and batch-resolve
if [[ "${#ids_needing_lookup[@]}" -gt 0 ]]; then
    echo "[PREFETCH] ${#ids_needing_lookup[@]} SteamID(s) need resolution"

    # Download the app list once if not already cached
    if [[ ! -f "${steam_list_cache}" ]]; then
        echo "[INFO] Downloading Steam app list (one-time, may take a moment)..."
        curl -s --max-time 60 \
            "https://api.steampowered.com/ISteamApps/GetAppList/v2/" \
            -o "${steam_list_cache}" || true
    fi

    # Batch jq lookup: single pass over the 50 MB JSON for all needed IDs.
    # Output format: one "id\tname" per line.
    if [[ -f "${steam_list_cache}" ]] && command -v jq &>/dev/null; then
        # Build a jq filter array from the needed IDs
        jq_id_array="$(printf '%s\n' "${ids_needing_lookup[@]}" | jq -R 'tonumber' | jq -s '.')"

        while IFS=$'\t' read -r resolved_id resolved_name; do
            [[ -n "${resolved_id}" && -n "${resolved_name}" ]] || continue
            prefetched_names["${resolved_id}"]="${resolved_name}"
        done < <(
            jq -r --argjson ids "${jq_id_array}" \
                '[.applist.apps[] | select(.appid as $a | $ids | index($a))] | .[] | "\(.appid)\t\(.name)"' \
                "${steam_list_cache}" 2>/dev/null || true
        )

        echo "[PREFETCH] Resolved ${#prefetched_names[@]} name(s) from Steam app list in one pass"
    elif [[ -f "${steam_list_cache}" ]]; then
        # grep fallback when jq is absent — still faster than per-ID grep
        # because we read the file once and pipe through all patterns
        grep_pattern="$(printf '"appid":\\s*%s\\s*,' "${ids_needing_lookup[@]}" | sed 's/,$//')"
        # Fall back to per-ID grep (still one file read per ID, but no jq)
        for sid in "${ids_needing_lookup[@]}"; do
            resolved="$(grep -oP '"appid":\s*'"${sid}"'\s*,\s*"name":\s*"\K[^"]+' \
                "${steam_list_cache}" | head -n 1 || true)"
            if [[ -n "${resolved}" ]]; then
                prefetched_names["${sid}"]="${resolved}"
            fi
        done
        echo "[PREFETCH] Resolved ${#prefetched_names[@]} name(s) via grep fallback"
    fi
fi

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
            # Previously failed — treat as miss so we retry the APIs
            echo ""
        else
            echo "${line}" | cut -f2
        fi
    else
        echo ""
    fi
}

# Helper: fetch game name from SteamDB, fallback to pre-fetched batch results.
# The Steam app list is now pre-downloaded and batch-parsed in step 3c-pre,
# so this function checks the prefetched_names map instead of re-parsing
# the 50 MB JSON file for every single ID.
# Sets global variables: fetched_name, fetched_source
fetch_game_name() {
    local id="$1"
    fetched_name=""
    fetched_source=""

    # ---- Check batch-prefetched results first (instant, no I/O) ----
    if [[ -n "${prefetched_names[${id}]+_}" && -n "${prefetched_names[${id}]}" ]]; then
        fetched_name="${prefetched_names[${id}]}"
        fetched_source="steamapi"
        return 0
    fi

    # ---- Try SteamDB API (for IDs not in the app list) ----
    # Response JSON: {"data":{"name":"Game Name",...},...}
    local steamdb_response
    steamdb_response="$(curl -s --max-time 30 \
        "https://steamdb.info/api/GetAppDetails/?appid=${id}" || true)"

    if [[ -n "${steamdb_response}" ]]; then
        if command -v jq &>/dev/null; then
            # jq gives a precise, reliable parse
            fetched_name="$(echo "${steamdb_response}" | jq -r '.data.name // empty' 2>/dev/null || true)"
        else
            # grep fallback when jq is absent
            fetched_name="$(echo "${steamdb_response}" | grep -oP '"name"\s*:\s*"\K[^"]+' | head -n 1 || true)"
        fi
        if [[ -n "${fetched_name}" && "${fetched_name}" != "null" ]]; then
            fetched_source="steamdb"
            return 0
        fi
    fi

    # Both sources failed — name remains empty
    return 1
}

# Sanitise a game name so it's safe as a filename component
sanitise_name() {
    # Replace characters that are problematic in filenames with underscores
    echo "$1" | tr -s '/:*?"<>|\\' '_'
}

# Process each unique SteamID
for steam_id in "${!steam_id_to_files[@]}"; do
    echo "[STEAM] Processing ID: ${steam_id}"

    game_name=""

    # --- Acquire lock, check cache ---
    acquire_lock
    game_name="$(lookup_cache "${steam_id}")"
    release_lock

    if [[ -n "${game_name}" ]]; then
        echo "[CACHE HIT] ${steam_id} → ${game_name}"
    else
        echo "[CACHE MISS] ${steam_id} — querying APIs..."

        # Only enforce rate limit if we'll actually hit an external API.
        # Prefetched names (from the batch jq pass) need no network call.
        if [[ -z "${prefetched_names[${steam_id}]+_}" ]]; then
            sleep "${rate_limit_sec}"
        fi

        if fetch_game_name "${steam_id}"; then
            game_name="${fetched_name}"
            echo "[FETCH] ${steam_id} → ${game_name} (via ${fetched_source})"

            # --- Atomically write to cache (replace any prior ERROR entry) ---
            entry_date="$(date '+%Y-%m-%d')"
            acquire_lock
            # Remove any existing line for this ID (e.g. a prior ERROR entry)
            tmp_replace="${steam_id_cache}.replace.$$"
            grep -vP "^${steam_id}\t" "${steam_id_cache}" > "${tmp_replace}" || true
            mv "${tmp_replace}" "${steam_id_cache}"
            printf '%s\t%s\t%s\t%s\n' \
                "${steam_id}" "${game_name}" "${fetched_source}" "${entry_date}" \
                >> "${steam_id_cache}"
            release_lock
        else
            echo -e "${YELLOW}[WARN] Could not resolve SteamID: ${steam_id}${NC}"
            # Write/update an ERROR entry in the cache so we remember this ID
            # and can retry it on future runs. Remove any previous ERROR line first.
            entry_date="$(date '+%Y-%m-%d')"
            acquire_lock
            # Strip any existing entry for this ID (successful or prior ERROR)
            tmp_strip="${steam_id_cache}.strip.$$"
            grep -vP "^${steam_id}\t" "${steam_id_cache}" > "${tmp_strip}" || true
            mv "${tmp_strip}" "${steam_id_cache}"
            printf '%s\t%s\t%s\t%s\n' \
                "${steam_id}" "ERROR" "ERROR" "${entry_date}" \
                >> "${steam_id_cache}"
            release_lock
            game_name=""   # Signal that rename should be skipped
        fi
    fi

    # --- Rename each file that has this SteamID prefix ---
    # Skip renaming entirely when no name was resolved.
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
                echo "[RENAMED] ${base} → ${new_base}"
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
