/// Parses the output of [statsCommand] and turns two samples into rates (docs/MODULES.md §8).
library;

import 'gpu.dart';

export 'gpu.dart';

/// Closes the single-quoted `sh -c` script, adds a quote and reopens it; the same in POSIX shells and fish.
const _quote = r"'\''";

/// One line per process from `/proc/<pid>/stat`: pid, state, ppid, utime + stime, threads, start time, resident
/// pages and the name, last because it may contain spaces. Everything up to the last ") " is the pid and name.
const _processes =
    'cat /proc/[0-9]*/stat 2>/dev/null | awk $_quote'
    '{ l = \$0; p = index(l, "("); s = l; sub(/.*[)] /, "", s); '
    'c = substr(l, p + 1, length(l) - length(s) - p - 2); '
    // mawk prints large sums in exponent form, so the CPU time goes through %.0f.
    'if (split(s, f, " ") >= 22) printf "%s %s %s %.0f %s %s %s %s\\n", \$1, f[1], f[2], f[12] + f[13], f[18], f[20], '
    'f[22], c }'
    '$_quote; ';

const _linux =
    'echo @@stat; grep ^cpu /proc/stat; '
    'echo @@mem; cat /proc/meminfo; '
    'echo @@load; cat /proc/loadavg; '
    'echo @@up; cat /proc/uptime; '
    'echo @@net; cat /proc/net/dev; '
    'echo @@conf; getconf PAGESIZE 2>/dev/null; getconf CLK_TCK 2>/dev/null; '
    'echo @@df; df -kPTl 2>/dev/null || df -kPl 2>/dev/null; '
    'echo @@proc; $_processes'
    'echo @@gpus; command -v nvidia-smi >/dev/null 2>&1 && echo nvidia; '
    'for d in /sys/class/drm/card[0-9]*; do case \$d in *-*) continue;; esac; '
    '[ "\$(cat \$d/device/vendor 2>/dev/null)" = 0x1002 ] && { echo amd; break; }; done; ';

/// Owners and full command lines, for the process window and the GPU page.
const _owners = 'echo @@ps; ps -eo pid,user:32,args --cols 600 2>/dev/null || ps -o pid,user,args 2>/dev/null; ';

const _nvidia =
    't=; command -v timeout >/dev/null 2>&1 && t="timeout 5"; '
    'if command -v nvidia-smi >/dev/null 2>&1; then '
    'echo @@nvgpu; \$t nvidia-smi --query-gpu=$nvidiaGpuFields --format=csv,noheader,nounits </dev/null 2>/dev/null; '
    'echo @@nvproc; \$t nvidia-smi --query-compute-apps=pid,used_memory,gpu_uuid,process_name '
    '--format=csv,noheader,nounits </dev/null 2>/dev/null; fi; ';

const _amd =
    'a=; for d in /sys/class/drm/card[0-9]*; do case \$d in *-*) continue;; esac; '
    '[ "\$(cat \$d/device/vendor 2>/dev/null)" = 0x1002 ] || continue; a=1; echo @@amd; '
    's=\$(sed -n "s/^PCI_SLOT_NAME=//p" \$d/device/uevent 2>/dev/null); echo "slot=\$s"; '
    'command -v lspci >/dev/null 2>&1 && echo "name=\$(lspci -s "\$s" </dev/null 2>/dev/null | head -n 1)"; '
    'for f in gpu_busy_percent mem_info_vram_used mem_info_vram_total; do '
    '[ -r \$d/device/\$f ] && echo "\$f=\$(cat \$d/device/\$f 2>/dev/null)"; done; '
    'echo "sclk=\$(grep "[*]" \$d/device/pp_dpm_sclk 2>/dev/null)"; '
    'echo "mclk=\$(grep "[*]" \$d/device/pp_dpm_mclk 2>/dev/null)"; '
    'for h in \$d/device/hwmon/hwmon*; do for f in temp1_input power1_average power1_input power1_cap fan1_input; do '
    '[ -r \$h/\$f ] && echo "\$f=\$(cat \$h/\$f 2>/dev/null)"; done; done; done; '
    'if [ -n "\$a" ]; then echo @@amdfd; '
    'grep -s -H -E "^drm-(driver|client-id|pdev|memory-vram):" /proc/[0-9]*/fdinfo/* 2>/dev/null; fi; ';

