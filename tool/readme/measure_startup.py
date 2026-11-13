"""Start time and idle memory of a desktop app, run with an empty profile.

  python -I measure_startup.py <name> <profile_dir> <exe> [args...]

Prints one JSON line: time from process creation to the first visible main window (median of the warm runs)
and, on the last run, the memory of the whole process tree after it sat idle. The app is started with
USERPROFILE/APPDATA/LOCALAPPDATA pointing at <profile_dir>, so it neither reads nor writes real user data.
Only processes started here are closed.
"""

import ctypes
import json
import os
import statistics
import subprocess
import sys
import time
from ctypes import wintypes

import psutil

RUNS, IDLE_SECONDS, TIMEOUT = 5, 15, 60
user32 = ctypes.windll.user32
user32.SetProcessDPIAware()


def tree(root):
    try:
        return [root, *root.children(recursive=True)]
    except psutil.NoSuchProcess:
        return []


def main_windows(pids):
    found = []

    @ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    def each(hwnd, _):
        pid = wintypes.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        if pid.value in pids and user32.IsWindowVisible(hwnd):
            rect = wintypes.RECT()
            user32.GetWindowRect(hwnd, ctypes.byref(rect))
            # A splash screen is not the main window.
            if rect.right - rect.left >= 600 and rect.bottom - rect.top >= 400:
                found.append(hwnd)
        return True

    user32.EnumWindows(each, 0)
    return found


def run(profile, command, idle):
    env = dict(os.environ)
    env['USERPROFILE'] = profile
    env['APPDATA'] = os.path.join(profile, 'AppData', 'Roaming')
    env['LOCALAPPDATA'] = os.path.join(profile, 'AppData', 'Local')
    for key in ('APPDATA', 'LOCALAPPDATA'):
        os.makedirs(env[key], exist_ok=True)
    started = time.perf_counter()
    process = subprocess.Popen(command, env=env, cwd=os.path.dirname(command[0]))
    root = psutil.Process(process.pid)
    windows = []
    while not windows:
        if time.perf_counter() - started > TIMEOUT:
            break
        time.sleep(0.005)
        windows = main_windows({p.pid for p in tree(root)})
    shown = time.perf_counter() - started
    result = {'seconds': shown if windows else None}
    if windows and idle:
        time.sleep(IDLE_SECONDS)
        unique = resident = count = 0
        for p in tree(root):
            try:
                info = p.memory_full_info()
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                continue
            unique += info.uss
            resident += info.rss
            count += 1
        result |= {'unique_mib': unique / 2**20, 'resident_mib': resident / 2**20, 'processes': count}
    else:
        time.sleep(2)
    mine = tree(root)
    for hwnd in main_windows({p.pid for p in mine}):
        user32.PostMessageW(hwnd, 0x0010, 0, 0)  # WM_CLOSE
    _, alive = psutil.wait_procs(mine, timeout=8)
    for p in alive:
        try:
            p.kill()
        except psutil.NoSuchProcess:
            pass
    time.sleep(1)
    return result


def main():
    name, profile, command = sys.argv[1], os.path.abspath(sys.argv[2]), sys.argv[3:]
    run(profile, command, False)  # first run fills the file cache and any first-run setup
    results = [run(profile, command, index == RUNS - 1) for index in range(RUNS)]
    times = [r['seconds'] for r in results if r['seconds'] is not None]
    last = results[-1]
    print(json.dumps({
        'name': name,
        'start_seconds_median': round(statistics.median(times), 3) if times else None,
        'start_seconds_all': [round(t, 3) for t in times],
        'idle_unique_mib': round(last.get('unique_mib', 0), 1),
        'idle_resident_mib': round(last.get('resident_mib', 0), 1),
        'processes': last.get('processes'),
    }))


if __name__ == '__main__':
    main()
