"""
Tests for the CSV processor Flask app.
Env vars are set before importing app.py so _ensure_dirs() uses writable tmp paths.
"""
import io
import json
import os
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

# Configure dirs before importing app (module-level _ensure_dirs() runs on import)
_BASE = Path("/tmp/csv-processor-test")
os.environ.update(
    {
        "UPLOAD_DIR": str(_BASE / "uploads"),
        "HISTORY_FILE": str(_BASE / "history" / "processed.json"),
        "STATIC_SHARED": str(_BASE / "static"),
        "S3_BUCKET": "",
    }
)

sys.path.insert(0, str(Path(__file__).parent.parent))
from app import (  # noqa: E402
    _get_history,
    _load_history,
    _parse_csv,
    _save_history,
    _write_history_entry,
    app as flask_app,
)


# ── fixtures ────────────────────────────────────────────────────────────────

@pytest.fixture()
def client(tmp_path):
    flask_app.config["UPLOAD_DIR"] = tmp_path / "uploads"
    flask_app.config["HISTORY_FILE"] = tmp_path / "history" / "processed.json"
    flask_app.config["STATIC_SHARED"] = tmp_path / "static"
    flask_app.config["TESTING"] = True
    (tmp_path / "uploads").mkdir(parents=True)
    (tmp_path / "history").mkdir(parents=True)
    (tmp_path / "static").mkdir(parents=True)
    with flask_app.test_client() as c:
        yield c


# ── _parse_csv ───────────────────────────────────────────────────────────────

SOH_ROWS = b'"211627629","Purple Kaftan","4900.0000"\n"211627630","Blue Dress","3500.0000"\n'
HEADER_ROWS = b"product_id,product_name,price\n123,Widget,9.99\n456,Gadget,19.99\n"


def test_parse_soh_format():
    rows = _parse_csv(SOH_ROWS)
    assert len(rows) == 2
    assert rows[0]["fields"]["product_id"] == "211627629"
    assert rows[0]["fields"]["product_name"] == "Purple Kaftan"
    assert rows[0]["fields"]["price"] == "4900.0000"
    assert rows[0]["line"] == 1


def test_parse_header_format():
    rows = _parse_csv(HEADER_ROWS)
    assert len(rows) == 2
    assert rows[0]["fields"]["product_id"] == "123"
    assert rows[1]["fields"]["product_name"] == "Gadget"


def test_parse_empty_raises():
    with pytest.raises(ValueError, match="empty"):
        _parse_csv(b"")


def test_parse_whitespace_only_raises():
    with pytest.raises(ValueError, match="empty"):
        _parse_csv(b"   \n  ")


def test_parse_skips_blank_lines():
    content = b'"123","Widget","9.99"\n\n"456","Gadget","19.99"\n'
    rows = _parse_csv(content)
    assert len(rows) == 2


def test_parse_bom_stripped():
    content = b"\xef\xbb\xbf\"123\",\"Widget\",\"9.99\"\n"
    rows = _parse_csv(content)
    assert rows[0]["fields"]["product_id"] == "123"


def test_parse_real_soh_sample():
    sample = Path(__file__).parent.parent.parent / "sample-data" / "soh.csv"
    if not sample.exists():
        pytest.skip("soh.csv not present")
    rows = _parse_csv(sample.read_bytes())
    assert len(rows) > 700
    assert rows[0]["fields"]["product_id"] == "211627629"


# ── history helpers ──────────────────────────────────────────────────────────

def test_history_round_trip(tmp_path):
    flask_app.config["HISTORY_FILE"] = tmp_path / "history" / "processed.json"
    (tmp_path / "history").mkdir()
    entry = {"id": "abc", "filename": "f.csv", "row_count": 5}
    _save_history([entry])
    loaded = _load_history()
    assert loaded == [entry]


def test_history_missing_file_returns_empty(tmp_path):
    flask_app.config["HISTORY_FILE"] = tmp_path / "missing.json"
    assert _load_history() == []


def test_write_history_entry_s3_success(tmp_path):
    flask_app.config["HISTORY_FILE"] = tmp_path / "history" / "processed.json"
    (tmp_path / "history").mkdir()
    entry = {"id": "20260101T120000000000Z", "filename": "f.csv", "row_count": 3}
    mock_client = MagicMock()
    with patch("app.os.getenv", side_effect=lambda k, d=None: "test-bucket" if k == "S3_BUCKET" else os.environ.get(k, d)):
        with patch("app._s3_client", return_value=mock_client):
            _write_history_entry(entry)
    mock_client.put_object.assert_called_once()
    assert mock_client.put_object.call_args.kwargs["Key"] == f"history/{entry['id']}.json"
    assert _load_history() == [entry]


