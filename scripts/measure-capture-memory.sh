#!/bin/bash
# Actual release executable, disposable named pasteboards, no user clipboard.
set -euo pipefail
cd "$(dirname "$0")/.."
probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/ipaste-capture-memory.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT
app_executable="${1:-$PWD/build/OpenPaste.app/Contents/MacOS/OpenPaste}"
python3 - "$app_executable" <<'PY'
from pathlib import Path
import sys
if b'--capture-worker' not in Path(sys.argv[1]).read_bytes():
    raise SystemExit('请先构建支持 --capture-worker 的当前版本；本脚本不会启动旧版应用。')
PY
cat > "$probe_dir/main.swift" <<'SWIFT'
import AppKit
import Foundation

let executable = URL(fileURLWithPath: CommandLine.arguments[1])
for size in [1, 18, 21] {
    try autoreleasepool {
        let name = "io.clipshelf.memory-probe.\(UUID().uuidString)"
        let board = NSPasteboard(name: .init(name))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: directory) }
        board.clearContents()
        board.setData(Data(repeating: 97, count: size * 1024 * 1024), forType: .string)
        let reader = Process(), input = Pipe(), output = Pipe(), metrics = Pipe()
        reader.executableURL = URL(fileURLWithPath: "/usr/bin/time")
        reader.arguments = ["-l", executable.path, "--capture-worker"]
        reader.standardInput = input; reader.standardOutput = output; reader.standardError = metrics
        let request: [String: Any] = ["pasteboardName": name, "changeCount": board.changeCount,
            "databasePath": directory.appendingPathComponent("history.sqlite").path,
            "sourceName": "Memory Benchmark", "sourceBundle": "test.memory-benchmark"]
        print("\(size) MiB synthetic text payload (capture worker peak, not idle memory):")
        fflush(stdout)
        try reader.run()
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: request))
        try input.fileHandleForWriting.close()
        let result = try JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile()) as! [String: Any]
        let report = String(decoding: metrics.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        reader.waitUntilExit()
        guard reader.terminationStatus == 0 else { exit(1) }
        let expected = size <= 20 ? "captured" : "tooLarge"
        guard result["status"] as? String == expected else { print(result); exit(1) }
        if size <= 20 {
            guard result["bytes"] as? Int == size * 1024 * 1024 else { print(result); exit(1) }
        }
        print("status=\(expected), workerExited=true")
        for line in report.split(separator: "\n") where line.contains("peak memory footprint") {
            print(line.trimmingCharacters(in: .whitespaces))
        }
    }
}
SWIFT
swiftc -O "$probe_dir/main.swift" -o "$probe_dir/produce"
"$probe_dir/produce" "$app_executable"