/// macOS has no `/proc`, so the same readings come from sysctl, vm_stat, netstat and ps and are converted into
/// the units [parseStats] expects. `rss` is reported in 1024-byte pages, matching the @@conf written here, and
/// ps cannot report thread counts, so those stay 0 (shown as unknown). Graphics cards are not probed.
const _darwin =
    'boot=\$(sysctl -n kern.boottime 2>/dev/null | sed -n $_quote'
    's/.* sec = \\([0-9]*\\),.*/\\1/p'
    '$_quote); up=\$(( \$(date +%s) - \${boot:-0} )); '
    'echo @@stat; sysctl -n kern.cp_time 2>/dev/null | awk $_quote'
    '{ printf "cpu "; for (i = 1; i <= NF; i++) printf "%s ", \$i; print "" }'
    '$_quote; '
    'echo @@mem; '
    'sysctl -n hw.memsize 2>/dev/null | awk $_quote'
    '{ if (\$1 ~ /^[0-9]+\$/) printf "MemTotal: %d kB\\n", \$1 / 1024 }'
    '$_quote; '
    'vm_stat 2>/dev/null | awk $_quote'
    'function n(v) { gsub(/[^0-9]/, "", v); return v + 0 } '
    '/^Mach Virtual Memory/ { page = n(\$8) } '
    '/^Pages free:/ { free = n(\$3) } '
    '/^Pages inactive:/ { inactive = n(\$3) } '
    '/^Pages speculative:/ { spec = n(\$3) } '
    'END { if (page >= 1) printf "MemAvailable: %d kB\\n", (free + inactive + spec) * page / 1024 }'
    '$_quote; '
    'sysctl -n vm.swapusage 2>/dev/null | awk $_quote'
    'function k(v) { u = substr(v, length(v), 1); x = substr(v, 1, length(v) - 1) + 0; '
    'if (u == "G") return x * 1048576; if (u == "M") return x * 1024; if (u == "K") return x; return x / 1024 } '
    '{ gsub(/=/, ""); for (i = 1; i < NF; i++) { if (\$i == "total") t = \$(i + 1); '
    'else if (\$i == "free") f = \$(i + 1) } } '
    'END { if (t != "") printf "SwapTotal: %d kB\\nSwapFree: %d kB\\n", k(t), k(f) }'
    '$_quote; '
    'echo @@load; sysctl -n vm.loadavg 2>/dev/null | awk $_quote'
    '{ gsub(/[{}]/, ""); if (NF >= 3) print \$1, \$2, \$3 }'
    '$_quote; '
    'echo @@up; echo "\$up 0"; '
    'echo @@net; netstat -ibn 2>/dev/null | awk $_quote'
    'NR == 1 { for (i = 1; i <= NF; i++) { if (\$i == "Name") name = i; else if (\$i == "Ibytes") rx = i; '
    'else if (\$i == "Obytes") tx = i } next } '
    'name && rx && tx && NF >= tx { if (seen[\$name]++) next; '
    'printf "%s: %s 0 0 0 0 0 0 0 %s\\n", \$name, \$rx, \$tx }'
    '$_quote; '
    'echo @@conf; echo 1024; '
    'sysctl -n kern.clockrate 2>/dev/null | sed -n $_quote'
    's/.*hz = \\([0-9]*\\).*/\\1/p'
    '$_quote; '
    'echo @@df; df -kP 2>/dev/null; '
    'echo @@proc; '
    'ps -axo pid=,state=,ppid=,time=,rss=,etime=,comm= 2>/dev/null | awk -v up="\$up" $_quote'
    'function secs(t, p, n, s) { gsub(/-/, ":", t); n = split(t, p, ":"); s = p[n] + 0; '
    'if (n >= 2) s += p[n - 1] * 60; if (n >= 3) s += p[n - 2] * 3600; if (n >= 4) s += p[n - 3] * 86400; return s } '
    '{ name = \$7; for (i = 8; i <= NF; i++) name = name " " \$i; et = secs(\$6); '
    'start = int((up - et) * 100); if (start < 0) start = 0; '
    'printf "%d %s %d %d 0 %d %d %s\\n", \$1, \$2, \$3, int(secs(\$4) * 100), start, \$5, name }'
    '$_quote; ';

