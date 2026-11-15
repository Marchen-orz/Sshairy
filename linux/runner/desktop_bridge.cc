#include "desktop_bridge.h"

#include <glib/gstdio.h>

#include <cstring>

namespace {

struct DesktopBridge {
  GtkWindow* window;
  FlMethodChannel* channel;
  FlView* view;
  GdkEvent* last_button = nullptr;
  gint64 last_button_at = 0;
  bool initialized = false;
  bool edge_cursor = false;
};

FlValue* WindowState(DesktopBridge* bridge) {
  FlValue* state = fl_value_new_map();
  GdkWindow* native = gtk_widget_get_window(GTK_WIDGET(bridge->window));
  const GdkWindowState flags = native ? gdk_window_get_state(native) : GDK_WINDOW_STATE_WITHDRAWN;
  fl_value_set_string_take(state, "maximized", fl_value_new_bool((flags & GDK_WINDOW_STATE_MAXIMIZED) != 0));
  fl_value_set_string_take(state, "active", fl_value_new_bool(gtk_window_is_active(bridge->window)));
  fl_value_set_string_take(state, "maximizeHovered", fl_value_new_bool(FALSE));
  fl_value_set_string_take(state, "customChrome", fl_value_new_bool(TRUE));
  return state;
}

void NotifyState(DesktopBridge* bridge) {
  if (!bridge->initialized) return;
  g_autoptr(FlValue) state = WindowState(bridge);
  fl_method_channel_invoke_method(bridge->channel, "state", state, nullptr, nullptr, nullptr);
}

gboolean WindowStateChanged(GtkWidget*, GdkEventWindowState*, gpointer user_data) {
  NotifyState(static_cast<DesktopBridge*>(user_data));
  return FALSE;
}

void FocusChanged(GObject*, GParamSpec*, gpointer user_data) {
  NotifyState(static_cast<DesktopBridge*>(user_data));
}

gboolean CloseRequested(GtkWidget*, GdkEvent*, gpointer user_data) {
  auto* bridge = static_cast<DesktopBridge*>(user_data);
  if (!bridge->initialized) return FALSE;
  fl_method_channel_invoke_method(bridge->channel, "closeRequested", nullptr, nullptr, nullptr, nullptr);
  return TRUE;
}

void Respond(FlMethodCall* call, FlValue* value = nullptr) {
  fl_method_call_respond_success(call, value, nullptr);
}

void ClipboardUris(GtkClipboard*, gchar** uris, gpointer user_data) {
  g_autoptr(FlMethodCall) call = FL_METHOD_CALL(user_data);
  if (uris == nullptr) {
    g_autoptr(FlValue) empty = fl_value_new_list();
    Respond(call, empty);
    return;
  }
  const gsize count = g_strv_length(uris);
  if (count > 64) {
    fl_method_call_respond_error(call, "attachmentTooMany", "Too many attachments", nullptr, nullptr);
    return;
  }
  g_autoptr(FlValue) files = fl_value_new_list();
  for (gsize i = 0; i < count; ++i) {
    g_autofree gchar* hostname = nullptr;
    g_autoptr(GError) error = nullptr;
    g_autofree gchar* filename = g_filename_from_uri(uris[i], &hostname, &error);
    if (filename == nullptr || (hostname != nullptr && *hostname != '\0' && g_ascii_strcasecmp(hostname, "localhost") != 0)) {
      fl_method_call_respond_error(call, "attachmentUnreadable", "Invalid file clipboard entry", nullptr, nullptr);
      return;
    }
    g_autofree gchar* utf8 = g_filename_to_utf8(filename, -1, nullptr, nullptr, &error);
    if (utf8 == nullptr || !g_path_is_absolute(filename) || *utf8 == '\0' || g_utf8_strlen(utf8, -1) > 32767) {
      fl_method_call_respond_error(call, "attachmentUnreadable", "Invalid file clipboard entry", nullptr, nullptr);
      return;
    }
    fl_value_append_take(files, fl_value_new_string(utf8));
  }
  Respond(call, files);
}

FlValue* SystemFonts(GtkWindow* window) {
  PangoFontFamily** families = nullptr;
  int count = 0;
  pango_context_list_families(gtk_widget_get_pango_context(GTK_WIDGET(window)), &families, &count);
  g_autoptr(FlValue) fonts = fl_value_new_list();
  for (int i = 0; i < count; ++i) {
    g_autoptr(FlValue) font = fl_value_new_list();
    fl_value_append_take(font, fl_value_new_string(pango_font_family_get_name(families[i])));
    fl_value_append_take(font, fl_value_new_bool(pango_font_family_is_monospace(families[i])));
    fl_value_append(fonts, font);
  }
  g_free(families);
  return fl_value_ref(fonts);
}

bool SetBrandIcon(DesktopBridge* bridge, FlValue* args) {
  constexpr const char* themes[] = {"blue", "green", "violet", "orange", "deepSea", "pink"};
  constexpr guint32 light[] = {0xF1F7FFFF, 0xF1FAF6FF, 0xF7F3FDFF, 0xFFF7EEFF, 0xF0F6FCFF, 0xFFF4F8FF};
  constexpr guint32 night[] = {0x121418FF, 0x0C1916FF, 0x14111EFF, 0x1D1510FF, 0x0A131FFF, 0x1D121AFF};
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return false;
  FlValue* name = fl_value_lookup_string(args, "theme");
  FlValue* dark = fl_value_lookup_string(args, "dark");
  if (name == nullptr || fl_value_get_type(name) != FL_VALUE_TYPE_STRING || dark == nullptr || fl_value_get_type(dark) != FL_VALUE_TYPE_BOOL) return false;
  int index = -1;
  for (int i = 0; i < 6; ++i) if (strcmp(themes[i], fl_value_get_string(name)) == 0) index = i;
  if (index < 0) return false;
  g_autofree gchar* exe = g_file_read_link("/proc/self/exe", nullptr);
  if (exe == nullptr) return false;
  g_autofree gchar* directory = g_path_get_dirname(exe);
  g_autofree gchar* path = g_build_filename(directory, "data", "flutter_assets", "assets", "brand", themes[index], "mark.png", nullptr);
  g_autoptr(GdkPixbuf) mark = gdk_pixbuf_new_from_file(path, nullptr);
  if (mark == nullptr) return false;
  g_autoptr(GdkPixbuf) icon = gdk_pixbuf_new(GDK_COLORSPACE_RGB, TRUE, 8, 256, 256);
  gdk_pixbuf_fill(icon, fl_value_get_bool(dark) ? night[index] : light[index]);
  gdk_pixbuf_composite(mark, icon, 24, 50, 208, 156, 24, 50,
                       208.0 / gdk_pixbuf_get_width(mark), 156.0 / gdk_pixbuf_get_height(mark), GDK_INTERP_BILINEAR, 255);
  gtk_window_set_icon(bridge->window, icon);
  return true;
}

void MenuMinimize(GtkMenuItem*, gpointer data) { gtk_window_iconify(GTK_WINDOW(data)); }
void MenuMaximize(GtkMenuItem*, gpointer data) {
  GtkWindow* window = GTK_WINDOW(data);
  GdkWindow* native = gtk_widget_get_window(GTK_WIDGET(window));
  if (native && (gdk_window_get_state(native) & GDK_WINDOW_STATE_MAXIMIZED)) gtk_window_unmaximize(window);
  else gtk_window_maximize(window);
}
void MenuClose(GtkMenuItem*, gpointer data) { gtk_window_close(GTK_WINDOW(data)); }

void SystemMenu(DesktopBridge* bridge) {
  GdkWindow* native = gtk_widget_get_window(GTK_WIDGET(bridge->window));
  const bool recent = bridge->last_button && g_get_monotonic_time() - bridge->last_button_at < G_USEC_PER_SEC;
  if (native && recent && gdk_window_show_window_menu(native, bridge->last_button)) return;
  GtkWidget* menu = gtk_menu_new();
  const char* labels[] = {"_Minimize", "Ma_ximize", "_Close"};
  GCallback callbacks[] = {G_CALLBACK(MenuMinimize), G_CALLBACK(MenuMaximize), G_CALLBACK(MenuClose)};
  for (int i = 0; i < 3; ++i) {
    GtkWidget* item = gtk_menu_item_new_with_mnemonic(g_dgettext("gtk30", labels[i]));
    g_signal_connect(item, "activate", callbacks[i], bridge->window);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), item);
  }
  gtk_menu_attach_to_widget(GTK_MENU(menu), GTK_WIDGET(bridge->window), nullptr);
  g_signal_connect_swapped(menu, "selection-done", G_CALLBACK(gtk_widget_destroy), menu);
  gtk_widget_show_all(menu);
  if (recent) gtk_menu_popup_at_pointer(GTK_MENU(menu), bridge->last_button);
  else gtk_menu_popup_at_widget(GTK_MENU(menu), GTK_WIDGET(bridge->window), GDK_GRAVITY_NORTH_EAST, GDK_GRAVITY_NORTH_EAST, nullptr);
}

