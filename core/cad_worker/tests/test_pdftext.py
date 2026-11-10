"""pdftext: page text extraction via pymupdf, CLI contract."""
import json
import subprocess
import sys
from pathlib import Path

import pymupdf

from cad_worker import pdftext as pt

REPO = Path(__file__).resolve().parent.parent


def _write_pdf(path: Path, lines: list[str], pages: int = 1):
    doc = pymupdf.open()
    for i in range(pages):
        page = doc.new_page()
        for j, line in enumerate(lines):
            page.insert_text((72, 72 + 14 * j), f"{line} (p{i + 1})")
    doc.save(str(path))
    doc.close()


def test_extracts_single_page(tmp_path):
    pdf = tmp_path / "one.pdf"
    _write_pdf(pdf, ["Width 23.8 mm"])
    result = pt.extract(str(pdf))
    assert result["ok"] is True
    assert result["pages"] == 1
    assert "Width 23.8 mm (p1)" in result["text"]


def test_extracts_multi_page_with_markers(tmp_path):
    pdf = tmp_path / "two.pdf"
    _write_pdf(pdf, ["Diameter 12"], pages=2)
    result = pt.extract(str(pdf))
    assert result["pages"] == 2
    assert "-- page 2 --" in result["text"]
    assert "Diameter 12 (p2)" in result["text"]


def test_blank_pdf_still_ok(tmp_path):
    pdf = tmp_path / "blank.pdf"
    doc = pymupdf.open()
    doc.new_page()
    doc.save(str(pdf))
    doc.close()
    result = pt.extract(str(pdf))
    assert result == {"ok": True, "text": "", "pages": 1}


def test_cli_ok_line(tmp_path):
    pdf = tmp_path / "one.pdf"
    _write_pdf(pdf, ["Radius 5"])
    proc = subprocess.run(
        [sys.executable, "-m", "cad_worker.pdftext", str(pdf)],
        capture_output=True, text=True, cwd=REPO, timeout=30)
    assert proc.returncode == 0
    payload = json.loads(proc.stdout)
    assert payload["ok"] is True and "Radius 5" in payload["text"]


def test_cli_missing_file_exit1(tmp_path):
    proc = subprocess.run(
        [sys.executable, "-m", "cad_worker.pdftext", str(tmp_path / "nope.pdf")],
        capture_output=True, text=True, cwd=REPO, timeout=30)
    assert proc.returncode == 1
    payload = json.loads(proc.stdout)
    assert payload["ok"] is False and payload["error"]
