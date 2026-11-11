#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p scratch/AgentSkillTests
python3 - <<'PY'
from pathlib import Path
import subprocess

output = Path('scratch/AgentSkillTests')
sources = sorted(str(path) for folder in ['Adieu', 'Shared'] for path in Path(folder).rglob('*.swift'))
flags = ['swiftc', '-swift-version', '6', '-parse-as-library', '-module-cache-path', str(output / 'ModuleCache')]
subprocess.run([*flags, '-enable-testing', '-module-name', 'ReviewAdieu',
                '-emit-library', '-emit-module', '-emit-module-path', str(output / 'ReviewAdieu.swiftmodule'),
                '-Xlinker', '-install_name', '-Xlinker', '@rpath/libReviewAdieu.dylib',
                *sources, '-o', str(output / 'libReviewAdieu.dylib')], check=True)
subprocess.run([*flags, '-I', str(output), '-L', str(output), '-lReviewAdieu',
                '-Xlinker', '-rpath', '-Xlinker', '@executable_path',
                'Tests/AgentSkillTests.swift', '-o', str(output / 'agent-skill-tests')], check=True)
subprocess.run([str(output / 'agent-skill-tests')], check=True)
PY
