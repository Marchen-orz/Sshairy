/// Parses the output of [statsCommand] and turns two samples into rates (docs/MODULES.md §8).
library;

/// A constant, read-only probe; nothing from hosts, paths or users is ever spliced in. It runs under `sh -c` so it
/// behaves the same whatever the login shell, and `df -l` keeps network mounts, which can hang, out of it.
const statsCommand =
    "sh -c '"
    'export LC_ALL=C; [ -r /proc/stat ] || { echo @@unsupported; exit 0; }; '
    'echo @@stat; head -n 1 /proc/stat; '
    'echo @@mem; cat /proc/meminfo; '
    'echo @@load; cat /proc/loadavg; '
    'echo @@up; cat /proc/uptime; '
    'echo @@net; cat /proc/net/dev; '
    'echo @@cpus; grep -c ^processor /proc/cpuinfo; '
    'echo @@df; df -kPl 2>/dev/null; '
    'if command -v nvidia-smi >/dev/null 2>&1; then echo @@gpu; '
    'nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu '
    '--format=csv,noheader,nounits 2>/dev/null; fi'
    "'";

class CpuTimes {
  const CpuTimes(this.busy, this.total);
  final int busy, total;
}

class Disk {
  const Disk(this.mount, this.usedKib, this.totalKib);
  final String mount;
  final int usedKib, totalKib;
  double get fraction => totalKib == 0 ? 0 : usedKib / totalKib;
}

class Gpu {
  const Gpu(this.name, {this.utilization, this.memoryUsedMib, this.memoryTotalMib, this.temperature});
  final String name;

  /// 0–1. Fields nvidia-smi reports as `[N/A]` are null.
  final double? utilization;
  final int? memoryUsedMib, memoryTotalMib;
  final int? temperature;

  double? get memoryFraction {
    final (used, total) = (memoryUsedMib, memoryTotalMib);
    return used == null || total == null || total == 0 ? null : used / total;
  }
}

/// One reading of the server; counters are cumulative, so rates need the previous sample.
class StatsSample {
  const StatsSample({
    required this.cpu,
    required this.memTotalKib,
    required this.memAvailableKib,
    required this.swapTotalKib,
    required this.swapFreeKib,
    required this.load,
    required this.uptime,
    required this.rxBytes,
    required this.txBytes,
    required this.cores,
    required this.disks,
    required this.gpus,
  });

  final CpuTimes? cpu;
  final int memTotalKib, memAvailableKib, swapTotalKib, swapFreeKib;
  final List<double> load;
  final Duration? uptime;
  final int rxBytes, txBytes;
  final int? cores;
  final List<Disk> disks;
  final List<Gpu> gpus;

  /// False when the server has no /proc, such as macOS or the BSDs.
  bool get supported => cpu != null && memTotalKib > 0;
}

/// What the panel shows: [sample] plus rates since the one before it.
class StatsSnapshot {
  const StatsSnapshot(this.sample, {this.cpu, this.rxPerSecond, this.txPerSecond});
  final StatsSample sample;

  /// 0–1; null for the first sample.
  final double? cpu;
  final double? rxPerSecond, txPerSecond;

  double get memory {
    final s = sample;
    return s.memTotalKib == 0 ? 0 : ((s.memTotalKib - s.memAvailableKib) / s.memTotalKib).clamp(0.0, 1.0);
  }

  double get swap {
    final s = sample;
    return s.swapTotalKib == 0 ? 0 : ((s.swapTotalKib - s.swapFreeKib) / s.swapTotalKib).clamp(0.0, 1.0);
  }
}

const _skipFs = {'tmpfs', 'devtmpfs', 'overlay', 'squashfs', 'udev', 'none', 'shm', 'efivarfs'};
const _systemMounts = ['/dev', '/run', '/sys', '/proc', '/snap'];

