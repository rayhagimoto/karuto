#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
cargo test --manifest-path stitcher/Cargo.toml --offline
cargo build --manifest-path stitcher/Cargo.toml --release --offline
developer_dir=$(xcode-select -p)
testing_plugin="$developer_dir/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
testing_flags=()
if [[ -f "$testing_plugin" ]]; then
  testing_flags=(-Xswiftc -load-plugin-library -Xswiftc "$testing_plugin")
fi
swift test --disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" -debug-info-format none "${testing_flags[@]}"