def test_write_history_entry_s3_failure_still_saves_local(tmp_path):
    flask_app.config["HISTORY_FILE"] = tmp_path / "history" / "processed.json"
    (tmp_path / "history").mkdir()
    entry = {"id": "20260101T120000000000Z", "filename": "f.csv", "row_count": 3}
    mock_client = MagicMock()
    mock_client.put_object.side_effect = Exception("connection refused")
    with patch("app.os.getenv", side_effect=lambda k, d=None: "test-bucket" if k == "S3_BUCKET" else os.environ.get(k, d)):
        with patch("app._s3_client", return_value=mock_client):
            _write_history_entry(entry)
    assert _load_history() == [entry]


def test_get_history_from_s3(tmp_path):
    flask_app.config["HISTORY_FILE"] = tmp_path / "history" / "processed.json"
    older = {"id": "aaa", "filename": "old.csv", "row_count": 1}
    newer = {"id": "zzz", "filename": "new.csv", "row_count": 2}
    mock_client = MagicMock()
    mock_client.get_paginator.return_value.paginate.return_value = [
        {
            "Contents": [
                {"Key": "history/aaa.json"},
                {"Key": "history/zzz.json"},
            ]
        }
    ]
    mock_client.get_object.side_effect = [
        {"Body": MagicMock(read=lambda: json.dumps(older).encode())},
        {"Body": MagicMock(read=lambda: json.dumps(newer).encode())},
    ]
    with patch("app.os.getenv", side_effect=lambda k, d=None: "test-bucket" if k == "S3_BUCKET" else os.environ.get(k, d)):
        with patch("app._s3_client", return_value=mock_client):
            entries = _get_history()
    assert entries == [newer, older]


def test_get_history_s3_failure_falls_back_to_local(tmp_path):
    flask_app.config["HISTORY_FILE"] = tmp_path / "history" / "processed.json"
    (tmp_path / "history").mkdir()
    local_entry = {"id": "local", "filename": "local.csv", "row_count": 4}
    _save_history([local_entry])
    with patch("app.os.getenv", side_effect=lambda k, d=None: "test-bucket" if k == "S3_BUCKET" else os.environ.get(k, d)):
        with patch("app._s3_client", side_effect=Exception("denied")):
            assert _get_history() == [local_entry]


# ── routes ──────────────────────────────────────────────────────────────────

def test_health(client):
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json["status"] == "ok"


def test_history_empty(client):
    resp = client.get("/api/history")
    assert resp.status_code == 200
    assert resp.json == []


def test_upload_no_file(client):
    resp = client.post("/api/process")
    assert resp.status_code == 400
    assert "error" in resp.json


def test_upload_wrong_extension(client):
    data = {"file": (io.BytesIO(b"col1,col2\n1,2"), "test.txt")}
    resp = client.post("/api/process", data=data, content_type="multipart/form-data")
    assert resp.status_code == 400
    assert "csv" in resp.json["error"].lower()


def test_upload_empty_csv(client):
    data = {"file": (io.BytesIO(b""), "test.csv")}
    resp = client.post("/api/process", data=data, content_type="multipart/form-data")
    assert resp.status_code == 400
    assert "empty" in resp.json["error"].lower()


def test_upload_valid_soh_no_s3(client):
    data = {"file": (io.BytesIO(SOH_ROWS), "soh.csv")}
    resp = client.post("/api/process", data=data, content_type="multipart/form-data")
    assert resp.status_code == 200
    assert resp.json["entry"]["row_count"] == 2
    assert resp.json["entry"]["s3_uri"] == ""
    assert len(resp.json["rows"]) == 2


def test_upload_valid_header_csv_no_s3(client):
    data = {"file": (io.BytesIO(HEADER_ROWS), "data.csv")}
    resp = client.post("/api/process", data=data, content_type="multipart/form-data")
    assert resp.status_code == 200
    assert resp.json["entry"]["row_count"] == 2


def test_upload_appears_in_history(client):
    data = {"file": (io.BytesIO(SOH_ROWS), "soh.csv")}
    client.post("/api/process", data=data, content_type="multipart/form-data")
    hist = client.get("/api/history").json
    assert len(hist) == 1
    assert hist[0]["filename"] == "soh.csv"


def test_upload_s3_failure_returns_500(client):
    with patch("app.os.getenv", side_effect=lambda k, d=None: "test-bucket" if k == "S3_BUCKET" else os.environ.get(k, d)):
        with patch("app._s3_client") as mock_s3:
            mock_s3.return_value.put_object.side_effect = Exception("connection refused")
            data = {"file": (io.BytesIO(SOH_ROWS), "soh.csv")}
            resp = client.post("/api/process", data=data, content_type="multipart/form-data")
    assert resp.status_code == 500
    assert "S3" in resp.json["error"]


def test_index_renders(client):
    resp = client.get("/")
    assert resp.status_code == 200
    assert b"CSV Processor" in resp.data
