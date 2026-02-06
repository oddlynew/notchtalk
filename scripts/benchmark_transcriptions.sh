#!/usr/bin/env bash
set -euo pipefail

RUNS=20
MODEL="gpt-4o-transcribe"
MAX_TIME=180
TEXT="This is a benchmark sample for the Notchtalk transcription endpoint reliability test."

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --runs N          Number of requests to execute (default: ${RUNS})
  --model NAME      Model to test (default: ${MODEL})
  --max-time SEC    Curl max-time in seconds (default: ${MAX_TIME})
  --text TEXT       Spoken sample text for generated audio
  -h, --help        Show this help

Environment:
  OPENAI_API_KEY    Required API key for OpenAI API

Example:
  OPENAI_API_KEY=... ./scripts/benchmark_transcriptions.sh --runs 30 --model gpt-4o-transcribe
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runs)
      RUNS="$2"
      shift 2
      ;;
    --model)
      MODEL="$2"
      shift 2
      ;;
    --max-time)
      MAX_TIME="$2"
      shift 2
      ;;
    --text)
      TEXT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  echo "OPENAI_API_KEY is not set" >&2
  exit 1
fi

for cmd in say afconvert curl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing dependency: $cmd" >&2
    exit 1
  fi
done

# Prefer the system Python for compatibility; Homebrew Python can be blocked by system policy in some environments.
if [[ -x /usr/bin/python3 ]]; then
  PYTHON_BIN="/usr/bin/python3"
elif command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="$(command -v python3)"
else
  echo "Missing dependency: python3" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

AIF_FILE="$TMP_DIR/sample.aiff"
M4A_FILE="$TMP_DIR/sample.m4a"
RESULTS_CSV="$TMP_DIR/results.csv"

say -o "$AIF_FILE" -- "$TEXT"
afconvert -f m4af -d aac "$AIF_FILE" "$M4A_FILE" >/dev/null 2>&1

cat > "$RESULTS_CSV" <<CSV
run,status,http_code,time_total,ok,text_len,error_message
CSV

echo "Benchmarking model=$MODEL runs=$RUNS max_time=${MAX_TIME}s"
echo "Audio sample: $M4A_FILE"

for run in $(seq 1 "$RUNS"); do
  body_file="$TMP_DIR/body_${run}.json"
  err_file="$TMP_DIR/err_${run}.txt"
  status=0

  meta="$(curl -sS --max-time "$MAX_TIME" \
      -w '%{http_code} %{time_total}' \
      -o "$body_file" \
      -X POST "https://api.openai.com/v1/audio/transcriptions" \
      -H "Authorization: Bearer ${OPENAI_API_KEY}" \
      -F "model=${MODEL}" \
      -F "response_format=json" \
      -F "file=@${M4A_FILE}" 2>"$err_file")" || status=$?

  http_code="$(echo "${meta:-}" | awk '{print $1}')"
  time_total="$(echo "${meta:-}" | awk '{print $2}')"

  ok=false
  text_len=0
  error_message=""

  if [[ "$status" -eq 0 && "$http_code" == "200" ]]; then
    ok=true
    text_len="$(jq -r '.text // ""' "$body_file" | wc -m | tr -d ' ')"
  else
    if [[ "$status" -ne 0 && -s "$err_file" ]]; then
      error_message="$(tr '\n' ' ' < "$err_file" | sed 's/\"/\"\"/g')"
    elif jq -e . >/dev/null 2>&1 < "$body_file"; then
      error_message="$(jq -r '.error.message // .message // .error // "request_failed"' "$body_file" | tr '\n' ' ')"
    else
      error_message="curl_exit_${status}"
    fi
  fi

  printf '%s,%s,%s,%s,%s,%s,"%s"\n' \
    "$run" "$status" "${http_code:-0}" "${time_total:-0}" "$ok" "$text_len" "$error_message" >> "$RESULTS_CSV"

  echo "[$run/$RUNS] http=${http_code:-0} curl_status=$status time=${time_total:-0}s ok=$ok"
done

"$PYTHON_BIN" - "$RESULTS_CSV" <<'PY'
import csv
import statistics
import sys
from pathlib import Path

path = Path(sys.argv[1])
rows = list(csv.DictReader(path.open()))

success = [r for r in rows if r["ok"] == "true"]
failed = [r for r in rows if r["ok"] != "true"]

def to_float(r):
    try:
        return float(r["time_total"])
    except Exception:
        return 0.0

all_times = sorted(to_float(r) for r in rows)
success_times = sorted(to_float(r) for r in success)


def pct(vals, p):
    if not vals:
        return 0.0
    idx = int((len(vals) - 1) * p)
    return vals[idx]

print("\nSummary")
print(f"- total: {len(rows)}")
print(f"- success: {len(success)}")
print(f"- failed: {len(failed)}")
if rows:
    print(f"- success rate: {len(success) / len(rows) * 100:.1f}%")
if success_times:
    print(f"- success p50: {pct(success_times, 0.50):.2f}s")
    print(f"- success p90: {pct(success_times, 0.90):.2f}s")
    print(f"- success max: {max(success_times):.2f}s")
if all_times:
    print(f"- all p50: {pct(all_times, 0.50):.2f}s")
    print(f"- all p90: {pct(all_times, 0.90):.2f}s")

if failed:
    print("\nFailure samples")
    for row in failed[:10]:
        print(f"- run {row['run']}: http={row['http_code']} curl_status={row['status']} error={row['error_message']}")

print(f"\nCSV: {path}")
PY
