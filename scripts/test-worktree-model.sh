#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p scratch/SwiftModuleCache
python3 - <<'PY'
from pathlib import Path
import subprocess
sources = sorted(str(p) for folder in ['Adieu', 'Shared'] for p in Path(folder).rglob('*.swift'))
subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', '-enable-testing',
                '-module-cache-path', 'scratch/SwiftModuleCache', '-module-name', 'ReviewAdieu',
                '-emit-library', '-emit-module', '-emit-module-path', 'scratch/ReviewAdieu.swiftmodule',
                '-Xlinker', '-install_name', '-Xlinker', '@rpath/libReviewAdieu.dylib',
                *sources, '-o', 'scratch/libReviewAdieu.dylib'], check=True)
subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library',
                '-module-cache-path', 'scratch/SwiftModuleCache', '-I', 'scratch', '-L', 'scratch',
                '-lReviewAdieu', '-Xlinker', '-rpath', '-Xlinker', '@executable_path',
                'Tests/WorktreeModelTests.swift', '-o', 'scratch/worktree-model-tests'], check=True)
subprocess.run(['scratch/worktree-model-tests', '-AdieuSample', 'NO'], check=True)
PY
