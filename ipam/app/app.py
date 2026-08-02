"""Site IP range allocator - Azure Web App.

Give it a site code and that site's /19; it returns eight /23s, one per VLAN
(10-80), and writes the plan to Table Storage.

Two surfaces over the same logic:
  - HTML pages for humans (preview first, save second - nothing is written
    until someone confirms the plan they are looking at)
  - JSON under /api for scripts and pipelines

Deliberately session-free: the preview round-trips through the form rather
than server-side state, so there is no cookie, no secret key, and no reason
for two App Service instances to disagree.
"""

from __future__ import annotations

import csv
import io
import os

from flask import Flask, Response, jsonify, redirect, render_template, request, url_for

from allocator import CSV_COLUMNS, VLAN_IDS, AllocationError, split_site
from storage import SiteExists, StorageError, StorageNotConfigured, TableStore

app = Flask(__name__)
store = TableStore()


@app.context_processor
def template_defaults() -> dict:
    """Values every page needs, so no render_template call has to repeat them."""
    return {
        "storage_configured": store.configured,
        "vlan_ids": VLAN_IDS,
        "error": None,
        "warning": None,
        "saved": False,
        "supernet": "",
        "site_code": "",
    }


def _current_user() -> str:
    """Caller's identity, as supplied by App Service Easy Auth if enabled."""
    return request.headers.get("X-MS-CLIENT-PRINCIPAL-NAME", "")


def _recent_sites() -> tuple[list[dict], str | None]:
    """Sites for the sidebar. A storage problem shouldn't block previewing."""
    if not store.configured:
        return [], None
    try:
        return store.list_sites(), None
    except StorageError as exc:
        return [], str(exc)


# ------------------------------------------------------------------ HTML UI
@app.get("/")
def index():
    sites, warning = _recent_sites()
    return render_template(
        "index.html",
        sites=sites,
        warning=warning,
    )


@app.post("/allocate")
def allocate():
    """Preview a plan. Reads nothing, writes nothing."""
    supernet = request.form.get("supernet", "")
    site_code = request.form.get("site_code", "")

    try:
        allocation = split_site(supernet, site_code)
    except AllocationError as exc:
        sites, _ = _recent_sites()
        return (
            render_template(
                "index.html",
                sites=sites,
                error=str(exc),
                supernet=supernet,
                site_code=site_code,
            ),
            400,
        )

    return render_template(
        "result.html",
        site=allocation.as_dict(),
        stored=False,
    )


@app.post("/save")
def save():
    """Commit a previewed plan to storage."""
    supernet = request.form.get("supernet", "")
    site_code = request.form.get("site_code", "")

    try:
        allocation = split_site(supernet, site_code)
    except AllocationError as exc:
        sites, _ = _recent_sites()
        return render_template("index.html", sites=sites, error=str(exc)), 400

    try:
        store.save(allocation, created_by=_current_user())
    except StorageError as exc:
        status = 409 if isinstance(exc, SiteExists) else 503
        return (
            render_template(
                "result.html",
                site=allocation.as_dict(),
                stored=False,
                error=str(exc),
            ),
            status,
        )

    return redirect(url_for("site_detail", site_code=allocation.site_code, saved=1))


@app.get("/sites/<site_code>")
def site_detail(site_code: str):
    try:
        site = store.get_site(site_code.upper())
    except StorageError as exc:
        return render_template("index.html", sites=[], error=str(exc)), 503

    if site is None:
        sites, _ = _recent_sites()
        return (
            render_template(
                "index.html",
                sites=sites,
                error=f"No allocation stored for site {site_code.upper()}.",
            ),
            404,
        )

    return render_template(
        "result.html",
        site=site,
        stored=True,
        saved=request.args.get("saved") == "1",
    )


@app.post("/sites/<site_code>/delete")
def site_delete(site_code: str):
    try:
        store.delete_site(site_code.upper())
    except StorageError as exc:
        sites, _ = _recent_sites()
        return render_template("index.html", sites=sites, error=str(exc)), 503
    return redirect(url_for("index"))


@app.get("/sites/<site_code>.csv")
def site_csv(site_code: str):
    """Export one site's VLANs, for pasting into a build sheet."""
    try:
        site = store.get_site(site_code.upper())
    except StorageError as exc:
        return Response(str(exc), status=503, mimetype="text/plain")
    if site is None:
        return Response("Site not found", status=404, mimetype="text/plain")

    buffer = io.StringIO()
    writer = csv.writer(buffer)
    writer.writerow(CSV_COLUMNS)
    for vlan in site["vlans"]:
        record = dict(vlan) | {"site_code": site["site_code"]}
        writer.writerow([record.get(column, "") for column in CSV_COLUMNS])

    return Response(
        buffer.getvalue(),
        mimetype="text/csv",
        headers={
            "Content-Disposition": (
                f'attachment; filename="{site["site_code"]}-vlans.csv"'
            )
        },
    )


# ---------------------------------------------------------------- JSON API
@app.post("/api/allocate")
def api_allocate():
    """Preview without saving. Body: {"site_code": "...", "supernet": "..."}"""
    payload = request.get_json(silent=True) or {}
    try:
        allocation = split_site(
            payload.get("supernet", ""), payload.get("site_code", "")
        )
    except AllocationError as exc:
        return jsonify(error=str(exc)), 400
    return jsonify(allocation.as_dict())


@app.post("/api/sites")
def api_save():
    """Allocate and store in one call."""
    payload = request.get_json(silent=True) or {}
    try:
        allocation = split_site(
            payload.get("supernet", ""), payload.get("site_code", "")
        )
    except AllocationError as exc:
        return jsonify(error=str(exc)), 400

    try:
        store.save(allocation, created_by=_current_user())
    except SiteExists as exc:
        return jsonify(error=str(exc)), 409
    except StorageNotConfigured as exc:
        return jsonify(error=str(exc)), 501
    except StorageError as exc:
        return jsonify(error=str(exc)), 503

    return jsonify(allocation.as_dict()), 201


@app.get("/api/sites")
def api_list():
    try:
        return jsonify(sites=store.list_sites())
    except StorageError as exc:
        return jsonify(error=str(exc)), 503


@app.get("/api/sites/<site_code>")
def api_get(site_code: str):
    try:
        site = store.get_site(site_code.upper())
    except StorageError as exc:
        return jsonify(error=str(exc)), 503
    if site is None:
        return jsonify(error=f"No allocation stored for site {site_code.upper()}."), 404
    return jsonify(site)


@app.post("/api/sites/<site_code>/delete")
def api_delete(site_code: str):
    try:
        store.delete_site(site_code.upper())
    except StorageError as exc:
        return jsonify(error=str(exc)), 503
    return jsonify(deleted=site_code.upper())


@app.get("/api/health")
def health():
    """Liveness plus a hint at why saving might be failing."""
    return jsonify(
        status="ok",
        storage_configured=store.configured,
        table_endpoint=store.endpoint or None,
        vlans=list(VLAN_IDS),
    )


if __name__ == "__main__":
    # Local development only. App Service runs this through gunicorn.
    app.run(host="127.0.0.1", port=int(os.environ.get("PORT", 8000)), debug=True)