void HandleMethod(FlMethodChannel*, FlMethodCall* call, gpointer user_data) {
  auto* bridge = static_cast<DesktopBridge*>(user_data);
  const gchar* method = fl_method_call_get_name(call);
  if (strcmp(method, "initialize") == 0) {
    bridge->initialized = true;
    g_autoptr(FlValue) state = WindowState(bridge);
    Respond(call, state);
  } else if (strcmp(method, "fonts") == 0) {
    g_autoptr(FlValue) fonts = SystemFonts(bridge->window);
    Respond(call, fonts);
  } else if (strcmp(method, "clipboardFiles") == 0) {
    GtkClipboard* clipboard = gtk_clipboard_get_for_display(gtk_widget_get_display(GTK_WIDGET(bridge->window)), GDK_SELECTION_CLIPBOARD);
    gtk_clipboard_request_uris(clipboard, ClipboardUris, g_object_ref(call));
  } else if (strcmp(method, "brandIcon") == 0) {
    if (SetBrandIcon(bridge, fl_method_call_get_args(call))) Respond(call);
    else fl_method_call_respond_error(call, "icon_unavailable", "The window icon could not be loaded", nullptr, nullptr);
  } else if (strcmp(method, "minimize") == 0) {
    gtk_window_iconify(bridge->window);
    Respond(call);
  } else if (strcmp(method, "toggleMaximize") == 0) {
    MenuMaximize(nullptr, bridge->window);
    Respond(call);
  } else if (strcmp(method, "hide") == 0) {
    gtk_widget_hide(GTK_WIDGET(bridge->window));
    Respond(call);
  } else if (strcmp(method, "show") == 0) {
    gtk_window_present(bridge->window);
    Respond(call);
  } else if (strcmp(method, "drag") == 0) {
    if (bridge->last_button && bridge->last_button->button.button == 1 &&
        g_get_monotonic_time() - bridge->last_button_at < G_USEC_PER_SEC) {
      const auto& event = bridge->last_button->button;
      gtk_window_begin_move_drag(bridge->window, event.button, static_cast<int>(event.x_root), static_cast<int>(event.y_root), event.time);
    }
    Respond(call);
  } else if (strcmp(method, "systemMenu") == 0) {
    SystemMenu(bridge);
    Respond(call);
  } else if (strcmp(method, "maximizeRect") == 0) {
    Respond(call); // Snap hit testing is specific to the Windows non-client area.
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
  }
}

