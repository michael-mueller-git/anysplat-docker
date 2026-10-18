#!/usr/bin/env bash
set -euo pipefail

# Runtime interface -----------------------------------------------------------
: "${GRADIO_SERVER_NAME:=0.0.0.0}"
: "${GRADIO_SERVER_PORT:=7860}"
export GRADIO_SERVER_NAME GRADIO_SERVER_PORT

# Where uploads / interpolated videos / .ply outputs are written.
# Mount a volume here to persist results.
: "${ANYSPLAT_PROCESSED:=/app/proprocess_results}"
export ANYSPLAT_PROCESSED
mkdir -p "${ANYSPLAT_PROCESSED}" 2>/dev/null \
  || echo "anysplat: warning: cannot create ${ANYSPLAT_PROCESSED} (read-only or permission denied)"

echo "anysplat: model=${ANYSPLAT_MODEL:-/opt/models/anysplat}"
echo "anysplat: outputs=${ANYSPLAT_PROCESSED}"
echo "anysplat: HF_ENDPOINT=${HF_ENDPOINT:-<default>} HF_HOME=${HF_HOME:-<unset>}"
echo "anysplat: serving on ${GRADIO_SERVER_NAME}:${GRADIO_SERVER_PORT}"

cd /app
exec python3 app.py
