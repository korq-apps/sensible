"""Terminal presentation for the wizard and probe report: branding, boxes, prompts.

Presentation only. Nothing here decides control flow, and the JSON exchanged
between wizard and backend never passes through this module. Colour and box
drawing switch off when stdout is not a terminal, when NO_COLOR is set
(https://no-color.org) or when TERM is dumb, so piped output stays plain text.
The recovery copy installed outside the checkout never imports this module.
"""
import os
from pathlib import Path
import shutil
import sys
import textwrap

HERE = Path(__file__).resolve().parent
LOGO_PATHS = (HERE.parents[1] / 'live/config/includes.chroot/usr/share/sensible/logo.txt',
              Path('/usr/share/sensible/logo.txt'))
GUTTER = '  '
MAX_WIDTH = 76
MIN_WIDTH = 40

# Same palette as installer/lib/ui.sh: green brand, grey captions, cyan prompts.
SGR = {'bold': '1', 'dim': '2', 'red': '31', 'green': '32', 'yellow': '33', 'cyan': '36'}
KINDS = {'ok': ('green', 'bold'), 'warn': ('yellow', 'bold'), 'fail': ('red', 'bold'), 'info': ('cyan', 'bold')}
GLYPHS = {
    'utf8': {'tl': '╭', 'tr': '╮', 'bl': '╰', 'br': '╯', 'h': '─', 'v': '│',
             'done': '●', 'todo': '○', 'ok': '✔', 'fail': '✘', 'warn': '▲', 'info': '▸',
             'prompt': '›', 'bullet': '•'},
    'ascii': {'tl': '+', 'tr': '+', 'bl': '+', 'br': '+', 'h': '-', 'v': '|',
              'done': '#', 'todo': '-', 'ok': 'OK', 'fail': '!!', 'warn': '!', 'info': '>',
              'prompt': '>', 'bullet': '*'},
}


class Style:
    """Capability detection happens once per stream; tests construct it directly."""

    def __init__(self, stream=None, color=None, unicode=None, width=None):
        stream = sys.stdout if stream is None else stream
        tty = bool(getattr(stream, 'isatty', lambda: False)())
        if color is None:
            color = tty and not os.environ.get('NO_COLOR') and os.environ.get('TERM', '') not in ('', 'dumb')
        if unicode is None:
            encoding = (getattr(stream, 'encoding', None) or '').lower().replace('-', '').replace('_', '')
            unicode = encoding == 'utf8'
        if width is None:
            width = shutil.get_terminal_size((80, 24)).columns if tty else 80
        self.color = bool(color)
        self.glyphs = GLYPHS['utf8' if unicode else 'ascii']
        self.width = max(MIN_WIDTH, min(MAX_WIDTH, width - 2 * len(GUTTER)))

    def paint(self, text, *styles):
        if not self.color or not styles:
            return text
        return '\x1b[' + ';'.join(SGR[name] for name in styles) + 'm' + text + '\x1b[0m'

    def mark(self, kind):
        """The glyph for a message kind, coloured to match."""
        return self.paint(self.glyphs[kind], *KINDS[kind])

    def glyph(self, name):
        return self.glyphs[name]


def logo_lines():
    for path in LOGO_PATHS:
        try:
            lines = [line.rstrip() for line in path.read_text(encoding='utf-8').splitlines()]
        except (OSError, UnicodeDecodeError):
            continue
        while lines and not lines[-1]:
            lines.pop()
        # The shipped logo is printable ASCII art; refuse anything that could
        # carry control sequences into the terminal.
        if lines and all(line.isascii() and line.isprintable() for line in lines) and max(map(len, lines)) <= MAX_WIDTH:
            return lines
    return ['Sensible']


def wrap(text, width):
    """Keep blank lines and explicit line breaks; reflow only long lines."""
    output = []
    for line in text.splitlines() or ['']:
        output.extend(textwrap.wrap(line, width, break_long_words=False, break_on_hyphens=False) or [''])
    return output


