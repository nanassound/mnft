"""Extract text from a PDF for the LLM prompt (pymupdf; no poppler needed).

One-shot CLI: one JSON line on stdout.
  exit 0 -> {"ok": true, "text": "...", "pages": n}
  exit 1 -> {"ok": false, "error": "human reason"}

Pages after the first are separated by "-- page N --" markers. Empty text is
still ok: true — the caller decides whether to ask about a scanned PDF. The
input file is never modified.
"""
from __future__ import annotations

import json
import sys

import pymupdf


def extract(path: str) -> dict:
    doc = pymupdf.open(path)
    try:
        chunks = [page.get_text("text") for page in doc]
        pages = doc.page_count
    finally:
        doc.close()
    text = ""
    for i, chunk in enumerate(chunks, 1):
        if i > 1:
            text += f"\n-- page {i} --\n"
        text += chunk
    return {"ok": True, "text": text, "pages": pages}


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        sys.stderr.write("usage: python -m cad_worker.pdftext IN.pdf\n")
        return 3
    try:
        result = extract(argv[0])
    except Exception as exc:
        sys.stdout.write(json.dumps({"ok": False, "error": str(exc)}) + "\n")
        return 1
    sys.stdout.write(json.dumps(result) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
