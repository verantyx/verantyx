#!/bin/bash
set -e
shopt -s dotglob extglob

mkdir -p cli core cortex cortex-ios memory tools

# Move _verantyx-cortex
if [ -d "_verantyx-cortex" ]; then
    mv _verantyx-cortex/* cortex/ 2>/dev/null || true
    rmdir _verantyx-cortex 2>/dev/null || true
fi

# Move tool-search-oss
if [ -d "tool-search-oss" ]; then
    mv tool-search-oss/* tools/ 2>/dev/null || true
    rmdir tool-search-oss 2>/dev/null || true
fi

# Move everything else to cli/
for item in *; do
    if [[ "$item" != "cli" && "$item" != "core" && "$item" != "cortex" && "$item" != "cortex-ios" && "$item" != "memory" && "$item" != "tools" && "$item" != ".git" && "$item" != "organize.sh" ]]; then
        mv "$item" cli/
    fi
done

# Import from verantyx_v6
if [ -d "../verantyx_v6/core" ]; then
    cp -R ../verantyx_v6/core/* core/ 2>/dev/null || true
fi
if [ -d "../verantyx_v6/cross-memory-space" ]; then
    cp -R ../verantyx_v6/cross-memory-space/* memory/ 2>/dev/null || true
fi
if [ -d "../verantyx_v6/VerantyxWorkspace-iOS" ]; then
    cp -R ../verantyx_v6/VerantyxWorkspace-iOS/* cortex-ios/ 2>/dev/null || true
fi

