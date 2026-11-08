#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p scratch/SwiftModuleCache
swiftc -swift-version 6 -module-cache-path scratch/SwiftModuleCache \
  Adieu/Data/Models.swift Adieu/Data/SampleData.swift \
  Adieu/Scan/App*.swift Adieu/Scan/LeftoverScanner.swift \
  Adieu/Scan/LaunchScanner.swift Adieu/Scan/SpaceScanner.swift \
  Adieu/Scan/FileCategorizer.swift Adieu/Scan/FileScanner.swift \
  Adieu/Scan/DiskInfo.swift Adieu/Scan/CodeSignClones.swift \
  Adieu/Scan/Shell.swift Adieu/Scan/WorktreeScanner.swift Adieu/Scan/InputMethods.swift \
  Adieu/Actions/TrashService.swift Adieu/Actions/WorktreeCleanup.swift \
  Adieu/Actions/HistoryStore.swift Adieu/Actions/WorktreeCacheStore.swift \
  Adieu/App/Blocking.swift Adieu/App/WorktreeCatalog.swift \
  Tests/WorktreeTests.swift Tests/WorktreeCacheTests.swift \
  -o scratch/worktree-tests
scratch/worktree-tests
