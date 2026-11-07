import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/monitor/domain/stats.dart';

String sample({
  int user = 100,
  int idle = 900,
  int rx = 1000,
  int tx = 500,
  String cores = 'cpu0 50 0 0 450 0 0 0 0 0 0\ncpu1 50 0 0 450 0 0 0 0 0 0',
  String proc = '',
  String gpus = '',
  String extra = '',
  String df = '',
}) =>
    '''
@@stat
cpu  $user 0 0 $idle 0 0 0 0 0 0
$cores
@@mem
MemTotal:        2000000 kB
MemFree:          100000 kB
MemAvailable:     500000 kB
SwapTotal:       1000000 kB
SwapFree:         750000 kB
@@load
0.52 0.40 0.31 1/123 4567
@@up
93784.12 180000.00
@@net
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 99999 10 0 0 0 0 0 0 99999 10 0 0 0 0 0 0
  eth0: $rx 10 0 0 0 0 0 0 $tx 10 0 0 0 0 0 0
  eth1: 10 1 0 0 0 0 0 0 20 1 0 0 0 0 0 0
@@conf
4096
100
@@df
Filesystem     1024-blocks      Used Available Capacity Mounted on
$df
@@proc
$proc
@@gpus
$gpus
$extra
''';

void main() {
  test('parses memory, load, uptime, cores and network', () {
    final s = parseStats(sample());
    expect(s.supported, isTrue);
    expect(s.memTotalKib, 2000000);
    expect(s.memAvailableKib, 500000);
    expect(s.load, [.52, .40, .31]);
    expect(s.tasks, 123);
    expect(s.uptime, const Duration(seconds: 93784));
    expect(s.cores, 2);
    expect(s.rxBytes, 1010, reason: 'lo is excluded');
    expect(s.txBytes, 520);
    expect(s.interfaces.keys, ['lo', 'eth0', 'eth1']);
    final snap = diffStats(null, s, const Duration(seconds: 3));
    expect(snap.cpu, isNull);
    expect(snap.memory, closeTo(.75, 1e-9));
    expect(snap.swap, closeTo(.25, 1e-9));
  });

  test('cpu, cores and network rates come from the difference of two samples', () {
    final a = parseStats(sample(user: 100, idle: 900, rx: 1000, tx: 500));
    final b = parseStats(
      sample(
        user: 150,
        idle: 950,
        rx: 4000,
        tx: 800,
        cores: 'cpu0 100 0 0 450 0 0 0 0 0 0\ncpu1 50 0 0 500 0 0 0 0 0 0',
      ),
    );
    final snap = diffStats(a, b, const Duration(seconds: 3));
    expect(snap.cpu, closeTo(.5, 1e-9));
    expect(snap.coreUsage, [1.0, 0.0]);
    expect(snap.rxPerSecond, closeTo(1000, 1e-9));
    expect(snap.txPerSecond, closeTo(100, 1e-9));
    expect(snap.interfaceRates.keys, ['eth0', 'eth1'], reason: 'lo is left out');
    expect(snap.interfaceRates['eth0']!.rx, closeTo(1000, 1e-9));
    expect(snap.interfaceRates['eth1']!.rx, 0);
  });

  test('counters that went backwards give no rate', () {
    final a = parseStats(sample(user: 500, idle: 900, rx: 9000));
    final b = parseStats(sample(user: 100, idle: 100, rx: 10));
    final snap = diffStats(a, b, const Duration(seconds: 3));
    expect(snap.cpu, isNull);
    expect(snap.rxPerSecond, isNull);
    expect(snap.interfaceRates.containsKey('eth0'), isFalse);
  });

  test('disks skip pseudo filesystems, snaps and bind mounts', () {
    final s = parseStats(
      sample(
        df: [
          '/dev/vda2        41152812  20576406  18663036      53% /',
          'tmpfs              201000      1000    200000       1% /run',
          '/dev/loop0          65536     65536         0     100% /snap/core/1',
          '/dev/vda2        41152812  20576406  18663036      53% /var/lib/docker',
          '/dev/vdb1       104857600  10485760  94371840      10% /data disk',
        ].join('\n'),
      ),
    );
    expect(s.disks.map((d) => d.mount), ['/', '/data disk']);
    expect(s.disks.first.fraction, closeTo(.5, .01));
    expect(s.disks.first.availableKib, 18663036, reason: 'df reserves blocks for root, so free is not size - used');
  });

  group('processes', () {
    // pid state ppid ticks threads start resident-pages name, as the awk fragment prints them.
    const before =
        '1 S 0 500 1 1 3000 systemd\n'
        '2 S 0 0 1 1 0 kthreadd\n'
        '30 I 2 900 1 5 0 kworker/0:1\n'
        '400 S 1 1000 12 9000 25600 my (odd) app\n'
        '500 R 1 2000 1 9100 512 busy';
    const after =
        '1 S 0 500 1 1 3000 systemd\n'
        '2 S 0 0 1 1 0 kthreadd\n'
        '30 I 2 990 1 5 0 kworker/0:1\n'
        '400 S 1 1050 12 9000 25600 my (odd) app\n'
        '500 R 1 50 1 9300 512 busy\n'
        '600 S 1 10 1 9350 256 new';

    test('cpu is per core as in top; a reused pid or a new process has none yet', () {
      // 200 ticks across two cores in the interval: 100 ticks is one core.
      final a = parseStats(sample(user: 100, idle: 900, proc: before));
      final b = parseStats(sample(user: 250, idle: 950, proc: after));
      final snap = diffStats(a, b, const Duration(seconds: 1));
      final byPid = {for (final p in snap.processes) p.pid: p};
      expect(byPid.keys, unorderedEquals([1, 400, 500, 600]), reason: 'kernel threads are left out');
      expect(byPid[1]!.cpu, 0);
      expect(byPid[400]!.cpu, closeTo(.5, 1e-9));
      expect(byPid[400]!.name, 'my (odd) app');
      expect(byPid[400]!.stat.threads, 12);
      expect(byPid[400]!.residentBytes, 25600 * 4096);
      expect(byPid[400]!.memory, closeTo(25600 * 4096 / (2000000 * 1024), 1e-9));
      expect(byPid[400]!.elapsed, const Duration(seconds: 93784 - 90));
      expect(byPid[500]!.cpu, isNull, reason: 'a different start time is a new process');
      expect(byPid[600]!.cpu, isNull);
      expect(snap.top(2).map((p) => p.pid), [400, 1], reason: 'busiest first, then by memory');
    });

    test('owners and command lines join by pid', () {
      final s = parseStats(
        sample(
          proc: before,
          extra: '@@ps\n    PID USER     COMMAND\n    400 www-data /usr/bin/my app --flag\n      1 root     /sbin/init',
        ),
      );
      final p = diffStats(null, s, Duration.zero).processes.firstWhere((p) => p.pid == 400);
      expect(p.owner?.user, 'www-data');
      expect(p.command, '/usr/bin/my app --flag');
      expect(s.owners.containsKey(0), isFalse, reason: 'the header is not a process');
    });
  });

  test('parses nvidia-smi cards and their compute processes', () {
    final s = parseStats(
      sample(
        gpus: 'nvidia',
        proc: '777 S 1 10 4 100 2560 python3',
        extra: [
          '@@ps',
          '  PID USER COMMAND',
          '  777 alice python3 train.py',
          '@@nvgpu',
          '0, GPU-aaa, NVIDIA A10, 37, 2048, 24576, 61, 85.31, 150.00, 30, 1695, 6251',
          'broken line',
          '1, GPU-bbb, Tesla, Rev 2, [N/A], 12288, 24576, [N/A], [N/A], [N/A], [N/A], [N/A], [N/A]',
          '@@nvproc',
          '777, 1800, GPU-aaa, /usr/bin/python3',
          '888, [N/A], GPU-aaa, /opt/x, y/app',
        ].join('\n'),
      ),
    );
    expect(s.gpuVendors, {GpuVendor.nvidia});
    expect(s.gpus, hasLength(2));
    final g = s.gpus.first;
    expect((g.vendor, g.index, g.id, g.name), (GpuVendor.nvidia, 0, 'GPU-aaa', 'NVIDIA A10'));
    expect(g.utilization, closeTo(.37, 1e-9));
    expect(g.memoryFraction, closeTo(2048 / 24576, 1e-9));
    expect((g.temperature, g.powerWatts, g.powerLimitWatts, g.fanPercent), (61, 85.31, 150, 30));
    expect((g.coreClockMhz, g.memoryClockMhz), (1695, 6251));
    expect(g.processes.map((p) => (p.pid, p.name, p.memoryBytes, p.user)), [
      (777, 'python3', 1800 * 1048576, 'alice'),
      (888, 'app', null, null),
    ]);
    expect(g.processes.last.command, '/opt/x, y/app');
    final t = s.gpus.last;
    expect(t.name, 'Tesla, Rev 2');
    expect(t.utilization, isNull);
    expect(t.memoryFraction, closeTo(.5, 1e-9));
    expect(t.processes, isEmpty);
  });

  test('parses amdgpu sysfs and sums each client once', () {
    final s = parseStats(
      sample(
        gpus: 'amd',
        proc: '900 S 1 10 4 100 2560 blender',
        extra: [
          '@@amd',
          'slot=0000:03:00.0',
          'name=03:00.0 VGA compatible controller: Advanced Micro Devices, Inc. [AMD/ATI] Navi 21',
          'gpu_busy_percent=42',
          'mem_info_vram_used=1073741824',
          'mem_info_vram_total=17163091968',
          'sclk=1: 2100Mhz *',
          'mclk=',
          'temp1_input=55000',
          'power1_average=120000000',
          'power1_cap=255000000',
          'fan1_input=1100',
          '@@amdfd',
          '/proc/900/fdinfo/5:drm-driver:\tamdgpu',
          '/proc/900/fdinfo/5:drm-pdev:\t0000:03:00.0',
          '/proc/900/fdinfo/5:drm-client-id:\t12',
          '/proc/900/fdinfo/5:drm-memory-vram:\t524288 KiB',
          '/proc/900/fdinfo/6:drm-driver:\tamdgpu',
          '/proc/900/fdinfo/6:drm-pdev:\t0000:03:00.0',
          '/proc/900/fdinfo/6:drm-client-id:\t12',
          '/proc/900/fdinfo/6:drm-memory-vram:\t524288 KiB',
          '/proc/901/fdinfo/3:drm-driver:\ti915',
          '/proc/901/fdinfo/3:drm-pdev:\t0000:00:02.0',
        ].join('\n'),
      ),
    );
    expect(s.gpuVendors, {GpuVendor.amd});
    final g = s.gpus.single;
    expect((g.vendor, g.id, g.name), (GpuVendor.amd, '0000:03:00.0', 'AMD Navi 21'));
    expect(g.utilization, closeTo(.42, 1e-9));
    expect(g.memoryUsedBytes, 1073741824);
    expect((g.temperature, g.powerWatts, g.powerLimitWatts, g.fanRpm), (55, 120, 255, 1100));
    expect((g.coreClockMhz, g.memoryClockMhz), (2100, null));
    expect(g.processes.map((p) => (p.pid, p.name, p.memoryBytes)), [(900, 'blender', 512 * 1048576)]);
  });

  test('servers without /proc are unsupported', () {
    final s = parseStats('@@unsupported\n');
    expect(s.supported, isFalse);
  });

  test('every variant of the command is built from constants and only reads', () {
    for (final processes in [false, true]) {
      for (final gpu in [false, true]) {
        final command = statsCommand(processes: processes, gpu: gpu);
        expect(command, startsWith("sh -c '"));
        expect(command, isNot(contains(RegExp(r'\brm\b|>\s*[^&/=]|\bsudo\b|\bkill\b|\btee\b|\bdd\b'))));
        expect(command.contains('@@ps'), processes || gpu);
        expect(command.contains('@@nvgpu'), gpu);
      }
    }
  });
}
