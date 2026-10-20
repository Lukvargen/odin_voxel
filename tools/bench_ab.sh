# bench_ab.sh A.exe B.exe [rounds] [bench args...]: A/B two builds' GPU time.
# Runs `bench quick hd <args>` alternately (A, B, A, B, ...) from the repo root
# and prints, per run, the default-settings frame time summed over the six
# views and each view's own. Run-to-run noise is ~1-4%: trust a change only
# if it holds in every round. Copy each build to its own fixed path first
# (shaders are #load-ed into the exe; a new path costs one ~20 s shader
# compile on its first run). Example:
#   bash tools/bench_ab.sh /tmp/base.exe ./odin_raytrace.exe 2 hour=17.3
set -e
A="$1"; B="$2"; ROUNDS="${3:-2}"; shift 3 2>/dev/null || shift $#
cd "$(dirname "$0")/.."
OUT="${TMPDIR:-/tmp}/bench_ab"; mkdir -p "$OUT"
for r in $(seq 1 "$ROUNDS"); do
  for e in "$A" "$B"; do
    f="$OUT/$(basename "$e" .exe)_$r.txt"
    "$e" bench quick hd "$@" > "$f" 2>&1
    s=$(grep "default (aa1" "$f" | awk '{s+=$4} END {printf "%.2f", s}')
    v=$(grep "default (aa1" "$f" | awk '{printf "%s ", $4}')
    echo "$(basename "$e") run $r: sum $s ms  [$v]"
  done
done
