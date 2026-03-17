#!/bin/bash

# Batch transcription script for ca4e-media
# macOS Bash 3.2 friendly

set -u

ROOT="${ROOT:-$(pwd)}"
WHISPER="${WHISPER:-whisper-cli}"
MODEL="${MODEL:-$HOME/models/ggml-medium.bin}"
VOCAB_FILE="${VOCAB_FILE:-$ROOT/whisper-vocabulary.txt}"
LOG_FILE="${LOG_FILE:-$ROOT/whisper-batch.log}"
TMP_SUFFIX=".whisper-temp.wav"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

log() {
    echo "$*" | tee -a "$LOG_FILE"
}

format_time() {
    seconds="$1"
    printf "%02d:%02d:%02d" \
        $((seconds/3600)) \
        $(((seconds%3600)/60)) \
        $((seconds%60))
}

build_prompt() {
    awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
            if (length($0) > 0) {
                if (out != "") out = out ", "
                out = out $0
            }
        }
        END {
            print out
        }
    ' "$VOCAB_FILE"
}

normalize_path() {
    inpath="$1"

    case "$inpath" in
        /*)
            printf "%s\n" "$inpath"
            ;;
        Users/*)
            printf "/%s\n" "$inpath"
            ;;
        ./*)
            printf "%s/%s\n" "$ROOT" "${inpath#./}"
            ;;
        *)
            printf "%s/%s\n" "$ROOT" "$inpath"
            ;;
    esac
}

cleanup_temp_file() {
    temp_file="$1"
    if [ -n "$temp_file" ] && [ -f "$temp_file" ]; then
        rm -f "$temp_file"
    fi
}

extract_audio() {
    media_file="$1"
    temp_wav="$2"
    err_file="$3"

    rm -f "$err_file"

    ffmpeg -y -v error -i "$media_file" -ar 16000 -ac 1 -c:a pcm_s16le "$temp_wav" 2>"$err_file"
    return $?
}

process_file() {
    original_media_file="$1"
    media_file="$(normalize_path "$original_media_file")"

    base="${media_file%.*}"
    txt_file="${base}.txt"
    temp_wav="${base}${TMP_SUFFIX}"
    err_file="${base}.ffmpeg-error.log"
    stem_name="$(basename "$base")"
    file_hint="$(echo "$stem_name" | tr '-' ' ')"
    prompt="Computer Architecture for Everybody, CA4E, Dr. Chuck, Chuck Severance, ${file_hint}. Technical vocabulary: ${VOCAB_PROMPT}"

    if [ ! -f "$media_file" ]; then
        log ""
        log "=================================================="
        log "MEDIA: $original_media_file"
        log "NORMALIZED: $media_file"
        log "FAILED: input file does not exist"
        return 1
    fi

    if [ -f "$txt_file" ]; then
        log "SKIP: $media_file (found $(basename "$txt_file"))"
        return 0
    fi

    log ""
    log "=================================================="
    log "MEDIA: $media_file"
    log "TEMP WAV: $temp_wav"
    log "OUTPUT BASE: $base"

    total_start=$(date +%s)

    cleanup_temp_file "$temp_wav"
    rm -f "$err_file"

    log "STEP 1: Extracting audio with ffmpeg..."
    ffmpeg_start=$(date +%s)

    if ! extract_audio "$media_file" "$temp_wav" "$err_file"; then
        log "WARNING: ffmpeg failed first try, retrying once..."
        sleep 1
        cleanup_temp_file "$temp_wav"

        if ! extract_audio "$media_file" "$temp_wav" "$err_file"; then
            log "FAILED: ffmpeg could not extract audio from $media_file"
            if [ -s "$err_file" ]; then
                log "FFMPEG ERROR:"
                sed 's/^/  /' "$err_file" | tee -a "$LOG_FILE"
            fi
            cleanup_temp_file "$temp_wav"
            return 1
        fi
    fi

    ffmpeg_end=$(date +%s)
    ffmpeg_time=$((ffmpeg_end - ffmpeg_start))

    if [ ! -f "$temp_wav" ]; then
        log "FAILED: temp wav was not created: $temp_wav"
        return 1
    fi

    log "STEP 2: Running whisper-cli..."
    whisper_start=$(date +%s)

    if [ "$SUPPORTS_PROMPT" -eq 1 ]; then
        if ! "$WHISPER" \
            -m "$MODEL" \
            -f "$temp_wav" \
            -of "$base" \
            -otxt \
            -ovtt \
            -osrt \
            --prompt "$prompt" >>"$LOG_FILE" 2>&1; then
            log "FAILED: whisper-cli transcription failed for $media_file"
            cleanup_temp_file "$temp_wav"
            return 1
        fi
    else
        log "NOTE: whisper-cli does not support --prompt; running without prompt"
        if ! "$WHISPER" \
            -m "$MODEL" \
            -f "$temp_wav" \
            -of "$base" \
            -otxt \
            -ovtt \
            -osrt >>"$LOG_FILE" 2>&1; then
            log "FAILED: whisper-cli transcription failed for $media_file"
            cleanup_temp_file "$temp_wav"
            return 1
        fi
    fi

    whisper_end=$(date +%s)
    whisper_time=$((whisper_end - whisper_start))

    cleanup_temp_file "$temp_wav"
    rm -f "$err_file"

    total_end=$(date +%s)
    total_time=$((total_end - total_start))

    if [ -f "${base}.txt" ]; then
        log "DONE: $media_file"
        log "TIMING:"
        log "  FFMPEG : $(format_time "$ffmpeg_time")"
        log "  WHISPER: $(format_time "$whisper_time")"
        log "  TOTAL  : $(format_time "$total_time")"
        return 0
    fi

    log "WARNING: whisper-cli finished but ${base}.txt was not found"
    return 1
}

if ! command -v "$WHISPER" >/dev/null 2>&1; then
    fail "Cannot find '$WHISPER' in PATH"
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
    fail "Cannot find 'ffmpeg' in PATH"
fi

if [ ! -f "$MODEL" ]; then
    fail "Model not found: $MODEL"
fi

if [ ! -f "$VOCAB_FILE" ]; then
    fail "Vocabulary file not found: $VOCAB_FILE"
fi

SUPPORTS_PROMPT=0
if "$WHISPER" --help 2>&1 | grep -q -- "--prompt"; then
    SUPPORTS_PROMPT=1
fi

VOCAB_PROMPT="$(build_prompt)"

: > "$LOG_FILE"

log "Batch started: $(date)"
log "ROOT=$ROOT"
log "WHISPER=$WHISPER"
log "MODEL=$MODEL"
log "VOCAB_FILE=$VOCAB_FILE"
log "LOG_FILE=$LOG_FILE"
log "SUPPORTS_PROMPT=$SUPPORTS_PROMPT"
log "TEMP_SUFFIX=$TMP_SUFFIX"
log "=================================================="

TOTAL=0
DONE_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

while IFS= read -r -d '' media_file
do
    TOTAL=$((TOTAL + 1))

    normalized_media_file="$(normalize_path "$media_file")"
    base="${normalized_media_file%.*}"
    txt_file="${base}.txt"

    if [ -f "$txt_file" ]; then
        log "SKIP: $normalized_media_file (found $(basename "$txt_file"))"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi

    if process_file "$media_file"; then
        DONE_COUNT=$((DONE_COUNT + 1))
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done < <(
    find "$ROOT" -type f \
        \( -iname "*.m4v" -o -iname "*.mp4" -o -iname "*.mov" -o -iname "*.m4a" -o -iname "*.mp3" -o -iname "*.wav" -o -iname "*.aac" \) \
        -print0 | sort -z
)

log ""
log "=================================================="
log "Batch finished: $(date)"
log "TOTAL=$TOTAL"
log "DONE=$DONE_COUNT"
log "SKIPPED=$SKIP_COUNT"
log "FAILED=$FAIL_COUNT"
log "LOG=$LOG_FILE"
log "=================================================="
