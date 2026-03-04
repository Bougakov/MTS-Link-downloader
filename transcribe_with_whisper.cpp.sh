#!/bin/bash

# This script for Apple Silicon Macs accepts a path to a local audio file or a YouTube link. 
# It converts an audio track to 16-bit WAV audio and feeds it to Whisper.
# The output is a clean text file with a transcript.

# --- Configuration ---
# Temporary directory for intermediate files
TMP_DIR="/private/tmp"
# Whisper.cpp directory and executable - get it from https://github.com/ggml-org/whisper.cpp
WHISPER_DIR="/path/to/whisper.cpp"
WHISPER_EXE="${WHISPER_DIR}/main"
# Choose a model that suits you:
WHISPER_MODEL="${WHISPER_DIR}/models/ggml-medium.bin" 
#WHISPER_MODEL="${WHISPER_DIR}/models/ggml-large-v3.bin"
WHISPER_LANG="auto" # Can be auto, ru, en, de...

# --- Safety Checks ---
# Exit immediately if a command exits with a non-zero status.
set -e
# Treat unset variables as an error when substituting.
set -u
# Pipelines fail if any command fails, not just the last one.
set -o pipefail

# --- Function for logging ---
log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# --- Function for error handling ---
error_exit() {
  log "ERROR: $1" >&2
  exit 1
}

# --- Check Dependencies ---
command -v yt-dlp >/dev/null 2>&1 || error_exit "yt-dlp is not installed or not in PATH. Please install it (e.g., 'brew install yt-dlp')."
command -v ffmpeg >/dev/null 2>&1 || error_exit "ffmpeg is not installed or not in PATH. Please install it (e.g., 'brew install ffmpeg')."
[ -x "$WHISPER_EXE" ] || error_exit "Whisper executable not found or not executable at ${WHISPER_EXE}."
[ -f "$WHISPER_MODEL" ] || error_exit "Whisper model not found at ${WHISPER_MODEL}."

# --- Input Validation ---
if [ "$#" -ne 1 ]; then
  error_exit "Usage: $0 <youtube_link_or_local_file_path>"
fi

INPUT_SOURCE="$1"
AUDIO_SOURCE_PATH="" # This will hold the path to the audio file for ffmpeg

