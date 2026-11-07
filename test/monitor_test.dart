import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/monitor/domain/stats.dart';

String sample({int user = 100, int idle = 900, int rx = 1000, int tx = 500, String gpu = '', String df = ''}) =>
    '''
@@stat
cpu  $user 0 0 $idle 0 0 0 0 0 0
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
@@cpus
4
@@df
Filesystem     1024-blocks      Used Available Capacity Mounted on
$df
@@gpu
$gpu
@@end
''';

void main() {
  test('parses memory, load, uptime, cores and network', () {
    final s = parseStats(sample());
    expect(s.supported, isTrue);
    expect(s.memTotalKib, 2000000);
    expect(s.memAvailableKib, 500000);
    expect(s.load, [.52, .40, .31]);
    expect(s.uptime, const Duration(seconds: 93784));
    expect(s.cores, 4);
    expect(s.rxBytes, 1000, reason: 'lo is excluded');
    expect(s.txBytes, 500);
    final snap = diffStats(null, s, const Duration(seconds: 3));
    expect(snap.cpu, isNull);
    expect(snap.memory, closeTo(.75, 1e-9));
    expect(snap.swap, closeTo(.25, 1e-9));
  });

  test('cpu and network rates come from the difference of two samples', () {
    final a = parseStats(sample(user: 100, idle: 900, rx: 1000, tx: 500));
    final b = parseStats(sample(user: 150, idle: 950, rx: 4000, tx: 800));
    final snap = diffStats(a, b, const Duration(seconds: 3));
    expect(snap.cpu, closeTo(.5, 1e-9));
    expect(snap.rxPerSecond, closeTo(1000, 1e-9));
    expect(snap.txPerSecond, closeTo(100, 1e-9));
  });

  test('counters that went backwards give no rate', () {
    final a = parseStats(sample(user: 500, idle: 900, rx: 9000));
    final b = parseStats(sample(user: 100, idle: 100, rx: 10));
    final snap = diffStats(a, b, const Duration(seconds: 3));
    expect(snap.cpu, isNull);
    expect(snap.rxPerSecond, isNull);
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
  });

  test('parses nvidia-smi rows', () {
    final s = parseStats(
      sample(gpu: 'NVIDIA A10, 37, 2048, 24576, 61\nbroken line\nTesla, Rev 2, [N/A], 10, 20, [N/A]'),
    );
    expect(s.gpus, hasLength(2));
    expect(s.gpus.last.name, 'Tesla, Rev 2');
    expect(s.gpus.last.utilization, isNull);
    expect(s.gpus.last.memoryFraction, closeTo(.5, 1e-9));
    final g = s.gpus.first;
    expect(g.name, 'NVIDIA A10');
    expect(g.utilization, closeTo(.37, 1e-9));
    expect(g.memoryFraction, closeTo(2048 / 24576, 1e-9));
    expect(g.temperature, 61);
  });

  test('servers without /proc are unsupported', () {
    final s = parseStats('@@unsupported\n');
    expect(s.supported, isFalse);
  });

  test('the command is constant and read-only', () {
    expect(statsCommand, isNot(contains(RegExp(r'\brm\b|>\s*[^&/]|\bsudo\b|\bkill\b'))));
  });
}
