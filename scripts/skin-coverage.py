#!/usr/bin/env python3
"""Report how much of the iPhone view code already reads the interface-skin tokens.

A view that still writes `.foregroundStyle(.secondary)` or `cornerRadius: 12` cannot be restyled
by a skin. This walks Primuse/Views (macOS-only blocks and the Mac folder excluded), counts
token reads against hard-coded colours, radii and font sizes, and prints the files with the most
left to migrate. It is a progress report, not a gate.

    scripts/skin-coverage.py            # top 25 files
    scripts/skin-coverage.py --all      # every file
    scripts/skin-coverage.py --min 40   # exit 1 when colour coverage is below 40 %
"""
import argparse, os, re, sys

ROOT = 'Primuse/Views'
SKIP_DIRS = {'Mac'}
# Not chrome: the token mapping itself, and self-contained artwork (posters, immersive stages,
# the yearly report) whose colours are part of the piece rather than of the interface.
SKIP_PREFIXES = (
    'Theme/SkinStyle.swift',
    'Sharing/LyricPoster/',
    'NowPlaying/ImmersiveStage',
    'YearlyReport/',
)

TOKEN = re.compile(r'\.skin\(\.|\bskin\.(?:color|shapeStyle|metric|rawMetric|font|fontSize|animation)\(')
COLOR_LITERAL = re.compile(
    r'\.(?:foregroundStyle|foregroundColor|fill|stroke|strokeBorder|background|tint)\(\s*\.(?:primary|secondary|tertiary|quaternary)\b'
    r'|\bColor\.(?:primary|secondary|white|black|gray|red|green|blue|orange|pink|purple|yellow)\b'
    r'|\bColor\(\s*(?:red:|\.system|uiColor:|white:|hue:)'
    r'|\.(?:white|black)\.opacity\('
)
RADIUS_LITERAL = re.compile(r'cornerRadius:\s*\d')
FONT_LITERAL = re.compile(r'\.font\(\s*\.system\(\s*size:\s*\d')


def ios_lines(text):
    """Drop lines that only compile on macOS. Conditionals nest, so keep a stack of branch kinds."""
    stack, out = [], []
    for line in text.split('\n'):
        stripped = line.strip()
        if stripped.startswith('#if'):
            kind = 'mac' if 'os(macOS)' in stripped and '!' not in stripped else (
                'ios' if 'os(iOS)' in stripped and '!' not in stripped else 'other')
            stack.append(kind)
            continue
        if stripped.startswith('#elseif') or stripped.startswith('#else'):
            if stack:
                previous = stack[-1]
                if 'os(macOS)' in stripped:
                    stack[-1] = 'mac'
                elif 'os(iOS)' in stripped:
                    stack[-1] = 'ios'
                else:
                    stack[-1] = {'mac': 'ios', 'ios': 'mac'}.get(previous, 'other')
            continue
        if stripped.startswith('#endif'):
            if stack:
                stack.pop()
            continue
        if 'mac' not in stack:
            out.append(line)
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--all', action='store_true')
    parser.add_argument('--min', type=float, default=None)
    args = parser.parse_args()

    rows = []
    for directory, dirs, files in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for name in files:
            if not name.endswith('.swift'):
                continue
            path = os.path.join(directory, name)
            if path[len(ROOT) + 1:].startswith(SKIP_PREFIXES):
                continue
            lines = ios_lines(open(path, encoding='utf-8').read())
            body = '\n'.join(l for l in lines if not l.strip().startswith('//'))
            tokens = len(TOKEN.findall(body))
            colours = len(COLOR_LITERAL.findall(body))
            radii = len(RADIUS_LITERAL.findall(body))
            fonts = len(FONT_LITERAL.findall(body))
            if tokens or colours or radii or fonts:
                rows.append((colours + radii + fonts, path, tokens, colours, radii, fonts))

    rows.sort(reverse=True)
    total_tokens = sum(r[2] for r in rows)
    total_colours = sum(r[3] for r in rows)
    total_radii = sum(r[4] for r in rows)
    total_fonts = sum(r[5] for r in rows)
    coverage = 100.0 * total_tokens / max(1, total_tokens + total_colours)

    print(f'{"file":62s} {"tokens":>6s} {"colour":>6s} {"radius":>6s} {"font":>6s}')
    for _, path, tokens, colours, radii, fonts in (rows if args.all else rows[:25]):
        print(f'{path[len(ROOT) + 1:]:62s} {tokens:6d} {colours:6d} {radii:6d} {fonts:6d}')
    print('-' * 90)
    print(f'{len(rows)} files: {total_tokens} token reads, {total_colours} hard-coded colours, '
          f'{total_radii} radii, {total_fonts} font sizes')
    print(f'colour coverage: {coverage:.1f} %')
    if args.min is not None and coverage < args.min:
        sys.exit(1)


if __name__ == '__main__':
    main()
