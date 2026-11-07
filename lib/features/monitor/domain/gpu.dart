/// Graphics cards from nvidia-smi and amdgpu's sysfs (docs/MODULES.md §8).
library;

enum GpuVendor { nvidia, amd }

/// Who runs a process and its full command line, from `ps`.
typedef ProcessOwner = ({String user, String command});

/// The columns of `nvidia-smi --query-gpu`, in the order [parseGpus] reads them.
const nvidiaGpuFields =
    'index,uuid,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,power.limit,fan.speed,'
    'clocks.sm,clocks.mem';

class GpuProcess {
  const GpuProcess({required this.pid, required this.name, this.memoryBytes, this.user, this.command});

  final int pid;
  final String name;
  final int? memoryBytes;
  final String? user, command;
}

/// One card. Anything the driver does not report, such as `[N/A]` from nvidia-smi, is null.
class Gpu {
  const Gpu({
    required this.vendor,
    required this.id,
    required this.name,
    this.index,
    this.utilization,
    this.memoryUsedBytes,
    this.memoryTotalBytes,
    this.temperature,
    this.powerWatts,
    this.powerLimitWatts,
    this.fanPercent,
    this.fanRpm,
    this.coreClockMhz,
    this.memoryClockMhz,
    this.processes = const [],
  });

  final GpuVendor vendor;

  /// NVIDIA's UUID or AMD's PCI slot; stable across samples.
  final String id;
  final String name;
  final int? index;

  /// 0–1.
  final double? utilization;
  final int? memoryUsedBytes, memoryTotalBytes;

  /// Degrees Celsius.
  final double? temperature;
  final double? powerWatts, powerLimitWatts;
  final double? fanPercent;
  final int? fanRpm;
  final int? coreClockMhz, memoryClockMhz;
  final List<GpuProcess> processes;

  double? get memoryFraction {
    final (used, total) = (memoryUsedBytes, memoryTotalBytes);
    return used == null || total == null || total == 0 ? null : (used / total).clamp(0.0, 1.0);
  }
}

String _basename(String path) => path.split('/').where((s) => s.isNotEmpty).lastOrNull ?? path;