/// Owners and full command lines for the process window; BSD ps needs `-ww` to keep them untruncated.
const _darwinOwners = 'echo @@ps; ps axww -o pid=,user=,args= 2>/dev/null; ';

/// A read-only probe built only from the constant fragments above; nothing from hosts, paths or users is ever
/// spliced in. It runs under `sh -c` so it behaves the same whatever the login shell, and `df -l` keeps network
/// mounts, which can hang, out of it. [processes] adds owners and command lines; [gpu] adds the graphics queries.
/// Linux and macOS are covered; any other system reports @@unsupported.
String statsCommand({bool processes = false, bool gpu = false}) =>
    "sh -c 'export LC_ALL=C; if [ -r /proc/stat ]; then $_linux${processes || gpu ? _owners : ''}"
    "${gpu ? '$_nvidia$_amd' : ''}"
    "elif [ \"\$(uname -s)\" = Darwin ]; then $_darwin${processes || gpu ? _darwinOwners : ''}"
    "else echo @@unsupported; fi'";

class CpuTimes {
  const CpuTimes(this.busy, this.total);
  final int busy, total;
}

class Disk {
  const Disk(this.mount, this.usedKib, this.totalKib, [int? availableKib, this.device = '', this.fsType = ''])
    : availableKib = availableKib ?? totalKib - usedKib;
  final String mount, device, fsType;
  final int usedKib, totalKib, availableKib;
  double get fraction => totalKib == 0 ? 0 : usedKib / totalKib;
}

class NetCounters {
  const NetCounters(this.rx, this.tx);
  final int rx, tx;
}

/// One `/proc/<pid>/stat` line; times are in clock ticks and memory in pages.
class ProcessStat {
  const ProcessStat({
    required this.pid,
    required this.state,
    required this.ppid,
    required this.ticks,
    required this.threads,
    required this.start,
    required this.residentPages,
    required this.name,
  });

  final int pid, ppid, ticks, threads, start, residentPages;
  final String state, name;

  /// Kernel threads are children of kthreadd (pid 2); like htop, the views leave them out.
  bool get kernel => pid == 2 || ppid == 2;
}

/// One reading of the server; counters are cumulative, so rates need the previous sample.
class StatsSample {
  const StatsSample({
    required this.cpu,
    this.coreTimes = const [],
    required this.memTotalKib,
    required this.memAvailableKib,
    required this.swapTotalKib,
    required this.swapFreeKib,
    required this.load,
    this.tasks,
    required this.uptime,
    this.interfaces = const {},
    this.pageSize = 4096,
    this.clockTicks = 100,
    required this.disks,
    this.processes = const {},
    this.owners = const {},
    this.gpuVendors = const {},
    this.gpus = const [],
  });

  final CpuTimes? cpu;
  final List<CpuTimes> coreTimes;
  final int memTotalKib, memAvailableKib, swapTotalKib, swapFreeKib;
  final List<double> load;

  /// The total from /proc/loadavg's running/total field.
  final int? tasks;
  final Duration? uptime;

  /// By interface name, `lo` included.
  final Map<String, NetCounters> interfaces;
  final int pageSize, clockTicks;
  final List<Disk> disks;
  final Map<int, ProcessStat> processes;

  /// Only when the probe asked for them.
  final Map<int, ProcessOwner> owners;

  /// Found by the cheap probe; [gpus] is filled only when the graphics queries ran.
  final Set<GpuVendor> gpuVendors;
  final List<Gpu> gpus;

  int? get cores => coreTimes.isEmpty ? null : coreTimes.length;

  int get rxBytes => interfaces.entries.where((e) => e.key != 'lo').fold(0, (a, e) => a + e.value.rx);
  int get txBytes => interfaces.entries.where((e) => e.key != 'lo').fold(0, (a, e) => a + e.value.tx);