# --- 1. Determine Input Type and Handle YouTube Download ---
log "Input received: ${INPUT_SOURCE}"
# Simple check for http/https prefix to identify URLs
if [[ "$INPUT_SOURCE" =~ ^https?:// ]]; then
  log "Input identified as a URL. Assuming YouTube link."
  YOUTUBE_LINK="$INPUT_SOURCE"

  # Get expected output filename using --print filename
  log "Determining expected output filename for YouTube download..."
  EXPECTED_YT_WAV_PATH=$(yt-dlp --print filename --extract-audio --audio-format wav --audio-quality 0 --cookies-from-browser safari -o "${TMP_DIR}/%(id)s.%(ext)s" "$YOUTUBE_LINK") || error_exit "Failed to get expected filename from yt-dlp."

  if [ -z "$EXPECTED_YT_WAV_PATH" ]; then
      error_exit "yt-dlp did not return an expected filename."
  fi
  log "Expected output file: ${EXPECTED_YT_WAV_PATH}"

  # Perform the actual download
  log "Downloading audio from YouTube..."
  # We run the command again *without* --print filename to actually download
  yt-dlp --extract-audio --audio-format wav --audio-quality 0 --cookies-from-browser safari -o "${TMP_DIR}/%(id)s.%(ext)s" "$YOUTUBE_LINK" || error_exit "yt-dlp download failed."

  # Verify download
  if [ ! -f "$EXPECTED_YT_WAV_PATH" ]; then
      error_exit "YouTube download finished, but the expected file '${EXPECTED_YT_WAV_PATH}' was not found."
  fi
  log "YouTube audio downloaded successfully to ${EXPECTED_YT_WAV_PATH}"
  AUDIO_SOURCE_PATH="$EXPECTED_YT_WAV_PATH"

else
  log "Input identified as a local file path."
  if [ ! -f "$INPUT_SOURCE" ]; then
      error_exit "Local file not found: ${INPUT_SOURCE}"
  fi
  log "Using local file: ${INPUT_SOURCE}"
  AUDIO_SOURCE_PATH="$INPUT_SOURCE"
fi

# --- 2. Generate Unique Timestamped Base Filename ---
TIMESTAMP=$(date +%Y%m%d%H%M%S%N) # YearMonthDayHourMinuteSecondNanosecond
BASE_FILENAME="transcribe_${TIMESTAMP}"
log "Using base name for processing files: ${BASE_FILENAME}"

# --- 3. Convert Audio to Whisper Compatible Format ---
FFMPEG_OUTPUT_WAV="${TMP_DIR}/${BASE_FILENAME}.wav"
log "Converting audio to 16kHz 16-bit mono WAV: ${FFMPEG_OUTPUT_WAV}"

# Ensure absolute path for input if it's relative, handles spaces etc.
ffmpeg -i "$AUDIO_SOURCE_PATH" -af "silenceremove=start_periods=1:stop_periods=-1:start_threshold=-30dB:stop_threshold=-30dB:start_silence=2:stop_silence=2" -ar 16000 -ac 1 -c:a pcm_s16le "$FFMPEG_OUTPUT_WAV" || error_exit "ffmpeg conversion failed."

# Verify conversion output
if [ ! -f "$FFMPEG_OUTPUT_WAV" ]; then
    error_exit "ffmpeg conversion finished, but the output file '${FFMPEG_OUTPUT_WAV}' was not found."
fi
log "Audio conversion successful."

# --- 4. Run Whisper Transcription ---
WHISPER_OUTPUT_BASE="${TMP_DIR}/${BASE_FILENAME}" # Whisper adds extension
WHISPER_OUTPUT_CSV="${WHISPER_OUTPUT_BASE}.csv"   # Expected CSV output file

log "Starting transcription using whisper.cpp..."
log "Command: ${WHISPER_EXE} -bs 5 -et 2.4 --max-context 64 -bo 6 -tp 0.2 --language \"${WHISPER_LANG}\" -m \"${WHISPER_MODEL}\" --output-csv --output-file \"${WHISPER_OUTPUT_BASE}\" -np --file \"${FFMPEG_OUTPUT_WAV}\""

# NOTE: No 'cd' needed if paths are absolute. Runs from the current directory.
"$WHISPER_EXE" -bs 5 -et 2.4 --max-context 64 -bo 6 -tp 0.2 --language "$WHISPER_LANG" -m "$WHISPER_MODEL" --output-csv --output-file "$WHISPER_OUTPUT_BASE" -np --file "$FFMPEG_OUTPUT_WAV" || error_exit "whisper.cpp transcription failed."

# Verify transcription output
if [ ! -f "$WHISPER_OUTPUT_CSV" ]; then
    error_exit "whisper.cpp finished, but the expected output file '${WHISPER_OUTPUT_CSV}' was not found."
fi
log "Transcription successful. CSV output: ${WHISPER_OUTPUT_CSV}"

# --- 5. Process CSV to Plain Text ---
FINAL_TEXT_OUTPUT="${TMP_DIR}/${BASE_FILENAME}.txt"
log "Processing CSV to plain text: ${FINAL_TEXT_OUTPUT}"

# Use tail to skip header, cut to get 3rd column, sed to clean quotes and whitespace
# sed commands:
# 1. Remove leading spaces/tabs then a quote: s/^[[:space:]]*"//
# 2. Remove a quote then trailing spaces/tabs: s/"[[:space:]]*$//
# 3. Remove any remaining leading spaces/tabs: s/^[[:space:]]*//
# 4. Remove any remaining trailing spaces/tabs: s/[[:space:]]*$//
tail -n +2 "$WHISPER_OUTPUT_CSV" | cut -d ',' -f 3- | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' > "$FINAL_TEXT_OUTPUT"

# Verify final output
if [ ! -s "$FINAL_TEXT_OUTPUT" ]; then # -s checks if file exists and is not empty
    error_exit "Failed to create or populate the final text file '${FINAL_TEXT_OUTPUT}'."
fi

log "--- Process Complete ---"
log "Original Input: ${INPUT_SOURCE}"
log "Converted WAV: ${FFMPEG_OUTPUT_WAV}"
log "Whisper CSV Output: ${WHISPER_OUTPUT_CSV}"
log "Final Text Output: ${FINAL_TEXT_OUTPUT}"

exit 0