def emit(lines, out=None):
    print('\n'.join(lines), file=sys.stdout if out is None else out, flush=True)


def banner(style, title, *caption, out=None):
    """Sensible logo, page title and a bullet-separated caption, as the installer draws it."""
    joiner = '  ' + style.glyph('bullet') + '  '
    lines = [GUTTER + style.paint(line, 'green') for line in logo_lines()]
    lines += ['', GUTTER + style.paint(title, 'bold'), GUTTER + style.paint(joiner.join(caption), 'dim')]
    emit(lines, out)


def box(style, rows, *edge_styles):
    """Rows are (painted, visible) pairs; visible text sets the padding."""
    g = style.glyph
    inner = style.width - 4
    side = style.paint(g('v'), *edge_styles)
    body = [GUTTER + side + ' ' + painted + ' ' * max(0, inner - len(visible)) + ' ' + side for painted, visible in rows]
    bar = g('h') * (inner + 2)
    return [GUTTER + style.paint(g('tl') + bar + g('tr'), *edge_styles), *body,
            GUTTER + style.paint(g('bl') + bar + g('br'), *edge_styles)]


def step(style, number, total, title, detail=None, out=None):
    """Numbered stage header with a dotted progress track, like the installer's bar."""
    g = style.glyph
    inner = style.width - 4
    label = f'Step {number} of {total}'
    track = g('done') * number + g('todo') * (total - number)
    rows = []
    for index, line in enumerate(wrap(f'{label}  {title}', inner)):
        if index == 0 and line.startswith(label):
            rows.append((style.paint(label, 'dim') + style.paint(line[len(label):], 'bold'), line))
        else:
            rows.append((style.paint(line, 'bold'), line))
    painted, visible = rows[0]
    if len(visible) + 2 + len(track) <= inner:
        gap = inner - len(visible) - len(track)
        rows[0] = (painted + ' ' * gap + style.paint(track, 'green'), visible + ' ' * gap + track)
    else:
        gap = inner - len(track)
        rows.append((' ' * gap + style.paint(track, 'green'), ' ' * gap + track))
    if detail:
        rows.extend((line, line) for line in wrap(detail, inner))
    emit(['', *box(style, rows, 'green')], out)


def say(style, message, kind=None, out=None):
    """A wrapped paragraph; kind marks it as ok, warn, fail or info with a glyph."""
    prefix = style.mark(kind) + ' ' if kind else ''
    indent = ' ' * (len(style.glyph(kind)) + 1) if kind else ''
    lines = wrap(message, style.width - len(indent))
    emit(['', GUTTER + prefix + lines[0], *(GUTTER + indent + line for line in lines[1:])], out)


def rule(style, title=None, out=None):
    h = style.glyph('h')
    line = h * style.width
    if title:
        line = h * 2 + ' ' + title + ' ' + h * max(0, style.width - len(title) - 4)
    emit(['', GUTTER + style.paint(line, 'dim')], out)


def grid(style, rows, out=None):
    """Aligned columns. Each cell is (text, *style names); a kind name also works."""
    cells = [[(text, KINDS.get(names[0], names) if len(names) == 1 else names)
              for text, *names in row] for row in rows]
    widths = [max(len(row[column][0]) for row in cells if column < len(row))
              for column in range(max(map(len, cells), default=0))]
    lines = []
    for row in cells:
        parts = [(style.paint(text, *names) if text else '') + ' ' * (widths[column] - len(text))
                 for column, (text, names) in enumerate(row)]
        lines.append((GUTTER + '  '.join(parts)).rstrip())
    emit(lines, out)


def prompt_text(style, question, hint=''):
    text = GUTTER + style.paint(style.glyph('prompt'), 'cyan', 'bold') + ' ' + question
    if hint:
        text += ' ' + style.paint(hint, 'dim')
    return text + ' '