  /// False when the server has no /proc, such as macOS or the BSDs.
  bool get supported => cpu != null && memTotalKib > 0;
}

/// A process as the views show it: [sample]'s reading joined with its owner and its CPU since the last sample.
class ProcessInfo {
  const ProcessInfo({
    required this.stat,
    required this.residentBytes,
    required this.memory,
    this.cpu,
    this.elapsed,
    this.owner,
  });

  final ProcessStat stat;
  final int residentBytes;

  /// Share of physical memory, 0–1.
  final double memory;

  /// Top's measure: 1 is one core busy all the time, so a busy multithreaded process can pass 1. Null for the
  /// first sample and for processes started since the previous one.
  final double? cpu;
  final Duration? elapsed;
  final ProcessOwner? owner;

  int get pid => stat.pid;
  String get name => stat.name;
  String get command => owner?.command ?? stat.name;
}

/// What the panel shows: [sample] plus rates since the one before it.
class StatsSnapshot {
  const StatsSnapshot(
    this.sample, {
    this.cpu,
    this.coreUsage = const [],
    this.rxPerSecond,
    this.txPerSecond,
    this.interfaceRates = const {},
    this.processes = const [],
  });
  final StatsSample sample;

  /// 0–1; null for the first sample.
  final double? cpu;

  /// Per core, 0–1; empty for the first sample.
  final List<double> coreUsage;
  final double? rxPerSecond, txPerSecond;

  /// Bytes per second by interface, `lo` left out.
  final Map<String, ({double rx, double tx})> interfaceRates;

  /// Every process but kernel threads, in no particular order.
  final List<ProcessInfo> processes;

  double get memory {
    final s = sample;
    return s.memTotalKib == 0 ? 0 : ((s.memTotalKib - s.memAvailableKib) / s.memTotalKib).clamp(0.0, 1.0);
  }

  double get swap {
    final s = sample;
    return s.swapTotalKib == 0 ? 0 : ((s.swapTotalKib - s.swapFreeKib) / s.swapTotalKib).clamp(0.0, 1.0);
  }

  /// The busiest processes for the panel: by CPU, then by memory, which orders an idle server meaningfully.
  List<ProcessInfo> top(int count) => (List.of(processes)..sort(compareBusy)).take(count).toList();

  static int compareBusy(ProcessInfo a, ProcessInfo b) {
    final c = (b.cpu ?? 0).compareTo(a.cpu ?? 0);
    return c != 0 ? c : b.residentBytes.compareTo(a.residentBytes);
  }
}

const _skipFs = {
  'tmpfs',
  'devtmpfs',
  'overlay',
  'squashfs',
  'udev',
  'none',
  'shm',
  'efivarfs',
  'proc',
  'sysfs',
  'devpts',
  'cgroup',
  'cgroup2',
  'securityfs',
  'debugfs',
  'tracefs',
  'pstore',
  'ramfs',
  'hugetlbfs',
  'fusectl',
  'mqueue',
  'autofs',
  'binfmt_misc',
  'rpc_pipefs',
  'nsfs',
  'bpf',
  'configfs',
};
const _systemMounts = ['/dev', '/run', '/sys', '/proc', '/snap'];
final _space = RegExp(r'\s+');

/// The probe's output by section; a section may repeat, as `@@amd` does once per card.
List<(String, List<String>)> splitSections(String output) {
  final sections = <(String, List<String>)>[];
  for (final raw in output.split('\n')) {
    final line = raw.trimRight();
    if (line.startsWith('@@')) {
      sections.add((line.substring(2), []));
    } else if (sections.isNotEmpty && line.isNotEmpty) {
      sections.last.$2.add(line);
    }
  }
  return sections;
}

CpuTimes? _cpuTimes(String line) {
  final n = line.split(_space).skip(1).map(int.tryParse).whereType<int>().toList();
  if (n.length < 4) return null;
  // user nice system idle iowait irq softirq steal; guest time is already inside user and nice.
  final total = n.take(8).fold(0, (a, b) => a + b);
  final idle = n[3] + (n.length > 4 ? n[4] : 0);
  return CpuTimes(total - idle, total);
}

