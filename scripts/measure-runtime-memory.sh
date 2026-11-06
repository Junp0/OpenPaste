#!/bin/bash
# Read-only: include every running OpenPaste app process, including its temporary UI.
set -euo pipefail
python3 - <<'PY'
import re
import subprocess

rows = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True).splitlines()
processes = []
for row in rows:
    fields = row.strip().split(None, 1)
    if len(fields) == 2 and fields[1].endswith(('/Contents/MacOS/OpenPaste', '/Contents/MacOS/iPaste')):
        processes.append((int(fields[0]), fields[1]))
if not processes:
    raise SystemExit('没有运行中的 OpenPaste 应用进程。')
total = 0.0
count = 0
for pid, path in processes:
    result = subprocess.run(['vmmap', '-summary', str(pid)], text=True, capture_output=True, timeout=15)
    match = re.search(r'^Physical footprint:\s*([\d.]+)([KMG]?)', result.stdout, re.MULTILINE)
    if not match:
        if subprocess.run(['kill', '-0', str(pid)], capture_output=True).returncode:
            print(f'{pid}: 采样期间已退出')
            continue
        raise SystemExit(f'无法读取进程 {pid} 的 physical footprint，未输出不完整的合计。')
    amount = float(match[1]) * {'': 1 / 1048576, 'K': 1 / 1024, 'M': 1, 'G': 1024}[match[2]]
    args = subprocess.run(['ps', '-p', str(pid), '-o', 'args='], text=True, capture_output=True).stdout
    role = '按需界面' if '--shelf-interface' in args else ('捕获任务' if '--capture-worker' in args else '主进程')
    print(f'{pid} {role}: {amount:.1f} MiB ({path})')
    total += amount
    count += 1
print(f'合计: {total:.1f} MiB，{count} 个存活进程（physical footprint，包含界面进程）')
PY
