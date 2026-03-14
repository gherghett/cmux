// Centralized C imports for GTK4, libadwaita, VTE, and libnotify.
// All GTK/GLib/VTE types flow through here.
pub const c = @cImport({
    @cInclude("gtk/gtk.h");
    @cInclude("libadwaita-1/adwaita.h");
    @cInclude("vte/vte.h");
    @cInclude("libnotify/notify.h");
});

/// Cast any GTK pointer to *GtkWidget with proper alignment.
/// Equivalent to GTK_WIDGET() macro in C.
pub fn asWidget(ptr: anytype) *c.GtkWidget {
    return @ptrCast(@alignCast(ptr));
}

/// Cast any pointer to *GObject with proper alignment.
pub fn asObject(ptr: anytype) *c.GObject {
    return @ptrCast(@alignCast(ptr));
}
