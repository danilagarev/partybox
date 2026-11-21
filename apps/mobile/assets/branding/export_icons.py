"""Rasterize the original SVG using system librsvg/cairo, no pip packages.
Run from any directory: python3 apps/mobile/assets/branding/export_icons.py
Requires Linux libcairo.so.2 and librsvg-2.so.2 (build tooling only).
"""
import ctypes as c
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
MOBILE = HERE.parents[1]
svg = c.CDLL('librsvg-2.so.2')
cairo = c.CDLL('libcairo.so.2')
gobject = c.CDLL('libgobject-2.0.so.0')
svg.rsvg_handle_new_from_file.argtypes = [c.c_char_p, c.c_void_p]
svg.rsvg_handle_new_from_file.restype = c.c_void_p
svg.rsvg_handle_render_cairo.argtypes = [c.c_void_p, c.c_void_p]
svg.rsvg_handle_render_cairo.restype = c.c_int
cairo.cairo_image_surface_create.argtypes = [c.c_int, c.c_int, c.c_int]
cairo.cairo_image_surface_create.restype = c.c_void_p
cairo.cairo_create.argtypes = [c.c_void_p]
cairo.cairo_create.restype = c.c_void_p
cairo.cairo_scale.argtypes = [c.c_void_p, c.c_double, c.c_double]
cairo.cairo_surface_write_to_png.argtypes = [c.c_void_p, c.c_char_p]
cairo.cairo_surface_write_to_png.restype = c.c_int
cairo.cairo_destroy.argtypes = [c.c_void_p]
cairo.cairo_surface_destroy.argtypes = [c.c_void_p]
gobject.g_object_unref.argtypes = [c.c_void_p]
handle = svg.rsvg_handle_new_from_file(str(HERE / 'partybox-icon.svg').encode(), None)
assert handle, 'Cannot load SVG master'

def export(path, size):
    surface = cairo.cairo_image_surface_create(1, size, size)  # RGB24, opaque for stores
    context = cairo.cairo_create(surface)
    cairo.cairo_scale(context, size / 1024, size / 1024)
    assert svg.rsvg_handle_render_cairo(handle, context)
    assert cairo.cairo_surface_write_to_png(surface, str(path).encode()) == 0
    cairo.cairo_destroy(context)
    cairo.cairo_surface_destroy(surface)

export(HERE / 'partybox-icon-1024.png', 1024)
export(HERE / 'partybox-icon-512.png', 512)
for density, size in [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)]:
    export(MOBILE / f'android/app/src/main/res/mipmap-{density}/ic_launcher.png', size)
icons = MOBILE / 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
for image in json.loads((icons / 'Contents.json').read_text())['images']:
    size = round(float(image['size'].split('x')[0]) * float(image['scale'][:-1]))
    export(icons / image['filename'], size)
gobject.g_object_unref(handle)
print('PartyBox: exported 1024/512 masters, Android and iOS icons')
