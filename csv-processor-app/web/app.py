import csv
import io
import json
import os
from datetime import datetime, timezone
from pathlib import Path

import boto3
from flask import Flask, jsonify, render_template, request
from werkzeug.utils import secure_filename

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = int(os.getenv("MAX_UPLOAD_BYTES", 10 * 1024 * 1024))
app.config["UPLOAD_DIR"] = Path(os.getenv("UPLOAD_DIR", "/data/uploads"))
app.config["HISTORY_FILE"] = Path(os.getenv("HISTORY_FILE", "/data/history/processed.json"))
app.config["STATIC_SHARED"] = Path(os.getenv("STATIC_SHARED", "/shared/public"))

ALLOWED_EXTENSIONS = {".csv"}

# SOH export format (no header): "product_id","product_name","price"
SOH_FIELDNAMES = ("product_id", "product_name", "price")


def _ensure_dirs() -> None:
    app.config["UPLOAD_DIR"].mkdir(parents=True, exist_ok=True)
    app.config["HISTORY_FILE"].parent.mkdir(parents=True, exist_ok=True)
    app.config["STATIC_SHARED"].mkdir(parents=True, exist_ok=True)


def _allowed(filename: str) -> bool:
    return Path(filename).suffix.lower() in ALLOWED_EXTENSIONS


def _load_history() -> list[dict]:
    if not app.config["HISTORY_FILE"].exists():
        return []
    with app.config["HISTORY_FILE"].open(encoding="utf-8") as fh:
        return json.load(fh)


def _save_history(entries: list[dict]) -> None:
    path = app.config["HISTORY_FILE"]
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(entries, indent=2), encoding="utf-8")
    tmp.replace(path)


def _write_history_entry(entry: dict) -> None:
    """Persist entry locally AND to S3 (when configured) for cross-pod consistency."""
    local = _load_history()
    local.insert(0, entry)
    _save_history(local[:100])

    bucket = os.getenv("S3_BUCKET")
    if not bucket:
        return
    try:
        _s3_client().put_object(
            Bucket=bucket,
            Key=f"history/{entry['id']}.json",
            Body=json.dumps(entry, default=str).encode(),
            ContentType="application/json",
        )
    except Exception:
        pass


def _get_history() -> list[dict]:
    """Return history from S3 when configured (consistent across replicas), else local file."""
    bucket = os.getenv("S3_BUCKET")
    if not bucket:
        return _load_history()
    try:
        client = _s3_client()
        paginator = client.get_paginator("list_objects_v2")
        entries = []
        for page in paginator.paginate(Bucket=bucket, Prefix="history/"):
            for obj in page.get("Contents", []):
                body = client.get_object(Bucket=bucket, Key=obj["Key"])["Body"].read()
                entries.append(json.loads(body.decode()))
        entries.sort(key=lambda e: e.get("id", ""), reverse=True)
        return entries[:100]
    except Exception:
        return _load_history()


def _normalize_field(value: str) -> str:
    return (value or "").strip().strip('"')


def _is_soh_headerless_row(cells: list[str]) -> bool:
    if len(cells) != 3:
        return False
    product_id = _normalize_field(cells[0])
    return product_id.isdigit()


def _parse_csv(content: bytes) -> list[dict]:
    text = content.decode("utf-8-sig").strip()
    if not text:
        raise ValueError("CSV file is empty")

    buf = io.StringIO(text)
    peek_reader = csv.reader(buf)
    first_row = next(peek_reader, None)
    if not first_row:
        raise ValueError("CSV file is empty")

    buf.seek(0)
    if _is_soh_headerless_row(first_row):
        reader = csv.DictReader(buf, fieldnames=SOH_FIELDNAMES)
        start_line = 1
    else:
        reader = csv.DictReader(buf)
        if not reader.fieldnames:
            raise ValueError(
                "Unrecognized CSV format. Expected SOH rows "
                '(product_id, product_name, price) or a header row.'
            )
        start_line = 2

    rows = []
    for idx, row in enumerate(reader, start=start_line):
        fields = {k: _normalize_field(v) for k, v in row.items() if k}
        if not any(fields.values()):
            continue
        rows.append({"line": idx, "fields": fields})
    if not rows:
        raise ValueError("No data rows found in CSV")
    return rows


def _s3_client():
    region = os.getenv("AWS_REGION", "us-east-1")
    endpoint = os.getenv("S3_ENDPOINT_URL")
    kwargs = {"region_name": region}
    if endpoint:
        kwargs["endpoint_url"] = endpoint
    return boto3.client("s3", **kwargs)


def _upload_to_s3(content: bytes, key: str) -> str:
    bucket = os.getenv("S3_BUCKET")
    if not bucket:
        return ""
    storage_class = os.getenv("S3_STORAGE_CLASS", "STANDARD")
    _s3_client().put_object(
        Bucket=bucket,
        Key=key,
        Body=content,
        StorageClass=storage_class or "STANDARD",
    )
    return f"s3://{bucket}/{key}"


_ensure_dirs()


@app.route("/")
def index():
    return render_template("index.html", history=_get_history())


@app.route("/api/process", methods=["POST"])
def process_csv():
    if "file" not in request.files:
        return jsonify({"error": "No file uploaded"}), 400
    uploaded = request.files["file"]
    if not uploaded.filename:
        return jsonify({"error": "Empty filename"}), 400
    filename = secure_filename(uploaded.filename)
    if not _allowed(filename):
        return jsonify({"error": "Only .csv files are allowed"}), 400

    raw = uploaded.read()
    try:
        rows = _parse_csv(raw)
    except Exception as exc:
        return jsonify({"error": str(exc)}), 400

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    stored_name = f"{stamp}_{filename}"
    local_path = app.config["UPLOAD_DIR"] / stored_name
    local_path.write_bytes(raw)

    s3_key = f"processed/{stamp}/{filename}"
    s3_uri = ""
    try:
        s3_uri = _upload_to_s3(raw, s3_key)
    except Exception as exc:
        return jsonify({"error": f"S3 upload failed: {exc}"}), 500

    entry = {
        "id": stamp,
        "filename": filename,
        "stored_name": stored_name,
        "processed_at": datetime.now(timezone.utc).isoformat(),
        "row_count": len(rows),
        "s3_uri": s3_uri,
        "s3_key": s3_key,
    }
    _write_history_entry(entry)

    return jsonify({"entry": entry, "rows": rows})


@app.route("/api/history")
def history():
    return jsonify(_get_history())


@app.route("/health")
def health():
    return jsonify({"status": "ok"})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.getenv("APP_PORT", "8080")))
