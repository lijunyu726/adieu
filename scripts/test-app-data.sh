#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p scratch/SwiftModuleCache
python3 - <<'PY'
from pathlib import Path
import subprocess
sources = sorted(str(p) for folder in ['Adieu', 'Shared'] for p in Path(folder).rglob('*.swift'))
subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', '-enable-testing',
                '-module-cache-path', 'scratch/SwiftModuleCache', '-module-name', 'ReviewAppData',
                '-emit-library', '-emit-module', '-emit-module-path', 'scratch/ReviewAppData.swiftmodule',
                '-Xlinker', '-install_name', '-Xlinker', '@rpath/libReviewAppData.dylib',
                *sources, '-o', 'scratch/libReviewAppData.dylib'], check=True)
subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library',
                '-module-cache-path', 'scratch/SwiftModuleCache', '-I', 'scratch', '-L', 'scratch',
                '-lReviewAppData', '-Xlinker', '-rpath', '-Xlinker', '@executable_path',
                'Tests/AppDataBrowserTests.swift', '-o', 'scratch/app-data-model-tests'], check=True)
subprocess.run(['scratch/app-data-model-tests', '-AdieuSample', 'YES', '-confirmAlways', 'NO'], check=True)
PY
