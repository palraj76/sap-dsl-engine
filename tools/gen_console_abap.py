"""Regenerate the HTML inside ZCL_HTTP_DSL_CONSOLE from web/dsl_console.html.

The page lives as a normal HTML file so it stays easy to edit. This script turns
it into APPEND statements and replaces the generated block in method
GET_PAGE_LINES of src/zcl_http_dsl_console.clas.abap.

Usage (from the repository root):
    python tools/gen_console_abap.py
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
HTML = ROOT / "web" / "dsl_console.html"
CLAS = ROOT / "src" / "zcl_http_dsl_console.clas.abap"

START = '    " >>> GENERATED from web/dsl_console.html by tools/gen_console_abap.py - do not edit by hand'
END = '    " <<< END GENERATED'
INDENT = "    "
MAX_ABAP_LINE = 255  # ABAP source line limit


def to_abap(lines):
    out, problems = [], []
    for no, line in enumerate(lines, 1):
        if any(ord(c) > 126 or (ord(c) < 32 and c != "\t") for c in line):
            problems.append(f"line {no}: non-ASCII or control character - use an HTML entity or \\u escape")
        literal = line.replace("\t", "  ").replace("`", "``")
        stmt = f"{INDENT}APPEND `{literal}` TO rt_lines."
        if len(stmt) > MAX_ABAP_LINE:
            problems.append(f"line {no}: {len(stmt)} chars once wrapped in APPEND (max {MAX_ABAP_LINE}) - split it")
        out.append(stmt)
    return out, problems


def main():
    lines = HTML.read_text(encoding="utf-8").splitlines()
    stmts, problems = to_abap(lines)
    if problems:
        print("Not generated:\n  " + "\n  ".join(problems))
        return 1

    src = CLAS.read_text(encoding="utf-8").splitlines()
    try:
        a, b = src.index(START), src.index(END)
    except ValueError:
        print(f"Markers not found in {CLAS.name}")
        return 1
    new = src[: a + 1] + stmts + src[b:]
    CLAS.write_text("\n".join(new) + "\n", encoding="utf-8", newline="\n")
    print(f"{CLAS.name}: {len(stmts)} HTML lines written")
    return 0


if __name__ == "__main__":
    sys.exit(main())
