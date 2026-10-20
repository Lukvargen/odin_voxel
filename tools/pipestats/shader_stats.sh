# shader_stats.sh [shader]: compile shaders/<shader>.hlsl (default voxel_tracer) and print what the
# NVIDIA driver reports for its compute pipeline: registers per thread, local memory per thread
# (spills; the driver adds 2^36, taken off here), shared memory per group, binary size.
# Builds tools/pipestats/pipestats.exe on first use. Run from anywhere (bash).
set -e
R="$(cd "$(dirname "$0")/../.." && pwd)"; T="$R/tools/pipestats"; S="${1:-voxel_tracer}"
[ -f "$T/pipestats.exe" ] || (cd "$T" && odin build . -out:pipestats.exe)
/c/dev/vulkanSDK/Bin/dxc.exe -T cs_6_0 -E main -I "$R/shaders" "$R/shaders/$S.hlsl" -spirv -fspv-target-env=vulkan1.1 -Fo "$T/$S.spv"
python -I "$T/layout.py" /c/dev/vulkanSDK/Bin/spirv-cross.exe "$T/$S.spv" > "$T/$S.layout"
"$T/pipestats.exe" "$T/$S.spv" "$T/$S.layout" | python -I -c "
import sys
for l in sys.stdin:
    f = l.split(); n = [w for w in f if w.isdigit()]
    if l.startswith('  Local Memory'): print('  local memory    ', int(n[0]) - 2**36, 'bytes/thread')
    elif l.startswith('  Register'): print('  registers       ', n[0], 'per thread')
    elif l.startswith('  Shared'): print('  shared memory   ', n[0], 'bytes/group')
    elif l.startswith('  Binary'): print('  binary          ', n[0], 'bytes')
    elif not l.startswith('  '): print(l.rstrip())
"