StatsSample parseStats(String output) {
  final sections = <String, List<String>>{};
  List<String>? current;
  for (final raw in output.split('\n')) {
    final line = raw.trimRight();
    if (line.startsWith('@@')) {
      current = sections[line.substring(2)] = [];
    } else if (current != null && line.isNotEmpty) {
      current.add(line);
    }
  }
  List<String> of(String name) => sections[name] ?? const [];

  CpuTimes? cpu;
  final stat = of('stat').where((l) => l.startsWith('cpu ')).firstOrNull;
  if (stat != null) {
    final n = stat.split(RegExp(r'\s+')).skip(1).map(int.tryParse).whereType<int>().toList();
    if (n.length >= 4) {
      // user nice system idle iowait irq softirq steal; guest time is already inside user and nice.
      final total = n.take(8).fold(0, (a, b) => a + b);
      final idle = n[3] + (n.length > 4 ? n[4] : 0);
      cpu = CpuTimes(total - idle, total);
    }
  }

  final mem = <String, int>{};
  for (final line in of('mem')) {
    final m = RegExp(r'^(\w+):\s+(\d+)').firstMatch(line);
    if (m != null) mem[m[1]!] = int.parse(m[2]!);
  }
  final available = mem['MemAvailable'] ?? (mem['MemFree'] ?? 0) + (mem['Buffers'] ?? 0) + (mem['Cached'] ?? 0);

  final loadFields = (of('load').firstOrNull ?? '').split(RegExp(r'\s+'));
  final load = loadFields.take(3).map(double.tryParse).whereType<double>().toList();

  final upSeconds = double.tryParse((of('up').firstOrNull ?? '').split(RegExp(r'\s+')).first);

  var rx = 0, tx = 0;
  for (final line in of('net')) {
    final colon = line.indexOf(':');
    if (colon < 0) continue;
    if (line.substring(0, colon).trim() == 'lo') continue;
    final n = line.substring(colon + 1).trim().split(RegExp(r'\s+')).map(int.tryParse).toList();
    if (n.length >= 9 && n[0] != null && n[8] != null) {
      rx += n[0]!;
      tx += n[8]!;
    }
  }

  final disks = <Disk>[];
  final seen = <String>{};
  for (final line in of('df')) {
    final f = line.split(RegExp(r'\s+'));
    if (f.length < 6) continue;
    final total = int.tryParse(f[1]), used = int.tryParse(f[2]);
    if (total == null || used == null || total == 0) continue;
    final fs = f[0], mount = f.sublist(5).join(' ');
    if (_skipFs.contains(fs) || fs.startsWith('/dev/loop')) continue;
    if (_systemMounts.any((m) => mount == m || mount.startsWith('$m/'))) continue;
    // A device mounted twice (bind mounts) counts once.
    if (!seen.add(fs)) continue;
    disks.add(Disk(mount, used, total));
  }

  final gpus = <Gpu>[];
  for (final line in of('gpu')) {
    final f = line.split(',').map((s) => s.trim()).toList();
    if (f.length < 5) continue;
    // A name may itself contain commas, so the numbers are read from the end.
    double? n(int fromEnd) => double.tryParse(f[f.length - fromEnd]);
    final util = n(4);
    gpus.add(
      Gpu(
        f.sublist(0, f.length - 4).join(', '),
        utilization: util == null ? null : (util / 100).clamp(0.0, 1.0),
        memoryUsedMib: n(3)?.round(),
        memoryTotalMib: n(2)?.round(),
        temperature: n(1)?.round(),
      ),
    );
  }

  return StatsSample(
    cpu: cpu,
    memTotalKib: mem['MemTotal'] ?? 0,
    memAvailableKib: available,
    swapTotalKib: mem['SwapTotal'] ?? 0,
    swapFreeKib: mem['SwapFree'] ?? 0,
    load: load,
    uptime: upSeconds == null ? null : Duration(seconds: upSeconds.floor()),
    rxBytes: rx,
    txBytes: tx,
    cores: int.tryParse(of('cpus').firstOrNull ?? ''),
    disks: disks,
    gpus: gpus,
  );
}

/// Rates between [previous] and [current], taken [elapsed] apart. Counters that went backwards (a reboot or a
/// wrapped interface counter) give no rate rather than a negative one.
StatsSnapshot diffStats(StatsSample? previous, StatsSample current, Duration elapsed) {
  if (previous == null || elapsed <= Duration.zero) return StatsSnapshot(current);
  double? cpu;
  final (a, b) = (previous.cpu, current.cpu);
  if (a != null && b != null && b.total > a.total && b.busy >= a.busy) {
    cpu = ((b.busy - a.busy) / (b.total - a.total)).clamp(0.0, 1.0);
  }
  final seconds = elapsed.inMicroseconds / 1e6;
  double? rate(int before, int after) => after >= before ? (after - before) / seconds : null;
  return StatsSnapshot(
    current,
    cpu: cpu,
    rxPerSecond: rate(previous.rxBytes, current.rxBytes),
    txPerSecond: rate(previous.txBytes, current.txBytes),
  );
}
