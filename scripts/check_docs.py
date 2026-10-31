#!/usr/bin/env python3
"""Check Markdown docs against docs/STYLE_GUIDE.md.

Usage:
    python3 scripts/check_docs.py [path ...] [--strict]

Default: check all Markdown files in the repository except generated/vendor dirs.
Exit code: 1 if there are errors (or warnings with --strict), else 0.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parent.parent
SKIP_DIRS = {
    ".git",
    ".claude",
    ".github",
    "node_modules",
    ".venv",
    "venv",
    "__pycache__",
}
SKIP_FILES = {"_sidebar.md"}
METADATA_EXEMPT = {"README.md", "CLAUDE.md"}

ALLOWED_STATUS = ("已实测", "部分实测", "未实测", "设计稿")
ALLOWED_TYPE_HINTS = (
    "Explanation",
    "Tutorial",
    "How-to",
    "Reference",
    "Case study",
    "解释",
    "教程",
    "操作指南",
    "参考",
    "排障记录",
)

RE_STATUS = re.compile(r"^>\s*\*\*状态\*\*\s*[:：]\s*(.+)$")
RE_TYPE = re.compile(r"^>\s*\*\*类型\*\*\s*[:：]\s*(.+)$")
RE_HEADING = re.compile(r"^(#{1,6})\s+(.+?)\s*$")
RE_FENCE = re.compile(r"^\s*(```+|~~~+)\s*([^\s`]*)")
RE_LINK = re.compile(r"\[([^\]]+)\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
RE_SEP = re.compile(r"^\s*\|?[\s:|-]+\|?\s*$")
RE_DATE = re.compile(r"\d{4}-\d{2}-\d{2}")


@dataclass
class Issue:
    severity: str
    path: Path
    line: int
    message: str


def rel(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def split_cells(line: str) -> list[str]:
    """Split a Markdown table row on unescaped pipes."""
    s = line.strip()
    if s.startswith("|"):
        s = s[1:]
    if s.endswith("|"):
        s = s[:-1]
    cells: list[str] = []
    buf: list[str] = []
    escaped = False
    for ch in s:
        if escaped:
            buf.append(ch)
            escaped = False
        elif ch == "\\":
            escaped = True
        elif ch == "|":
            cells.append("".join(buf).strip())
            buf = []
        else:
            buf.append(ch)
    cells.append("".join(buf).strip())
    return cells


def check_links(path: Path, line_no: int, line: str) -> list[Issue]:
    issues: list[Issue] = []
    for m in RE_LINK.finditer(line):
        target = m.group(2).strip()
        if not target or target.startswith("#"):
            continue
        if target in {"...", "<...>"} or target.startswith("<"):
            continue
        if re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", target):
            # absolute URL or non-file scheme; local-link check does not apply
            continue
        target = target.split("#", 1)[0]
        if not target:
            continue
        target = unquote(target)
        candidate = (path.parent / target).resolve()
        ok = candidate.exists()
        if not ok and not Path(target).suffix:
            ok = (candidate.with_suffix(".md")).exists() or (candidate / "README.md").exists()
        if not ok:
            issues.append(Issue("error", path, line_no, f"broken relative link: {target}"))
    return issues


def check_file(path: Path, strict_templates: bool = False) -> list[Issue]:
    issues: list[Issue] = []
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError as exc:
        return [Issue("error", path, 1, f"cannot read file: {exc}")]

    is_template = "docs/templates/" in rel(path)
    is_style_guide = rel(path) == "docs/STYLE_GUIDE.md"
    is_metadata_exempt = path.name in METADATA_EXEMPT
    in_fence = False
    fence_char = ""
    fence_start = 0
    fence_lang = ""
    heading_levels: list[tuple[int, int, str]] = []
    table: list[tuple[int, list[str]]] = []
    metadata_type: str | None = None
    metadata_status: str | None = None

    def flush_table() -> None:
        nonlocal table
        if len(table) >= 2:
            widths = {len(cells) for _, cells in table}
            if len(widths) > 1:
                issues.append(
                    Issue(
                        "warning",
                        path,
                        table[0][0],
                        f"table column count changes within one table: {sorted(widths)}",
                    )
                )
        table = []

    for idx, raw in enumerate(lines, start=1):
        line = raw.rstrip("\n")

        if not in_fence:
            fm = RE_FENCE.match(line)
            if fm:
                in_fence = True
                fence_char = fm.group(1)[0]
                fence_lang = fm.group(2)
                fence_start = idx
                if not fence_lang:
                    issues.append(Issue("warning", path, idx, "code fence has no language tag"))
                continue

            hm = RE_HEADING.match(line)
            if hm:
                heading_levels.append((len(hm.group(1)), idx, hm.group(2)))

            if line.strip().startswith("|") and line.count("|") >= 2:
                if not RE_SEP.match(line):
                    table.append((idx, split_cells(line)))
            else:
                flush_table()

            if idx <= 35:
                sm = RE_STATUS.match(line.strip())
                if sm:
                    metadata_status = sm.group(1).strip()
                tm = RE_TYPE.match(line.strip())
                if tm:
                    metadata_type = tm.group(1).strip()
        else:
            # Closing fence must use the same character and at least the same length.
            cm = RE_FENCE.match(line)
            if cm and cm.group(1)[0] == fence_char and len(cm.group(1)) >= 3 and not cm.group(2):
                in_fence = False
                fence_char = ""
                fence_lang = ""
            continue

        if not in_fence and not is_template:
            issues.extend(check_links(path, idx, line))

    flush_table()

    if in_fence:
        issues.append(
            Issue("error", path, fence_start, f"unclosed code fence (started with {fence_char * 3})")
        )

    # H1 / heading hierarchy
    h1 = [(ln, text) for lvl, ln, text in heading_levels if lvl == 1]
    if len(h1) == 0:
        issues.append(Issue("error", path, 1, "missing H1"))
    elif len(h1) > 1:
        issues.append(Issue("error", path, h1[1][0], "multiple H1 headings"))
    prev = 0
    for lvl, ln, text in heading_levels:
        if prev and lvl > prev + 1:
            issues.append(
                Issue("warning", path, ln, f"heading level jumps from H{prev} to H{lvl}: {text}")
            )
        prev = lvl

    # Metadata block
    if not is_metadata_exempt:
        if metadata_type is None:
            issues.append(Issue("warning", path, 1, "missing metadata line: > **类型**"))
        elif not any(t.lower() in metadata_type.lower() for t in ALLOWED_TYPE_HINTS):
            issues.append(
                Issue("warning", path, 1, f"unknown document type in metadata: {metadata_type}")
            )

        if metadata_status is None:
            issues.append(Issue("warning", path, 1, "missing metadata line: > **状态**"))
        else:
            if not metadata_status.startswith(ALLOWED_STATUS):
                issues.append(
                    Issue(
                        "error",
                        path,
                        1,
                        "status must start with one of: " + ", ".join(ALLOWED_STATUS),
                    )
                )
            elif not RE_DATE.search(metadata_status) and not (is_template and not strict_templates):
                issues.append(
                    Issue("warning", path, 1, "metadata status should include a YYYY-MM-DD date")
                )

    # Type-specific required sections (advisory)
    if metadata_type and not is_metadata_exempt and not is_template and not is_style_guide:
        h2_text = "\n".join(text for lvl, _, text in heading_levels if lvl == 2)
        required: list[tuple[str, tuple[str, ...]]] = []
        t = metadata_type.lower()
        if "how-to" in t or "操作指南" in t:
            required = [("验证", ("验证",)), ("排错", ("排错", "常见错误"))]
        elif "tutorial" in t or "教程" in t:
            required = [("步骤", ("步骤", "操作")), ("验证", ("验证",))]
        elif "reference" in t or "参考" in t:
            required = [("速查或字段", ("速查", "字段")), ("参考", ("参考",))]
        elif "explanation" in t or "解释" in t:
            required = [("结论", ("结论",)), ("参考或延伸", ("参考", "延伸"))]
        elif "case study" in t or "排障记录" in t:
            required = [
                ("现象", ("现象",)),
                ("根因", ("根因",)),
                ("参考", ("参考",)),
            ]
        for label, words in required:
            if not any(word in h2_text for word in words):
                issues.append(
                    Issue("warning", path, 1, f"type-specific section missing: {label}")
                )

    return issues


def iter_markdown(paths: list[Path]) -> list[Path]:
    files: list[Path] = []
    for base in paths:
        if base.is_file():
            if base.suffix.lower() == ".md" and base.name not in SKIP_FILES:
                files.append(base)
            continue
        for p in base.rglob("*.md"):
            if any(part in SKIP_DIRS for part in p.parts):
                continue
            if p.name in SKIP_FILES:
                continue
            files.append(p)
    return sorted(set(files))


def main() -> int:
    parser = argparse.ArgumentParser(description="Check Markdown docs against docs/STYLE_GUIDE.md")
    parser.add_argument("paths", nargs="*", help="files or directories (default: repository root)")
    parser.add_argument("--strict", action="store_true", help="treat warnings as errors")
    parser.add_argument("--quiet", action="store_true", help="only print the summary")
    args = parser.parse_args()

    bases = [Path(p) for p in args.paths] if args.paths else [ROOT]
    files = iter_markdown(bases)

    all_issues: list[Issue] = []
    for path in files:
        all_issues.extend(check_file(path))

    by_severity = {"error": 0, "warning": 0}
    for issue in all_issues:
        by_severity[issue.severity] += 1
        if not args.quiet:
            print(f"{rel(issue.path)}:{issue.line}: [{issue.severity}] {issue.message}")

    print(
        f"\nChecked {len(files)} file(s): "
        f"{by_severity['error']} error(s), {by_severity['warning']} warning(s)"
    )

    if by_severity["error"] or (args.strict and by_severity["warning"]):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
