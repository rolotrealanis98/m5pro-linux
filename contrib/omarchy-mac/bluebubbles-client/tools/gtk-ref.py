#!/usr/bin/env python3
"""A plain GTK3 window in the desktop's interface font, as a size reference next to BlueBubbles.
Prints the font and the text scale GTK uses. Run with the Hyprland session environment (see bb-launch.py --exec)."""
import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, GLib
s = Gtk.Settings.get_default()
print('gtk-font-name=%s xft-dpi=%s' % (s.props.gtk_font_name, s.props.gtk_xft_dpi), flush=True)
w = Gtk.Window(title='bb-gtk-ref'); w.set_default_size(560, 220); w.set_name('bb-gtk-ref')
box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, margin=16); w.add(box)
for t in ('Hamburgefonstiv 0123456789 (GTK label, interface font)', 'The quick brown fox jumps over the lazy dog'):
    box.add(Gtk.Label(label=t, xalign=0))
box.add(Gtk.Button(label='Button')); box.add(Gtk.Entry(text='Entry'))
w.connect('destroy', Gtk.main_quit); w.show_all()
GLib.timeout_add_seconds(int(__import__('sys').argv[1]) if len(__import__('sys').argv) > 1 else 25, Gtk.main_quit)
Gtk.main()
