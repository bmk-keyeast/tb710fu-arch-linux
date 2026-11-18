#!/usr/bin/env python3
"""Contact sheet of the rendered kShimC themes: sheet.py <dir with STYLE.png> <out.png>"""
import pathlib
import sys

from PIL import Image, ImageDraw, ImageFont

CURRENT = "IOS_HIG"
THEMES = {
    "IOS_HIG": "iOS 스타일 목록", "CUPERTINO": "애플풍 밝은 목록", "STAR_CHART": "손그림 별자리",
    "HARMONYOS": "HarmonyOS풍 카드", "ONE_UI": "삼성 One UI풍", "CLOVER": "Clover 부트로더풍",
    "MATERIAL3": "Material 3", "MATERIAL2": "Material 2 밝게", "MATERIAL2_DARK": "Material 2 어둡게",
    "FLUENT": "Fluent 밝게", "FLUENT_DARK": "Fluent 어둡게", "FLUENT2": "Fluent 2 밝게",
    "FLUENT2_DARK": "Fluent 2 어둡게", "SURFACE": "Surface UEFI풍", "SURFACE_DARK": "Surface 어둡게",
    "METRO": "Windows Metro풍", "ADWAITA": "GNOME Adwaita풍", "HOLO": "Android Holo풍",
    "GLASS": "반투명 유리", "AURORA": "오로라 그라데이션", "SOFT_UI": "부드러운 입체",
    "BENTO": "벤토 카드", "CARDS": "카드형", "NEON": "네온", "NORD": "Nord 색상",
    "FLAT": "단순 평면", "MINIMAL": "미니멀", "CLASSIC": "고전 부트로더", "TERMINAL": "터미널",
    "HIGH_CONTRAST": "고대비", "LVGL_DEFAULT": "LVGL 기본",
}
COLS, TILE_W, TILE_H, GAP, LABEL, HEAD = 4, 640, 400, 28, 74, 150
FONT = "/usr/share/opentype/noto/NotoSansCJK-%s.ttc"

src, out = pathlib.Path(sys.argv[1]), sys.argv[2]
found = [s for s in THEMES if (src / f"{s}.png").exists()]
rows = (len(found) + COLS - 1) // COLS
W = COLS * TILE_W + (COLS + 1) * GAP
H = HEAD + rows * (TILE_H + LABEL + GAP) + GAP
sheet = Image.new("RGB", (W, H), "#15171c")
d = ImageDraw.Draw(sheet)
big, name, desc = (ImageFont.truetype(FONT % w, s) for w, s in (("Bold", 52), ("Bold", 26), ("Regular", 22)))
d.text((GAP, 28), f"kShimC 부트 메뉴 테마 {len(found)}종", font=big, fill="#ffffff")
d.text((GAP, 100), "TB710FU 해상도(3200×2000)로 실제 메뉴 코드를 렌더링한 화면", font=desc, fill="#a9afbb")
for i, style in enumerate(found):
    x = GAP + (i % COLS) * (TILE_W + GAP)
    y = HEAD + (i // COLS) * (TILE_H + LABEL + GAP)
    sheet.paste(Image.open(src / f"{style}.png").convert("RGB").resize((TILE_W, TILE_H), Image.LANCZOS), (x, y))
    now = style == CURRENT
    d.rectangle((x - 3, y - 3, x + TILE_W + 2, y + TILE_H + 2), outline="#35c759" if now else "#3a3f4a", width=6 if now else 2)
    d.text((x, y + TILE_H + 8), style + ("  ● 현재 적용" if now else ""), font=name, fill="#35c759" if now else "#ffffff")
    d.text((x, y + TILE_H + 42), THEMES[style], font=desc, fill="#a9afbb")
sheet.save(out, optimize=True)
missing = sorted(set(THEMES) - set(found))
print(f"{len(found)} themes, missing: {missing}")