// Gtk's undecorated window still needs native edge resizing; consume only the outer six logical pixels.
int ResizeEdge(GtkWidget* widget, double x, double y) {
  const int width = gtk_widget_get_allocated_width(widget), height = gtk_widget_get_allocated_height(widget);
  const bool left = x < 6, right = x >= width - 6, top = y < 6, bottom = y >= height - 6;
  if (top) return left ? GDK_WINDOW_EDGE_NORTH_WEST : right ? GDK_WINDOW_EDGE_NORTH_EAST : GDK_WINDOW_EDGE_NORTH;
  if (bottom) return left ? GDK_WINDOW_EDGE_SOUTH_WEST : right ? GDK_WINDOW_EDGE_SOUTH_EAST : GDK_WINDOW_EDGE_SOUTH;
  return left ? GDK_WINDOW_EDGE_WEST : right ? GDK_WINDOW_EDGE_EAST : -1;
}

gboolean ViewEvent(GtkWidget* widget, GdkEvent* event, gpointer user_data) {
  auto* bridge = static_cast<DesktopBridge*>(user_data);
  if (event->type == GDK_BUTTON_PRESS || event->type == GDK_2BUTTON_PRESS) {
    if (bridge->last_button) gdk_event_free(bridge->last_button);
    bridge->last_button = gdk_event_copy(event);
    bridge->last_button_at = g_get_monotonic_time();
  }
  GdkWindow* native = gtk_widget_get_window(GTK_WIDGET(bridge->window));
  if (native == nullptr || (gdk_window_get_state(native) & (GDK_WINDOW_STATE_MAXIMIZED | GDK_WINDOW_STATE_FULLSCREEN))) return FALSE;
  double x = 0, y = 0;
  if (!gdk_event_get_coords(event, &x, &y)) return FALSE;
  const int edge = ResizeEdge(widget, x, y);
  if (event->type == GDK_BUTTON_PRESS && event->button.button == 1 && edge >= 0) {
    gtk_window_begin_resize_drag(bridge->window, static_cast<GdkWindowEdge>(edge), 1,
                                 static_cast<int>(event->button.x_root), static_cast<int>(event->button.y_root), event->button.time);
    return TRUE;
  }
  if (event->type == GDK_MOTION_NOTIFY && (edge >= 0 || bridge->edge_cursor)) {
    const char* names[] = {"nw-resize", "n-resize", "ne-resize", "w-resize", "e-resize", "sw-resize", "s-resize", "se-resize"};
    g_autoptr(GdkCursor) cursor = edge < 0 ? nullptr : gdk_cursor_new_from_name(gtk_widget_get_display(widget), names[edge]);
    gdk_window_set_cursor(gtk_widget_get_window(widget), cursor);
    bridge->edge_cursor = edge >= 0;
  }
  return FALSE;
}

