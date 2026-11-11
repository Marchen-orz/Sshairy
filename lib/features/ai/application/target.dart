import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/ids.dart';

/// The app projects the focused SSH pane; a turn freezes it when sending.
final agentFocusedHostProvider = Provider<HostId?>((_) => null);