StatsSample parseStats(String output) {
  final sections = splitSections(output);
  List<String> of(String name) => [
    for (final (n, lines) in sections)
      if (n == name) ...lines,
  ];

  CpuTimes? cpu;
  final cores = <CpuTimes>[];
  for (final line in of('stat')) {
    if (line.startsWith('cpu ')) {
      cpu = _cpuTimes(line);
    } else if (RegExp(r'^cpu\d+ ').hasMatch(line)) {
      if (_cpuTimes(line) case final t?) cores.add(t);
    }
  }

  final mem = <String, int>{};
  for (final line in of('mem')) {
    final m = RegExp(r'^(\w+):\s+(\d+)').firstMatch(line);
    if (m != null) mem[m[1]!] = int.parse(m[2]!);
  }
  final available = mem['MemAvailable'] ?? (mem['MemFree'] ?? 0) + (mem['Buffers'] ?? 0) + (mem['Cached'] ?? 0);

  final loadFields = (of('load').firstOrNull ?? '').split(_space);
  final load = loadFields.take(3).map(double.tryParse).whereType<double>().toList();
  final tasks = loadFields.length > 3 ? int.tryParse(loadFields[3].split('/').last) : null;

  final upSeconds = double.tryParse((of('up').firstOrNull ?? '').split(_space).first);

  final interfaces = <String, NetCounters>{};
  for (final line in of('net')) {
    final colon = line.indexOf(':');
    if (colon < 0) continue;
    final name = line.substring(0, colon).trim();
    final n = line.substring(colon + 1).trim().split(_space).map(int.tryParse).toList();
    if (name.isNotEmpty && n.length >= 9 && n[0] != null && n[8] != null) interfaces[name] = NetCounters(n[0]!, n[8]!);
  }

  final conf = of('conf');
  final pageSize = conf.isNotEmpty ? int.tryParse(conf[0].trim()) : null;
  final clockTicks = conf.length > 1 ? int.tryParse(conf[1].trim()) : null;

  final disks = <Disk>[];
  final seen = <String>{};
  for (final line in of('df')) {
    final f = line.trim().split(_space);
    if (f.length < 6) continue;
    final typed = int.tryParse(f[1]) == null;
    final offset = typed ? 1 : 0;
    if (f.length < 6 + offset) continue;
    final total = int.tryParse(f[1 + offset]), used = int.tryParse(f[2 + offset]), free = int.tryParse(f[3 + offset]);
    if (total == null || used == null || total <= 0) continue;
    final fs = f[0], type = typed ? f[1] : '', mount = f.sublist(5 + offset).join(' ');
    if (_skipFs.contains(fs) || _skipFs.contains(type) || fs.startsWith('/dev/loop')) continue;
    // Real data volumes can live under /run/media; filter by type when df provides it.
    if (!typed && !fs.startsWith('/dev/') && _systemMounts.any((m) => mount == m || mount.startsWith('$m/'))) continue;
    // A device mounted twice (bind mounts) counts once.
    if (!seen.add(fs)) continue;
    disks.add(Disk(mount, used, total, free, fs, type));
  }

  final processes = <int, ProcessStat>{};
  for (final line in of('proc')) {
    final f = line.split(' ');
    if (f.length < 8) continue;
    final n = [
      for (final i in [0, 2, 3, 4, 5, 6]) int.tryParse(f[i]),
    ];
    if (n.contains(null)) continue;
    processes[n[0]!] = ProcessStat(
      pid: n[0]!,
      state: f[1],
      ppid: n[1]!,
      ticks: n[2]!,
      threads: n[3]!,
      start: n[4]!,
      residentPages: n[5]!,
      name: f.sublist(7).join(' '),
    );
  }

  final owners = <int, ProcessOwner>{};
  for (final line in of('ps')) {
    final m = RegExp(r'^\s*(\d+)\s+(\S+)\s*(.*)$').firstMatch(line);
    if (m != null) owners[int.parse(m[1]!)] = (user: m[2]!, command: m[3]!);
  }

  final vendors = {for (final line in of('gpus')) ?GpuVendor.values.where((v) => v.name == line.trim()).firstOrNull};

  return StatsSample(
    cpu: cpu,
    coreTimes: cores,
    memTotalKib: mem['MemTotal'] ?? 0,
    memAvailableKib: available,
    swapTotalKib: mem['SwapTotal'] ?? 0,
    swapFreeKib: mem['SwapFree'] ?? 0,
    load: load,
    tasks: tasks,
    uptime: upSeconds == null ? null : Duration(seconds: upSeconds.floor()),
    interfaces: interfaces,
    pageSize: pageSize == null || pageSize <= 0 ? 4096 : pageSize,
    clockTicks: clockTicks == null || clockTicks <= 0 ? 100 : clockTicks,
    disks: disks,
    processes: processes,
    owners: owners,
    gpuVendors: vendors,
    gpus: parseGpus(sections, names: {for (final p in processes.values) p.pid: p.name}, owners: owners),
  );
}