void DestroyBridge(gpointer data) {
  auto* bridge = static_cast<DesktopBridge*>(data);
  g_signal_handlers_disconnect_by_data(bridge->window, bridge);
  if (bridge->view) {
    g_signal_handlers_disconnect_by_data(bridge->view, bridge);
    g_object_remove_weak_pointer(G_OBJECT(bridge->view), reinterpret_cast<gpointer*>(&bridge->view));
  }
  fl_method_channel_set_method_call_handler(bridge->channel, nullptr, nullptr, nullptr);
  g_object_unref(bridge->channel);
  if (bridge->last_button) gdk_event_free(bridge->last_button);
  delete bridge;
}

}  // namespace

gboolean sshairy_renderer_preference(GApplication* application) {
  if (g_strcmp0(g_getenv("SSHAIRY_TEST_ISOLATED"), "1") == 0) return FALSE;
  const gchar* identifier = g_application_get_application_id(application);
  g_autofree gchar* exe = g_file_read_link("/proc/self/exe", nullptr);
  g_autofree gchar* executable = exe ? g_path_get_basename(exe) : g_strdup("sshairy");
  gchar* dot = strrchr(executable, '.');
  if (dot && dot != executable) *dot = '\0';
  g_autofree gchar* current = g_build_filename(g_get_user_data_dir(), identifier ? identifier : executable, nullptr);
  g_autofree gchar* legacy = g_build_filename(g_get_user_data_dir(), executable, nullptr);
  // Match path_provider_linux: use the old executable-based directory only when the ID directory does not exist.
  const gchar* directory = !g_file_test(current, G_FILE_TEST_IS_DIR) && g_file_test(legacy, G_FILE_TEST_IS_DIR) ? legacy : current;
  g_autofree gchar* path = g_build_filename(directory, "settings.json", nullptr);
  GStatBuf info = {};
  if (g_stat(path, &info) != 0 || info.st_size < 0 || info.st_size > 1024 * 1024) return FALSE;
  gchar* contents = nullptr;
  gsize length = 0;
  if (!g_file_get_contents(path, &contents, &length, nullptr)) return FALSE;
  g_autoptr(GBytes) bytes = g_bytes_new_take(contents, length);
  g_autoptr(FlJsonMessageCodec) codec = fl_json_message_codec_new();
  g_autoptr(FlValue) settings = fl_message_codec_decode_message(FL_MESSAGE_CODEC(codec), bytes, nullptr);
  if (settings == nullptr || fl_value_get_type(settings) != FL_VALUE_TYPE_MAP) return FALSE;
  FlValue* value = fl_value_lookup_string(settings, "renderer");
  return value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_STRING && strcmp(fl_value_get_string(value), "impeller") == 0;
}

void sshairy_register_desktop_bridge(GtkWindow* window, FlView* view) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  auto* bridge = new DesktopBridge{window, fl_method_channel_new(fl_engine_get_binary_messenger(fl_view_get_engine(view)), "sshairy/window", FL_METHOD_CODEC(codec)), view};
  g_object_add_weak_pointer(G_OBJECT(view), reinterpret_cast<gpointer*>(&bridge->view));
  fl_method_channel_set_method_call_handler(bridge->channel, HandleMethod, bridge, nullptr);
  g_object_set_data_full(G_OBJECT(window), "sshairy-desktop-bridge", bridge, DestroyBridge);
  g_signal_connect(window, "delete-event", G_CALLBACK(CloseRequested), bridge);
  g_signal_connect(window, "window-state-event", G_CALLBACK(WindowStateChanged), bridge);
  g_signal_connect(window, "notify::is-active", G_CALLBACK(FocusChanged), bridge);
  gtk_widget_add_events(GTK_WIDGET(view), GDK_BUTTON_PRESS_MASK | GDK_POINTER_MOTION_MASK);
  g_signal_connect(view, "event", G_CALLBACK(ViewEvent), bridge);
}
