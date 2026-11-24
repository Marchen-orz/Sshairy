import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/scrolling.dart';
import 'package:sshairy/design/sidebar_frame.dart';
import 'package:sshairy/design/theme.dart';
import 'package:sshairy/features/workspace/presentation/workspace_page.dart';

class _MonitorProbe extends StatefulWidget {
  const _MonitorProbe(this.log, {super.key});

  final List<String> log;

  @override
  State<_MonitorProbe> createState() => _MonitorProbeState();
}

class _MonitorProbeState extends State<_MonitorProbe> {
  var samples = 0;

  @override
  void initState() {
    super.initState();
    widget.log.add('+monitor');
  }

  @override
  void dispose() {
    widget.log.add('-monitor');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(color: Colors.transparent, child: Text('samples:$samples'));
}

void main() {
  test('effectiveWindowWidth ignores iconic and zero sizes but follows real resizes', () {
    expect(WorkspacePage.effectiveWindowWidth(0, const Size(1400, 800)), 1400);
    // Win32 WM_NCCALCSIZE minimized iconic bar (~160x28) and collapsed 0x0 frames.
    expect(WorkspacePage.effectiveWindowWidth(1400, const Size(160, 28)), 1400);
    expect(WorkspacePage.effectiveWindowWidth(1400, Size.zero), 1400);
    expect(WorkspacePage.effectiveWindowWidth(1400, const Size(319, 800)), 1400);
    expect(WorkspacePage.effectiveWindowWidth(1400, const Size(1400, 199)), 1400);
    // Genuine narrow and wide desktop resizes update normally.
    expect(WorkspacePage.effectiveWindowWidth(1400, const Size(960, 700)), 960);
    expect(WorkspacePage.effectiveWindowWidth(960, const Size(1360, 800)), 1360);
  });

  testWidgets('minimizing to iconic size and restoring keeps monitor panel mounted without replaying animation', (
    tester,
  ) async {
    final log = <String>[];
    final probeKey = GlobalKey<_MonitorProbeState>();
    var windowWidth = 0.0;

    Future<void> pumpSize(Size size) async {
      tester.view.physicalSize = size;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        scrollBehavior: const AppScrollBehavior(),
        theme: buildTheme(Brightness.light).copyWith(platform: TargetPlatform.windows),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              windowWidth = WorkspacePage.effectiveWindowWidth(windowWidth, MediaQuery.sizeOf(context));
              final wide = windowWidth >= WorkspaceSize.wideBreakpoint;
              return SidebarFrame(
                width: WorkspaceSize.monitor,
                resizeLabel: 'Resize monitor',
                onResize: (_) {},
                sidebar: wide ? _MonitorProbe(log, key: probeKey) : null,
                child: const SizedBox.expand(),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(log, ['+monitor']);
    probeKey.currentState!.samples = 42;

    // Simulate minimize on Windows (iconic ~160x28, then 0x0) and restore back to wide desktop.
    await pumpSize(const Size(160, 28));
    await pumpSize(Size.zero);
    await pumpSize(const Size(1400, 800));
    await tester.pumpAndSettle();

    expect(log, ['+monitor']);
    expect(probeKey.currentState!.samples, 42);

    // A genuine narrow resize below wideBreakpoint still hides and unmounts the sidebar.
    await pumpSize(const Size(960, 700));
    await tester.pumpAndSettle();
    expect(log, ['+monitor', '-monitor']);

    // Widening back mounts a fresh sidebar.
    await pumpSize(const Size(1400, 800));
    await tester.pumpAndSettle();
    expect(log, ['+monitor', '-monitor', '+monitor']);
  });
}