/// Rates between [previous] and [current], taken [elapsed] apart. Counters that went backwards (a reboot or a
/// wrapped interface counter) give no rate rather than a negative one.
StatsSnapshot diffStats(StatsSample? previous, StatsSample current, Duration elapsed) {
  final memTotal = current.memTotalKib * 1024;
  final up = current.uptime;
  ProcessInfo info(ProcessStat p, double? cpu) {
    final resident = p.residentPages * current.pageSize;
    final elapsed = up == null ? null : up - Duration(milliseconds: p.start * 1000 ~/ current.clockTicks);
    return ProcessInfo(
      stat: p,
      residentBytes: resident,
      memory: memTotal == 0 ? 0 : (resident / memTotal).clamp(0.0, 1.0),
      cpu: cpu,
      elapsed: elapsed == null || elapsed.isNegative ? null : elapsed,
      owner: current.owners[p.pid],
    );
  }

  if (previous == null || elapsed <= Duration.zero) {
    return StatsSnapshot(
      current,
      processes: [
        for (final p in current.processes.values)
          if (!p.kernel) info(p, null),
      ],
    );
  }

  double? usage(CpuTimes? a, CpuTimes? b) => a != null && b != null && b.total > a.total && b.busy >= a.busy
      ? ((b.busy - a.busy) / (b.total - a.total)).clamp(0.0, 1.0)
      : null;
  final cpu = usage(previous.cpu, current.cpu);
  final cores = <double>[];
  if (previous.coreTimes.length == current.coreTimes.length) {
    for (var i = 0; i < current.coreTimes.length; i++) {
      cores.add(usage(previous.coreTimes[i], current.coreTimes[i]) ?? 0);
    }
  }

  final seconds = elapsed.inMicroseconds / 1e6;
  double? rate(int before, int after) => after >= before ? (after - before) / seconds : null;
  final rates = <String, ({double rx, double tx})>{};
  for (final MapEntry(key: name, value: now) in current.interfaces.entries) {
    final before = previous.interfaces[name];
    if (name == 'lo' || before == null) continue;
    final (rx, tx) = (rate(before.rx, now.rx), rate(before.tx, now.tx));
    if (rx != null && tx != null) rates[name] = (rx: rx, tx: tx);
  }

  // Ticks of all cores together; scaled by the core count so one busy core reads 1.
  final (a, b) = (previous.cpu, current.cpu);
  final ticks = a != null && b != null && b.total > a.total ? (b.total - a.total) / (current.cores ?? 1) : null;
  final processes = <ProcessInfo>[];
  for (final p in current.processes.values) {
    if (p.kernel) continue;
    final before = previous.processes[p.pid];
    // A different start time is a new process that reused the pid.
    final same = before != null && before.start == p.start && p.ticks >= before.ticks;
    processes.add(info(p, same && ticks != null ? (p.ticks - before.ticks) / ticks : null));
  }

  return StatsSnapshot(
    current,
    cpu: cpu,
    coreUsage: cores,
    rxPerSecond: rate(previous.rxBytes, current.rxBytes),
    txPerSecond: rate(previous.txBytes, current.txBytes),
    interfaceRates: rates,
    processes: processes,
  );
}
