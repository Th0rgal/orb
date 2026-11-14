"""Palette contract with the actual CSS source, including composited tokens."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
DIRECT = {
    'canvas': 'bg', 'surface': 'bg-inset', 'elevatedSurface': 'bg-elev', 'header': 'bg',
    'border': 'stroke', 'borderSubtle': 'stroke-soft', 'textPrimary': 'fg',
    'textSecondary': 'fg-2', 'textMuted': 'fg-3', 'textStrong': 'fg-strong',
    'textFaint': 'fg-4', 'borderStrong': 'stroke-strong', 'accent': 'blue',
    'codeBg': 'bg-code', 'diffAddText': 'diff-add-fg', 'diffDelText': 'diff-del-fg',
    'diffHunkText': 'fg', 'danger': 'danger', 'warning': 'warning', 'success': 'green',
    'plusBg': 'plus-bg', 'sendBg': 'send-bg', 'sendFg': 'send-fg',
}


def rgba(value):
    value = value.strip()
    if value.startswith('#'):
        h = value[1:]
        if len(h) == 3:
            h = ''.join(c*2 for c in h)
        if len(h) == 6:
            h += 'ff'
        return tuple(bytes.fromhex(h))
    raise ValueError(value)


def mix(a, b, fraction):
    return tuple(int(x*fraction+y*(1-fraction)+0.5) for x, y in zip(a[:3], b[:3]))+(255,)


class TokenTests(unittest.TestCase):
    def test_dark_and_light(self):
        css = (ROOT/'orb/src/styles.css').read_text()
        lean = (ROOT/'lean/LeanUI/Style.lean').read_text()
        dark = re.search(r':root\s*\{(.*?)\n\}', css, re.S)[1]
        light = re.search(r':root\[data-theme="light"\]\s*\{(.*?)\n\}', css, re.S)[1]
        for theme, block in [('Dark', dark), ('Light', light)]:
            linux = re.search(r':root\[data-platform="linux"\]'+(r'\[data-theme="light"\]' if theme == 'Light' else '')+r'\s*\{(.*?)\n\}', css, re.S)[1]
            tokens = dict(re.findall(r'--([\w-]+):\s*([^;]+);', dark+'\n'+block+'\n'+linux))
            palette = dict((k, tuple(bytes.fromhex(v))) for k, v in re.findall(r'(\w+)\s*:=\s*0x([0-9A-Fa-f]{8})', re.search(r'def orb'+theme+r'Palette : Palette := \{(.*?)\n\}', lean, re.S)[1]))
            expected = {k: rgba(tokens[v]) for k, v in DIRECT.items() if not v.startswith('diff-')}
            # Diff colors live in later component rules, shared across themes.
            diff = (ROOT/'orb/src/DiffViewer.css').read_text()
            expected['diffAddText'] = rgba(re.search(r'var\(--ok,\s*(#[0-9a-f]+)\)', diff)[1])
            add_alpha = float(re.search(r'\.diff-row-add\s*\{.*?var\(--ok,.*?\)\s*(\d+)%', diff, re.S)[1])/100
            del_alpha = float(re.search(r'\.diff-row-del\s*\{.*?var\(--danger,.*?\)\s*(\d+)%', diff, re.S)[1])/100
            hunk_alpha = float(re.search(r'\.diff-hunk-head\s*\{.*?var\(--stroke\)\s*(\d+)%', diff, re.S)[1])/100
            expected['diffDelText'] = rgba(tokens['danger'])
            expected['diffAddBg'] = expected['diffAddText'][:3]+(int(255*add_alpha+.5),)
            expected['diffDelBg'] = expected['diffDelText'][:3]+(int(255*del_alpha+.5),)
            expected['diffHunkBg'] = rgba(tokens['stroke'])[:3]+(int(255*hunk_alpha+.5),)
            expected['accentMuted'] = rgba(tokens['blue'])[:3]+((51 if theme == 'Dark' else 38),)
            expected['sidebar'] = mix(rgba(tokens['bg-sidebar']), rgba(tokens['bg']), float(tokens['sidebar-opacity'].rstrip('%'))/100)
            # Sidebar overrides are in the platform-independent .sidebar block.
            sidebar_rule = re.search(r'(?:^|\n)'+(r':root\[data-theme="light"\] ' if theme == 'Light' else '')+r'\.sidebar\s*\{(.*?)\n\}', css, re.S)[1]
            active_fraction = float(re.search(r'--bg-active:.*?var\(--fg\)\s*([\d.]+)%', sidebar_rule)[1])/100
            expected['rowActive'] = mix(rgba(tokens['fg']), expected['sidebar'], active_fraction)
            focus = float(re.search(r'(\d+)%', tokens['focus-border'])[1])/100
            expected['focusRing'] = mix(rgba(tokens['fg']), rgba(tokens['stroke']), focus)
            shadow = re.search(r'rgba\((\d+),\s*(\d+),\s*(\d+),\s*([\d.]+)\)', tokens['shadow-lg'])
            expected['shadowColor'] = tuple(int(shadow[i]) for i in (1, 2, 3))+(int(float(shadow[4])*255),)
            self.assertEqual(set(palette), set(expected))
            for key, value in expected.items():
                with self.subTest(theme=theme, token=key):
                    if key in ('sidebar', 'rowActive'):
                        # Chromium quantizes translucent layers to 8-bit before compositing.
                        self.assertLessEqual(max(abs(a-b) for a, b in zip(palette[key], value)), 1)
                    else:
                        self.assertEqual(palette[key], value)


if __name__ == '__main__':
    unittest.main()
