# layout.py <spirv-cross.exe> <shader.spv>: print pipestats' layout lines from SPIR-V reflection.
import json, subprocess, sys
j = json.loads(subprocess.run([sys.argv[1], sys.argv[2], '--reflect'], capture_output=True, text=True, check=True).stdout)
kinds = {'separate_images': 'SAMPLED_IMAGE', 'images': 'STORAGE_IMAGE', 'ssbos': 'STORAGE_BUFFER', 'ubos': 'UNIFORM_BUFFER'}
for k, t in kinds.items():
    for r in j.get(k, []):
        print(r['set'], r['binding'], t)
