"""minicloud external heartbeat (ADR-0002, Anchor 1).

One Lambda, two triggers — mode is detected from the event:
  * EventBridge schedule  -> probe every target, store status in DynamoDB, SNS on transition.
  * Function URL (public) -> render the status page (HTML, or JSON at */status.json).

It runs OUTSIDE the home failure domain, so it can report a total-site outage the in-cluster
Prometheus cannot (control-plane / DNS / ingress / power loss). Read-only observer: it never
touches the cluster, only fetches public URLs. Stdlib-only HTTP (urllib) + boto3 (Lambda-provided)
so the deployment zip is just this file — no vendored deps.

Security (ADR-0002): the public page whitelists name/status/since ONLY — never URLs, HTTP bodies,
versions, or internal IPs. A target is "up" if it ANSWERS with any HTTP < 500 (a 302 to SSO or a
401 still means the external path is alive); >=500 or a connection error is "down".
"""

import json
import os
import time
import urllib.error
import urllib.request

import boto3

STATUS_TABLE = os.environ["STATUS_TABLE"]
SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN", "")
TARGETS = json.loads(os.environ.get("TARGETS", "[]"))  # [{"name": "...", "url": "https://..."}]
PROBE_TIMEOUT = float(os.environ.get("PROBE_TIMEOUT", "8"))

_ddb = boto3.resource("dynamodb").Table(STATUS_TABLE)
_sns = boto3.client("sns")


def _probe(url):
    """Return (up: bool, detail: str). Any HTTP < 500 = up (SSO 302 / 401 still means alive)."""
    req = urllib.request.Request(
        url, method="GET", headers={"User-Agent": "minicloud-heartbeat/1.0"}
    )
    try:
        with urllib.request.urlopen(req, timeout=PROBE_TIMEOUT) as resp:
            code = resp.status
    except urllib.error.HTTPError as exc:  # 3xx/4xx still reached the app
        code = exc.code
    except Exception as exc:  # DNS / TLS / connection / timeout = down
        return False, f"error: {str(exc)[:100]}"
    return code < 500, f"HTTP {code}"


def _run_probes():
    now = int(time.time())
    for target in TARGETS:
        up, detail = _probe(target["url"])
        status = "UP" if up else "DOWN"
        prev = _ddb.get_item(Key={"target": target["name"]}).get("Item")
        prev_status = prev.get("status") if prev else None
        first_seen = prev_status is None
        changed = (not first_seen) and prev_status != status
        last_change = now if (changed or first_seen) else int(prev["lastChange"])

        _ddb.put_item(
            Item={
                "target": target["name"],
                "url": target["url"],
                "status": status,
                "detail": detail,
                "lastCheck": now,
                "lastChange": last_change,
            }
        )
        # Alert ONLY on a real transition (not every tick, not first-seen).
        if changed and SNS_TOPIC_ARN:
            _sns.publish(
                TopicArn=SNS_TOPIC_ARN,
                Subject=f"[minicloud] {target['name']} is {status}",
                Message=(
                    f"{target['name']} transitioned {prev_status} -> {status} "
                    f"at {now} ({detail}). Probed from AWS (external vantage)."
                ),
            )
    return {"checked": len(TARGETS), "at": now}


def _safe_view():
    """Whitelist ONLY safe fields for the public page — no url/detail/internal data."""
    items = _ddb.scan().get("Items", [])
    return sorted(
        (
            {
                "name": i["target"],
                "status": i["status"],
                "since": int(i.get("lastChange", 0)),
                "lastCheck": int(i.get("lastCheck", 0)),
            }
            for i in items
        ),
        key=lambda x: x["name"],
    )


def _html(view, generated):
    rows = "".join(
        f'<tr><td>{t["name"]}</td>'
        f'<td class="{"up" if t["status"] == "UP" else "down"}">{t["status"]}</td>'
        f'<td>{max(0, generated - t["since"]) // 60} min</td></tr>'
        for t in view
    )
    overall = "ALL SYSTEMS OPERATIONAL" if all(t["status"] == "UP" for t in view) else "DEGRADED"
    return (
        "<!doctype html><html><head><meta charset=utf-8>"
        "<meta name=viewport content='width=device-width,initial-scale=1'>"
        "<title>minicloud status</title><style>"
        "body{font-family:system-ui,sans-serif;max-width:640px;margin:3rem auto;padding:0 1rem}"
        "h1{font-size:1.3rem}table{width:100%;border-collapse:collapse;margin-top:1rem}"
        "td,th{text-align:left;padding:.5rem;border-bottom:1px solid #eee}"
        ".up{color:#16794c;font-weight:600}.down{color:#c0392b;font-weight:600}"
        "small{color:#888}</style></head><body>"
        f"<h1>minicloud — {overall}</h1>"
        "<table><tr><th>Service</th><th>Status</th><th>For</th></tr>"
        f"{rows}</table>"
        f"<p><small>External probe (AWS). Generated {generated} UTC epoch. "
        "Independent of the home site.</small></p></body></html>"
    )


def handler(event, context):
    # Function URL invoke carries requestContext; EventBridge schedule does not.
    if "requestContext" in event:
        view = _safe_view()
        generated = int(time.time())
        if event.get("rawPath", "/").endswith(".json"):
            return {
                "statusCode": 200,
                "headers": {"content-type": "application/json", "cache-control": "no-store"},
                "body": json.dumps({"service": "minicloud", "generated": generated, "targets": view}),
            }
        return {
            "statusCode": 200,
            "headers": {"content-type": "text/html; charset=utf-8", "cache-control": "no-store"},
            "body": _html(view, generated),
        }
    return _run_probes()
