#ifndef SSHAIRY_DESKTOP_BRIDGE_H_
#define SSHAIRY_DESKTOP_BRIDGE_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

gboolean sshairy_renderer_preference(GApplication* application);
void sshairy_register_desktop_bridge(GtkWindow* window, FlView* view);

#endif  // SSHAIRY_DESKTOP_BRIDGE_H_
