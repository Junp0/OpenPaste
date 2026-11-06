#!/bin/bash
# Compare eager thumbnail loading with the shelf's metadata-only query.
# Uses disposable synthetic data; never opens the user's clipboard database.
set -euo pipefail
cd "$(dirname "$0")/.."
benchmark_dir="$(mktemp -d "${TMPDIR:-/tmp}/ipaste-memory.XXXXXX")"
trap 'rm -rf "$benchmark_dir"' EXIT
cat > "$benchmark_dir/main.swift" <<'SWIFT'
import Foundation
import Security
import ClipboardCore

let mode = CommandLine.arguments[1]
let database = try ClipboardDatabase(url: URL(fileURLWithPath: CommandLine.arguments[2]))
if mode == "fixture" {
    // Compressed image bytes are not highly compressible like zero-filled data.
    var thumbnail = Data(count: 128 * 1024)
    for index in 0..<1000 {
        let status = thumbnail.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
        }
        precondition(status == errSecSuccess)
        let text = "Synthetic image \(index)"
        try database.save(ClipDraft(kind: .image, title: text, text: "", sourceName: "Benchmark",
            sourceBundle: "test.benchmark", thumbnail: thumbnail,
            payload: ClipPayload(items: [[ClipRepresentation(type: "public.utf8-plain-text", data: Data(text.utf8))]])))
    }
    print("Synthetic fixture: 1,000 records, 128 KiB per thumbnail (no image decoding).")
} else {
    let records = try database.records(includeThumbnails: mode == "eager")
    withExtendedLifetime(records) {
        let bytes = records.reduce(0) { $0 + ($1.thumbnail?.count ?? 0) }
        let checksum = records.reduce(UInt64(0)) { total, record in
            total &+ (record.thumbnail?.reduce(UInt64(0)) { $0 &+ UInt64($1) } ?? 0)
        }
        print("\(mode): records=\(records.count), retained thumbnail bytes=\(bytes), checksum=\(checksum)")
        // Give macOS time to sample resident memory while the array is alive.
        Thread.sleep(forTimeInterval: 1)
    }
}
SWIFT
# Preserve the application's module boundary when benchmarking release builds.
swiftc -O -emit-library -emit-module -module-name ClipboardCore -I Sources/CSQLite \
    Sources/ClipboardCore/Models.swift Sources/ClipboardCore/Database.swift \
    -emit-module-path "$benchmark_dir/ClipboardCore.swiftmodule" -o "$benchmark_dir/libClipboardCore.dylib"
swiftc -O -I Sources/CSQLite -I "$benchmark_dir" -L "$benchmark_dir" -lClipboardCore \
    -Xlinker -rpath -Xlinker "$benchmark_dir" "$benchmark_dir/main.swift" -o "$benchmark_dir/measure"
"$benchmark_dir/measure" fixture "$benchmark_dir/history.sqlite"
for mode in eager metadata; do
    /usr/bin/time -l "$benchmark_dir/measure" "$mode" "$benchmark_dir/history.sqlite" 2>&1 \
        | awk '/records=|maximum resident set size|peak memory footprint/ { print }'
done
