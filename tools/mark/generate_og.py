#!/usr/bin/env python3
"""Generate the social share card (og:image) for the website.

1200x630, the one size every platform crops least. The wordmark lockup and
tagline sit in the left column inside the safe area (text kept well clear of
edges so LinkedIn/Facebook/X center-crops never clip it); a phone screenshot
bleeds off the bottom right.

Usage:
    python3 generate_og.py ../../website/public/og/card.png
"""

import argparse
import base64
import subprocess
import sys
from pathlib import Path

from generate import (
    GLYPH_H,
    GROUND,
    INK_PRIMARY,
    INK_SECONDARY,
    text_cells,
    text_width,
)

W, H = 1200, 630
MARGIN = 84                      # safe-area margin for all text
SHOT = Path(__file__).resolve().parents[2] / "website/public/shots/01.png"

TAGLINE = ["Control your agents", "from your phone."]
SUBLINE = "Free. End-to-end encrypted. No servers."


def lockup_svg(x, y, cell_px):
    """The REMOTE / FOR OPENCODE banner lockup at (x, y), left-aligned."""
    parts = [f'<g shape-rendering="crispEdges">']
    for row_index, line in enumerate(["REMOTE", "FOR OPENCODE"]):
        fill = INK_PRIMARY if row_index == 0 else INK_SECONDARY
        oy = y + row_index * (GLYPH_H + 2) * cell_px
        for col, row in text_cells(line):
            parts.append(
                f'<rect x="{x + col * cell_px}" y="{oy + row * cell_px}" '
                f'width="{cell_px}" height="{cell_px}" fill="{fill}"/>'
            )
    parts.append("</g>")
    return "\n".join(parts)


def build_svg():
    shot_b64 = base64.b64encode(SHOT.read_bytes()).decode()
    # 1284x2778 source; width 380 keeps the left column roomy and lets the
    # phone run off the bottom edge.
    shot_w = 350
    shot_h = round(shot_w * 2778 / 1284)
    shot_x, shot_y = W - shot_w - 80, 100

    cell_px = 9  # FOR OPENCODE is 58 cells wide; 9px keeps the lockup ~522px

    tagline = "".join(
        f'<text x="{MARGIN}" y="{330 + i * 54}" '
        'font-family="Helvetica Neue, Helvetica, Arial" font-size="42" '
        f'font-weight="600" fill="{INK_PRIMARY}">{line}</text>'
        for i, line in enumerate(TAGLINE)
    )

    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}"
  viewBox="0 0 {W} {H}">
  <rect width="{W}" height="{H}" fill="{GROUND}"/>
  {lockup_svg(MARGIN, 96, cell_px)}
  {tagline}
  <text x="{MARGIN}" y="452" font-family="Helvetica Neue, Helvetica, Arial"
    font-size="26" font-weight="400" fill="{INK_SECONDARY}">{SUBLINE}</text>
  <clipPath id="phone"><rect x="{shot_x}" y="{shot_y}" width="{shot_w}"
    height="{shot_h}" rx="42"/></clipPath>
  <image x="{shot_x}" y="{shot_y}" width="{shot_w}" height="{shot_h}"
    clip-path="url(#phone)" href="data:image/png;base64,{shot_b64}"/>
  <rect x="{shot_x}" y="{shot_y}" width="{shot_w}" height="{shot_h}" rx="42"
    fill="none" stroke="{INK_SECONDARY}" stroke-opacity="0.35" stroke-width="2"/>
</svg>"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out", type=Path)
    args = parser.parse_args()

    tmp = args.out.with_suffix(".tmp.svg")
    tmp.write_text(build_svg())
    # Headless Chrome renders the SVG at exactly W x H; qlmanage pads
    # non-square thumbnails and clips, so it is no good here.
    rendered = args.out.resolve()
    subprocess.run(
        [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "--headless", "--disable-gpu", "--force-device-scale-factor=1",
            f"--window-size={W},{H}", "--default-background-color=00000000",
            f"--screenshot={rendered}", tmp.resolve().as_uri(),
        ],
        check=True, capture_output=True,
    )
    if not rendered.exists():
        sys.exit("render failed")
    tmp.unlink()
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
