const form = document.getElementById("upload-form");
const statusEl = document.getElementById("status");
const results = document.getElementById("results");
const output = document.getElementById("output");
const historyBody = document.getElementById("history-body");

function escapeHtml(str) {
  const el = document.createElement("span");
  el.textContent = String(str ?? "");
  return el.innerHTML;
}

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  const fileInput = document.getElementById("file");
  if (!fileInput.files.length) {
    statusEl.textContent = "Choose a CSV file first.";
    return;
  }

  const body = new FormData();
  body.append("file", fileInput.files[0]);
  statusEl.textContent = "Processing…";
  results.hidden = true;

  try {
    const response = await fetch("/api/process", { method: "POST", body });
    const data = await response.json();
    if (!response.ok) {
      throw new Error(data.error || "Processing failed");
    }

    const lines = data.rows.map((row) => {
      const f = row.fields;
      if (f.product_id !== undefined) {
        return `Line ${row.line}: ${f.product_id} | ${f.product_name} | ${f.price}`;
      }
      return `Line ${row.line}: ${JSON.stringify(f)}`;
    });
    output.textContent = lines.join("\n");
    results.hidden = false;
    const s3msg = data.entry.s3_uri ? ` Uploaded to ${data.entry.s3_uri}.` : "";
    statusEl.textContent = `Processed ${data.entry.filename} (${data.entry.row_count} rows).${s3msg}`;

    await refreshHistory();
    form.reset();
  } catch (err) {
    statusEl.textContent = err.message;
  }
});

async function refreshHistory() {
  const response = await fetch("/api/history");
  const items = await response.json();
  historyBody.innerHTML = items
    .map(
      (item) => `<tr>
        <td>${escapeHtml(item.processed_at)}</td>
        <td>${escapeHtml(item.filename)}</td>
        <td>${escapeHtml(item.row_count)}</td>
        <td><code>${escapeHtml(item.s3_uri || "—")}</code></td>
      </tr>`
    )
    .join("");
}
