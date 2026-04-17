# CyberWatch Dashboard

A zero-build-step threat intelligence dashboard. Single `index.html` file — open it directly in a browser or serve it via GitHub Pages. Connects to the CyberWatch REST API over HTTP(S).

## Features

- **IOC management** — submit indicators, view enrichment results, filter by type/disposition/score
- **Security events** — ingest and browse events with severity and category filters
- **Alert management** — see auto-generated high-threat alerts, acknowledge with analyst notes
- **Bulk scans** — paste up to 10,000 IOC values for batch enrichment
- **Live dashboard** — stat cards auto-refresh every 30 seconds
- **Connection settings** — configure API URL and API key in-browser, saved to localStorage

---

## Option 1 — Open locally (no server needed)

Requires the CyberWatch API to be running (see main README for `make dev`).

```bash
# macOS
open dashboard/index.html

# Linux
xdg-open dashboard/index.html

# Windows
start dashboard/index.html
```

The dashboard opens with `http://localhost:3000` as the default API URL and `dev-key-local` as the default API key — both match the Docker Compose defaults.

> **CORS note**: When opening as a `file://` URL, browsers block cross-origin requests to `localhost`.
> Serve it locally instead:
> ```bash
> make ui
> # Opens http://localhost:8080 — CORS works because origin matches
> ```

---

## Option 2 — Serve locally via make

```bash
# Starts a local HTTP server and opens the browser
make ui
```

This runs `npx serve dashboard/ -l 8080` (or `python3 -m http.server 8080 --directory dashboard`).
Your Docker Compose API at `localhost:3000` will be reachable.

---

## Option 3 — GitHub Pages (public URL, points at AWS API)

### 3.1 Enable GitHub Pages

1. Push this repo to GitHub
2. Go to **Settings → Pages**
3. Under **Source**, select **GitHub Actions**
4. Save

### 3.2 Add optional secrets (recommended)

Go to **Settings → Secrets and variables → Actions**:

| Secret | Value | Purpose |
|--------|-------|---------|
| `DASHBOARD_API_URL` | `https://api.yourdomain.com` | Pre-configures the API URL in the deployed HTML so users don't have to type it |

> The API key is **never** pre-filled in the deployed HTML — users must enter it in the Settings panel. This prevents key leakage in the public GitHub Pages source.

### 3.3 Deploy

Push to `main` or `develop` and the `pages.yml` workflow runs automatically. Your dashboard will be live at:

```
https://your-username.github.io/cyberwatch/
```

### 3.4 Configure CORS on the API

For the GitHub Pages dashboard to call your AWS API, the API must allow the GitHub Pages origin.

In your `terraform.tfvars` (or ECS environment variables), set:

```
ALLOWED_ORIGINS=https://your-username.github.io
```

Or for a custom domain:
```
ALLOWED_ORIGINS=https://dashboard.yourdomain.com
```

### 3.5 Enter your API key in the dashboard

1. Open the dashboard URL
2. Click the **⚙** gear icon at the bottom of the sidebar
3. Confirm the API URL is correct
4. Enter your API key (from `API_KEYS` env var on the API)
5. Click **Save & Reconnect**

The green dot in the sidebar confirms the API is reachable.

---

## Using the Dashboard

### Submitting an IOC
1. Go to **IOCs** tab
2. Click **+ Submit IOC**
3. Fill in the value, type, and source
4. Click **Submit for Enrichment**

The IOC appears immediately with `enrichment_status: pending`. Refresh after a few seconds to see the score, disposition, and whether an alert was fired.

### Acknowledging an Alert
1. Go to **Alerts** tab
2. Click **Acknowledge** next to an open alert
3. Enter your analyst name and any notes
4. Click **Acknowledge**

### Running a Bulk Scan
1. Go to **Bulk Scans** tab
2. Enter a scan name
3. Paste IOC values — one per line (IPs, domains, hashes all accepted)
4. Click **Submit Scan**

The scan card shows live progress and a breakdown of malicious/suspicious/benign counts.

---

## Technical Notes

- **No build step** — pure HTML + CSS + React loaded from esm.sh CDN
- **No server required** — static file, serve from anywhere
- **localStorage** — API URL and key are persisted in the browser's localStorage
- **Auto-refresh** — dashboard stats and alert badge refresh every 30 seconds; scan list refreshes every 8 seconds
- **Works offline from GitHub Pages** — the HTML and JS load from CDN; only the API calls go to your backend