/// Cards from the `@@nvgpu`, `@@nvproc`, `@@amd` and `@@amdfd` sections; process names come from [names] and
/// owners from [owners] when the probe listed them.
List<Gpu> parseGpus(
  List<(String, List<String>)> sections, {
  Map<int, String> names = const {},
  Map<int, ProcessOwner> owners = const {},
}) {
  List<String> of(String name) => [
    for (final (n, lines) in sections)
      if (n == name) ...lines,
  ];
  GpuProcess process(int pid, String fallbackName, int? memory, [String? command]) {
    final owner = owners[pid];
    return GpuProcess(
      pid: pid,
      name: names[pid] ?? fallbackName,
      memoryBytes: memory,
      user: owner?.user,
      command: owner?.command ?? command,
    );
  }

  final gpus = <Gpu>[];

  final apps = <String, List<GpuProcess>>{};
  for (final line in of('nvproc')) {
    final f = line.split(',').map((s) => s.trim()).toList();
    if (f.length < 4) continue;
    final pid = int.tryParse(f[0]);
    if (pid == null) continue;
    final memory = double.tryParse(f[1]);
    // The name may itself contain commas, so it is everything after the UUID.
    final path = f.sublist(3).join(', ');
    (apps[f[2]] ??= []).add(process(pid, _basename(path), memory == null ? null : (memory * 1048576).round(), path));
  }
  for (final line in of('nvgpu')) {
    final f = line.split(',').map((s) => s.trim()).toList();
    if (f.length < 12) continue;
    // A name with commas widens the row; the nine numbers after it are read from the end.
    double? n(int fromEnd) => double.tryParse(f[f.length - fromEnd]);
    final name = f.sublist(2, f.length - 9).join(', ');
    final (util, used, total) = (n(9), n(8), n(7));
    gpus.add(
      Gpu(
        vendor: GpuVendor.nvidia,
        id: f[1],
        index: int.tryParse(f[0]),
        name: name,
        utilization: util == null ? null : (util / 100).clamp(0.0, 1.0),
        memoryUsedBytes: used == null ? null : (used * 1048576).round(),
        memoryTotalBytes: total == null ? null : (total * 1048576).round(),
        temperature: n(6),
        powerWatts: n(5),
        powerLimitWatts: n(4),
        fanPercent: n(3),
        coreClockMhz: n(2)?.round(),
        memoryClockMhz: n(1)?.round(),
        processes: [...?apps[f[1]]]..sort((a, b) => (b.memoryBytes ?? 0).compareTo(a.memoryBytes ?? 0)),
      ),
    );
  }

  // amdgpu clients: one fdinfo per open file, several of which may share a client id; vram is summed per client.
  final files = <(int, String), Map<String, String>>{};
  for (final line in of('amdfd')) {
    final m = RegExp(r'^/proc/(\d+)/fdinfo/(\d+):(drm-[a-z-]+):\s*(.*)$').firstMatch(line);
    if (m != null) (files[(int.parse(m[1]!), m[2]!)] ??= {})[m[3]!] = m[4]!;
  }
  final clients = <String, Map<int, int?>>{};
  final counted = <(int, String, String)>{};
  for (final MapEntry(key: (pid, _), value: keys) in files.entries) {
    final slot = keys['drm-pdev'];
    if (keys['drm-driver'] != 'amdgpu' || slot == null) continue;
    if (!counted.add((pid, slot, keys['drm-client-id'] ?? ''))) continue;
    final vram = RegExp(r'^(\d+)\s*(\w*)').firstMatch(keys['drm-memory-vram'] ?? '');
    final unit = switch (vram?[2]) {
      'KiB' => 1024,
      'MiB' => 1048576,
      'GiB' => 1 << 30,
      _ => 1,
    };
    final bytes = vram == null ? null : int.parse(vram[1]!) * unit;
    final perPid = clients[slot] ??= {};
    perPid[pid] = bytes == null ? perPid[pid] : (perPid[pid] ?? 0) + bytes;
  }

  var amdIndex = 0;
  for (final (name, lines) in sections) {
    if (name != 'amd') continue;
    final v = <String, String>{
      for (final line in lines)
        if (line.indexOf('=') case final i when i > 0) line.substring(0, i): line.substring(i + 1).trim(),
    };
    final slot = v['slot'] ?? '';
    int? number(String key) => int.tryParse(v[key] ?? '');
    int? mhz(String key) =>
        int.tryParse(RegExp(r'(\d+)\s*Mhz', caseSensitive: false).firstMatch(v[key] ?? '')?[1] ?? '');
    // lspci: "03:00.0 VGA compatible controller: Advanced Micro Devices, Inc. [AMD/ATI] Navi 21 [...]".
    final described = v['name'] ?? '';
    final colon = described.indexOf(': ');
    final model = colon < 0
        ? ''
        : described
              .substring(colon + 2)
              .replaceFirst('Advanced Micro Devices, Inc. ', '')
              .replaceFirst('[AMD/ATI] ', '');
    final busy = number('gpu_busy_percent');
    final power = number('power1_average') ?? number('power1_input');
    final cap = number('power1_cap');
    final temp = number('temp1_input');
    gpus.add(
      Gpu(
        vendor: GpuVendor.amd,
        id: slot,
        index: amdIndex++,
        name: model.isEmpty ? 'AMD GPU' : 'AMD $model',
        utilization: busy == null ? null : (busy / 100).clamp(0.0, 1.0),
        memoryUsedBytes: number('mem_info_vram_used'),
        memoryTotalBytes: number('mem_info_vram_total'),
        temperature: temp == null ? null : temp / 1000,
        powerWatts: power == null ? null : power / 1e6,
        powerLimitWatts: cap == null || cap == 0 ? null : cap / 1e6,
        fanRpm: number('fan1_input'),
        coreClockMhz: mhz('sclk'),
        memoryClockMhz: mhz('mclk'),
        processes: [
          for (final MapEntry(key: pid, value: bytes) in (clients[slot] ?? const <int, int?>{}).entries)
            process(pid, '$pid', bytes),
        ]..sort((a, b) => (b.memoryBytes ?? 0).compareTo(a.memoryBytes ?? 0)),
      ),
    );
  }
  return gpus;
}
