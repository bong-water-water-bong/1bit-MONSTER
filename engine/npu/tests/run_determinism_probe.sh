#!/bin/bash
# run_determinism_probe.sh — issue #1799 controlled clean-window probe.
#
# Runs the two-launch zaya decode (NPU_FUSED unset: GU launch -> host silu ->
# D launch) N times on the SAME binary/model/prompt, monitoring firmware health
# (xrt-smi, dmesg AIE errors, load) BETWEEN runs, and records per-layer
# readback fingerprints (NPU_DBG_FP=1) + generated tokens per run.
#
# This is the issue's next-step 1: separate firmware degradation (H2: errors
# grow with cumulative DPU executions, early runs clean) from a deterministic
# race (H1: stable discrete outcome states independent of health) on a quiet,
# freshly-booted box.
#
# Usage: engine/npu/tests/run_determinism_probe.sh [runs=10] [token_id=236778]
# Output: /tmp/npu1799_probe/ (probe.log + runN.tokens / runN.err per run)
# Exit 0 = completed (any rc recorded in the log), 2 = wrong dir.
set -u
cd "$(git rev-parse --show-toplevel)" || exit 2
RUNS=${1:-10}
TOKEN=${2:-236778}
BIN=./npu_engine_zaya
MODEL=${NPU1799_MODEL:-/home/bcloud/models/zaya1-8b.q4nx}
OUT=/tmp/npu1799_probe
mkdir -p "$OUT"
LOG=$OUT/probe.log
: > "$LOG"

health() { # tag
  local load; read -r load _ < /proc/loadavg
  local xrt_issues=0
  if command -v xrt-smi >/dev/null 2>&1; then
    xrt_issues=$(xrt-smi health 2>/dev/null | grep -ciE "error|bad|fault" || true)
  fi
  local dm=0
  if dmesg 2>/dev/null | grep -qiE "aie|xrt|npu"; then
    dm=$(dmesg 2>/dev/null | grep -ciE "aie|xrt|npu.*(error|fault|timeout|wedge|reset)" || true)
  fi
  echo "load=$load xrt_issues=$xrt_issues dmesg_aie_issues=$dm"
}

echo "=== pre-flight $(date -u +%FT%TZ) uptime=$(uptime -p) $(health) ===" | tee -a "$LOG"
for i in $(seq 1 "$RUNS"); do
  t0=$(date +%s)
  env NPU_SEED=42 NPU_DBG_FP=1 NPU_N_GEN=2 NPU_XCLBIN_DIR=engine/npu/xclbins \
      timeout 300 "$BIN" "$MODEL" "$TOKEN" > "$OUT/run$i.tokens" 2> "$OUT/run$i.err"
  rc=$?
  t1=$(date +%s)
  toks=$(tr '\n' ' ' < "$OUT/run$i.tokens")
  fp=$(grep -c "^\[fp\]" "$OUT/run$i.err" || true)
  printf "run %2d rc=%d %3ds tokens=[%s] fp=%s %s\n" "$i" "$rc" "$((t1-t0))" "$toks" "$fp" "$(health)" | tee -a "$LOG"
done
echo "=== token summary ===" | tee -a "$LOG"
for i in $(seq 1 "$RUNS"); do
  printf "run %2d: %s\n" "$i" "$(tr '\n' ' ' < "$OUT/run$i.tokens")"
done | tee -a "$LOG"
