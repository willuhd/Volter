# dmgbuild settings for the Volter Intel disk image.
#
# Consumed by .github/release/make-dmg.sh, both locally and in CI.
#
# Geometry provenance: decoded from the .DS_Store of a DMG Canvas-built image
# (volume "Volter Intel"), not from a design document, since document icon
# coordinates do not match what actually ships. From that image:
#
#   fwi0   top=120 left=200 bottom=480 right=800, view "icnv"  -> 600x360 window
#   fwvh   360   the *content* height, not the frame
#   icvt   12    label font size
#   icvo   127   icon size (see note below)
#   Iloc   Volter.app (113, 169), Applications (471, 169)
#
# The background is the flattened composite DMG Canvas produced, so nothing
# needs to be drawn at build time.
#
# NOTE on icon_size: the .DS_Store carries no plain "icon size" field. 127 is
# read from the icvo record, where the same field reads 99 on a sibling design
# whose document independently records 99 -- so the field's meaning correlates.
# If the icons render the wrong size, change this one number.

import os

# dmgbuild exec()s this file with the settings dict as the namespace, so
# __file__ does NOT exist here and must not be reintroduced. The directory
# holding the background is passed in by make-dmg.sh instead.
_here = defines.get("assets_dir")  # noqa: F821  (defined by dmgbuild)
if not _here:
    raise SystemExit(
        "error: run dmgbuild with -D assets_dir=/path/to/.github/release"
    )

# Injected by make-dmg.sh as -D app_path=/path/to/Volter.app
app_path = defines.get("app_path")  # noqa: F821  (defined by dmgbuild)
if not app_path:
    raise SystemExit(
        "error: run dmgbuild with -D app_path=/path/to/Volter.app"
    )

app_name = os.path.basename(app_path)

# ---------------------------------------------------------------------------
# Contents
# ---------------------------------------------------------------------------
files = [app_path]

# The volume name ("Volter Intel") is passed as dmgbuild's positional argument
# by make-dmg.sh, not set here, so there is a single source of truth.

symlinks = {"Applications": "/Applications"}

# ---------------------------------------------------------------------------
# Finder window
# ---------------------------------------------------------------------------
# Width stays at the design's 600pt. Height is raised to 424pt to match the
# background image's height: the DMG Canvas image used a 600x360 window against
# a 664x424pt background, so the bottom 64pt of the picture sat below the fold
# and the window scrolled.
#
# y is measured from the BOTTOM of the display by dmgbuild, whereas DMG Canvas
# measured its origin from the top (top=120). A large y is dmgbuild's documented
# idiom for "as high on the display as the Finder will allow".
window_rect = ((200, 100000), (600, 424))

default_view = "icon-view"
icon_size = 127
text_size = 12
label_pos = "bottom"

icon_locations = {
    app_name: (113, 169),
    "Applications": (471, 169),
}

# ---------------------------------------------------------------------------
# Background
# ---------------------------------------------------------------------------
# As written by DMG Canvas: a 2-frame TIFF.
#   frame 0: 1328x848 @144dpi   (Retina representation)
#   frame 1:  664x424 @1x
# Both represent 664x424pt. This MUST stay a multi-representation/DPI-tagged
# image: Finder draws folder background pictures at their natural *point* size,
# so a plain 1328x848 PNG would render as a zoomed crop of the top-left corner.
background = os.path.join(_here, "dmg-background.tiff")
