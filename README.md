# Steam Video Converter

A powerful bash script that automatically combines, re-encodes, and organizes Steam game clips into polished video files with proper game names.

## Overview

This script processes raw Steam gameplay recordings (stored as fragmented video chunks) into clean, compressed MKV files. It handles:

- **Concatenation**: Merges init segments and video/audio chunks into continuous streams
- **Re-encoding**: Optionally compresses output with AV1 video codec (GPU-accelerated when available)
- **GPU Acceleration**: Detects and uses hardware encoders (NVIDIA, AMD, Intel, Apple Silicon)
- **Game Naming**: Automatically fetches and applies game names from Steam's API
- **Parallel Processing**: Encodes multiple clips simultaneously for speed
- **Stream Validation**: Verifies output integrity with ffprobe

## Features

### 🎮 Automatic Game Name Resolution
- Extracts SteamIDs from clip filenames
- 3-tier resolution: Steam Store API → SteamDB → bulk app list fallback
- The full ~50 MB app list is only downloaded as a last resort if both APIs fail
- Local caching to avoid repeated API calls
- Handles failed lookups gracefully

### ⚡ Hardware Acceleration
- **Apple Silicon**: VideoToolbox (macOS 14+)
- **NVIDIA**: NVENC with RTX 40xx+ support (fallback to HEVC)
- **AMD**: AMF or VAAPI depending on driver
- **Intel**: Quick Sync Video (QSV)
- **Fallback**: CPU encoding with libsvtav1

### 🚀 Performance Optimizations
- Parallel job execution (CPU threads −2)
- RAM-backed temp directories (no disk I/O bottleneck)
- Lightweight per-ID API lookups before any bulk download
- Process substitution for stream copying
- GPU retry fallback on CPU if GPU encode fails

### 🛡️ Robust Error Handling
- Per-job error logging
- ffprobe stream integrity checks
- Timeout protection (10 minutes per clip)
- Cleanup of orphaned files and directories

## Requirements

### Dependencies

**All platforms:**
- `ffmpeg` with hardware encoder support (if using GPU)
- `bash` 4.0+
- `curl` (for API calls)

**macOS:**
- GNU `coreutils` for `gsort` (native `sort -V` doesn't exist)
  ```bash
  brew install coreutils
  ```

**Linux:**
- Standard `sort` with `-V` support (included by default)

### Optional
- `jq` for faster JSON parsing (script falls back to grep if missing)

## Usage

### Basic Usage

```bash
chmod +x convert-clips.sh
./convert-clips.sh
```

The script will prompt you to select an encoder:
```
Select encoder:
  1) copy  — stream copy, no re-encode (fast)
  2) av1   — re-encode with AV1 (smaller files, slower)
Encoder [1/2] (default: 1):
```

Press Enter to accept the default, or type `1` or `2` to choose.

## Configuration

Edit the script's `SECTION 1: ENVIRONMENT SETUP` to customize:

```bash
# --- Encoding & debug configuration ---

# default_encoder: "copy" = stream copy (fast, no re-encode)
#                  "av1"  = re-encode with AV1 (smaller files, slower)
# This sets the default for the interactive encoder prompt.
# To skip the prompt entirely, also set encoder_prompt=false below.
default_encoder="copy"

# Set to false to suppress the encoder prompt and use default_encoder as-is
encoder_prompt=true

# Debug mode: true = print each command before executing (set -x)
debug_mode=false
```

### Examples

```bash
# Run with defaults (stream copy, encoder prompt shown)
./convert-clips.sh

# Skip the prompt entirely and force AV1 encoding
# (edit in script: default_encoder="av1", encoder_prompt=false)

# Enable debug tracing for troubleshooting
# (edit in script: debug_mode=true)
```

## Output

### Processed Files

Output files are created in `CONVERTED/` with the pattern:

```
GameName_YYYYMMDD_HHMMSS_av1.mkv  # If AV1 encoded
GameName_YYYYMMDD_HHMMSS.mkv      # If stream copied
```

Example:
```
Portal_2_20260321_143021_av1.mkv
Half-Life_Alyx_20260320_091530_av1.mkv
```

### Cache Files

- `steam_id_cache.txt`: TSV cache of SteamID → Game Name mappings
- `errors.txt`: ffprobe warnings and stream integrity issues

### Logs

- `temp_errors.txt`: Job-specific errors (cleaned up after each run)
- Console output: Real-time progress and diagnostics

## How It Works

### Step 1: Environment Setup
- Detects OS (Linux/macOS)
- Verifies dependencies
- Detects GPU hardware and available encoders
- Applies debug mode if enabled
- Prompts for encoder selection (unless suppressed)

### Step 2: Main Processing Loop
- Collects all clip directories
- Dispatches encoding jobs in parallel (respecting CPU limits)
- For each clip:
  - Locates init segments and video/audio chunks
  - Uses process substitution (`<(...)`) for stream copying (no temp files)
  - Builds concat demuxer file lists for AV1 encoding
  - Encodes with GPU (if available) or CPU (libsvtav1)
  - Probes output for stream integrity

### Step 3: Game Name Resolution
- For each unique SteamID extracted from filenames:
  1. **Cache check** — returns immediately if a previous run resolved this ID
  2. **Steam Store API** — lightweight per-ID query (`store.steampowered.com/api/appdetails`)
  3. **SteamDB API** — fallback per-ID query (`steamdb.info/api/GetAppDetails`)
  4. **Bulk app list** — only downloaded if any IDs remain unresolved after both APIs fail; fetched once per run, all remaining IDs batch-resolved in a single pass, then deleted
- Updates local cache with results
- Renames files with sanitized game names

### Step 4: Sanitization
- Removes temporary files
- Cleans up garbage files with duplicate extensions
- Removes sync conflict artifacts

### Step 5: Finalization
- Merges error logs
- Displays summary

## Performance Tips

### Disable AV1 for Speed
Stream copying is much faster than re-encoding. Set `default_encoder="copy"` and `encoder_prompt=false` to skip the prompt and always stream-copy.

### GPU Encoding
If you have a supported GPU, AV1 hardware encoding is 5–10× faster than CPU:
- **NVIDIA RTX 40xx**: Excellent performance
- **AMD RDNA3+**: Good performance via AMF
- **Intel Arc/UHD**: Good performance via QSV
- **Apple Silicon**: Excellent via VideoToolbox

### Parallel Processing
The script automatically uses `CPU threads − 2` (minus 2) for parallelism. Adjust by running multiple instances with different clip directories.

### RAM Disks
The script uses `/dev/shm` (Linux) or `DARWIN_USER_TEMP_DIR` (macOS) automatically. Ensure your system has at least 2–4 GB free RAM.


## Contributing

Issues, improvements, and suggestions welcome!

---

**Last Updated**: 2026-03-24
