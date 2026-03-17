#!/bin/bash

# find videos without transcripts

find . -name "*.m4v" | while read f; do
    base="${f%.*}"
    if [ ! -f "${base}.txt" ]; then
        echo "MISSING TRANSCRIPT: $f"
    fi
done

