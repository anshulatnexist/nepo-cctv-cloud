#!/usr/bin/env bash
# =============================================================================
#  The Nepo Team – Cloud CCTV viewer (Noida NVR -> HTTPS web page for AbleSign)
#  Target: fresh Ubuntu 24.04 LTS droplet (DigitalOcean, BLR1 Bangalore)
#  Stack : go2rtc 1.9.15 (pulls RTSP from the NVR)  +  Caddy 2.10.2 (HTTPS, IP lock)
#
#  Run as root:      bash install.sh
#  Change settings:  bash install.sh        (re-run; current values are offered as defaults)
#  New secret link:  bash install.sh --new-token
# =============================================================================
set -euo pipefail

APP_DIR=/opt/nepo-cctv
SETTINGS="$APP_DIR/settings.env"
GO2RTC_IMAGE="alexxit/go2rtc:1.9.15"
CADDY_IMAGE="caddy:2.10.2"

c_ok()   { printf '\033[32m%s\033[0m\n' "$*"; }
c_warn() { printf '\033[33m%s\033[0m\n' "$*"; }
c_err()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }
die()    { c_err "ERROR: $*"; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root (sudo -i first)."
command -v apt-get >/dev/null || die "This script expects Ubuntu/Debian."

NEW_TOKEN=0
[[ "${1:-}" == "--new-token" ]] && NEW_TOKEN=1

mkdir -p "$APP_DIR/www"
chmod 700 "$APP_DIR"

# ---------- load previous answers (re-run support) ----------
if [[ -f "$SETTINGS" ]]; then
  # shellcheck disable=SC1090
  source "$SETTINGS"
  echo "Existing settings found – press Enter to keep each current value."
fi

ask() {  # ask VAR "Question" "default"
  local var=$1 q=$2 def=${3:-} ans
  read -r -p "$q${def:+ [$def]}: " ans || true
  printf -v "$var" '%s' "${ans:-$def}"
}

echo
echo "=== The Nepo Team – Cloud CCTV setup ==="
echo
ask DOMAIN        "Web address for the camera page"                        "${DOMAIN:-cctv.thenepoteam.com}"
ask LE_EMAIL      "Email for HTTPS certificate notices"                    "${LE_EMAIL:-}"
ask NOIDA_IP      "Noida office static public IP"                          "${NOIDA_IP:-}"
ask RTSP_PORT     "External RTSP port forwarded on the Noida router"       "${RTSP_PORT:-42554}"
ask NVR_USER      "NVR view-only username"                                 "${NVR_USER:-signage}"
if [[ -n "${NVR_PASS:-}" ]]; then
  read -r -s -p "NVR password for '$NVR_USER' [Enter = keep current]: " p || true; echo
  NVR_PASS=${p:-$NVR_PASS}
else
  read -r -s -p "NVR password for '$NVR_USER': " NVR_PASS; echo
fi
ask ALLOWED_IPS   "Public IP(s) allowed to view, space-separated (AU office first)" "${ALLOWED_IPS:-}"
ask CAMERAS       "Cameras as Name:Channel, comma-separated"               "${CAMERAS:-Reception:1,Director Room:2,Balcony:3,Office:4,Office B:5}"
ask STREAM_TYPE   "Stream quality – sub (recommended) or main"             "${STREAM_TYPE:-sub}"

[[ -n "$DOMAIN" && -n "$NOIDA_IP" && -n "$NVR_PASS" && -n "$ALLOWED_IPS" && -n "$CAMERAS" ]] \
  || die "Domain, Noida IP, NVR password, allowed IPs and cameras are all required."
[[ "$RTSP_PORT" =~ ^[0-9]+$ ]] || die "RTSP port must be a number."
case "$STREAM_TYPE" in sub) SUFFIX=02 ;; main) SUFFIX=01 ;; *) die "Stream quality must be 'sub' or 'main'." ;; esac
for ip in $ALLOWED_IPS; do
  [[ "$ip" =~ ^[0-9a-fA-F:.]+(/[0-9]{1,3})?$ ]] || die "Not an IP address/range: $ip"
done

if [[ -z "${TOKEN:-}" || $NEW_TOKEN -eq 1 ]]; then
  TOKEN=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
fi

umask 077
cat > "$SETTINGS" <<EOF
DOMAIN=$(printf '%q' "$DOMAIN")
LE_EMAIL=$(printf '%q' "$LE_EMAIL")
NOIDA_IP=$(printf '%q' "$NOIDA_IP")
RTSP_PORT=$(printf '%q' "$RTSP_PORT")
NVR_USER=$(printf '%q' "$NVR_USER")
NVR_PASS=$(printf '%q' "$NVR_PASS")
ALLOWED_IPS=$(printf '%q' "$ALLOWED_IPS")
CAMERAS=$(printf '%q' "$CAMERAS")
STREAM_TYPE=$(printf '%q' "$STREAM_TYPE")
TOKEN=$(printf '%q' "$TOKEN")
EOF
umask 022

# ---------- packages ----------
echo; echo "Installing Docker and firewall (first run takes ~2 minutes)…"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl ufw python3 dnsutils >/dev/null
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sh >/dev/null
fi
systemctl enable --now docker >/dev/null

ufw allow OpenSSH >/dev/null
ufw allow 80/tcp  >/dev/null
ufw allow 443/tcp >/dev/null
ufw allow 443/udp >/dev/null
ufw --force enable >/dev/null

# ---------- generate config ----------
export NOIDA_IP RTSP_PORT NVR_USER NVR_PASS CAMERAS SUFFIX TOKEN APP_DIR
python3 - <<'PY'
import os, json, re, urllib.parse
user = urllib.parse.quote(os.environ["NVR_USER"], safe="")
pw   = urllib.parse.quote(os.environ["NVR_PASS"], safe="")
host, port, suffix = os.environ["NOIDA_IP"], os.environ["RTSP_PORT"], os.environ["SUFFIX"]
if ":" in host and not host.startswith("["): host = f"[{host}]"
cams, seen = [], set()
for item in os.environ["CAMERAS"].split(","):
    item = item.strip()
    if not item: continue
    name, _, ch = item.rpartition(":")
    if not name or not ch.strip().isdigit():
        raise SystemExit(f"Bad camera entry '{item}' – use Name:Channel, e.g. Reception:1")
    cid = re.sub(r"[^a-z0-9]+", "_", name.lower()).strip("_") or f"cam{ch}"
    while cid in seen: cid += "_"
    seen.add(cid)
    cams.append({"id": cid, "name": name.strip(), "channel": int(ch)})
app = os.environ["APP_DIR"]
lines = [
    "# Generated by install.sh – edit via re-running install.sh",
    "log:", "  level: info",
    "api:", '  listen: "127.0.0.1:1984"', f'  base_path: "/{os.environ["TOKEN"]}"',
    "rtsp:", '  listen: ""',
    "webrtc:", '  listen: ""',
    "srtp:", '  listen: ""',
    "streams:",
]
for c in cams:
    url = f"rtsp://{user}:{pw}@{host}:{port}/Streaming/Channels/{c['channel']}{suffix}"
    lines.append(f"  {c['id']}: {json.dumps(url)}")
with open(f"{app}/go2rtc.yaml", "w") as f: f.write("\n".join(lines) + "\n")
os.chmod(f"{app}/go2rtc.yaml", 0o600)
with open(f"{app}/www/cameras.json", "w") as f:
    json.dump([{"id": c["id"], "name": c["name"]} for c in cams], f, indent=2)
print(f"  {len(cams)} camera(s): " + ", ".join(f"{c['name']} (ch{c['channel']})" for c in cams))
PY

GLOBAL_BLOCK=""
[[ -n "$LE_EMAIL" ]] && GLOBAL_BLOCK=$(printf '{\n\temail %s\n}\n' "$LE_EMAIL")

cat > "$APP_DIR/Caddyfile" <<EOF
$GLOBAL_BLOCK

$DOMAIN {
	encode gzip
	header {
		-Server
		Referrer-Policy no-referrer
		X-Robots-Tag "noindex, nofollow"
		X-Content-Type-Options nosniff
		Cache-Control no-store
	}
	log {
		output stdout
		format console
	}

	route {
		# 1) Only the allowed public IPs get anything at all
		@outsider not remote_ip $ALLOWED_IPS
		respond @outsider 404

		# 2) Viewer page + camera list (served by Caddy)
		redir /$TOKEN /$TOKEN/ 308
		@page path /$TOKEN/ /$TOKEN/index.html /$TOKEN/cameras.json
		handle @page {
			uri strip_prefix /$TOKEN
			root * /srv/www
			file_server
		}

		# 3) Only the player script, live video socket and snapshots reach go2rtc.
		#    Its admin UI, config and stream list (which contain the NVR password) stay blocked.
		@player path /$TOKEN/video-rtc.js /$TOKEN/api/ws /$TOKEN/api/frame.jpeg
		handle @player {
			reverse_proxy 127.0.0.1:1984
		}

		# 4) Everything else
		respond 404
	}
}
EOF

cat > "$APP_DIR/docker-compose.yml" <<EOF
services:
  go2rtc:
    image: $GO2RTC_IMAGE
    container_name: nepo-go2rtc
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./go2rtc.yaml:/config/go2rtc.yaml:ro
    logging: { driver: json-file, options: { max-size: "10m", max-file: "3" } }

  caddy:
    image: $CADDY_IMAGE
    container_name: nepo-caddy
    restart: unless-stopped
    depends_on: [go2rtc]
    network_mode: host          # Caddy sees the viewer's real IP for the IP lock
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./www:/srv/www:ro
      - caddy_data:/data
      - caddy_config:/config
    logging: { driver: json-file, options: { max-size: "10m", max-file: "3" } }

volumes:
  caddy_data:
  caddy_config:
EOF

# ---------- viewer page ----------
cat > "$APP_DIR/www/index.html" <<'HTML_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<meta name="referrer" content="no-referrer">
<title>The Nepo Team – Live CCTV</title>
<style>
  :root { --bg:#0B0F19; --tile:#111827; --line:#1F2937; --text:#F3F4F6; --muted:#9CA3AF; --cyan:#00D2FE; --red:#EF4444; }
  * { box-sizing:border-box; }
  html, body { margin:0; height:100%; background:var(--bg); color:var(--text);
    font-family: system-ui, -apple-system, "Segoe UI", Roboto, Arial, sans-serif; overflow:hidden; cursor:none; }
  header { position:fixed; top:0; left:0; right:0; height:40px; display:flex; align-items:center;
    justify-content:space-between; padding:0 16px; font-size:15px; z-index:5;
    background:linear-gradient(var(--bg), rgba(11,15,25,0)); }
  header b { color:var(--cyan); letter-spacing:.08em; }
  #clock { color:var(--muted); font-variant-numeric:tabular-nums; }
  #grid { position:absolute; inset:40px 6px 6px 6px; display:grid; gap:6px; }
  .tile { position:relative; background:var(--tile); border:1px solid var(--line); border-radius:6px; overflow:hidden; min-width:0; min-height:0; }
  .tile cam-view, .tile video { position:absolute; inset:0; width:100%; height:100%; object-fit:contain; background:#000; display:block; }
  .label { position:absolute; left:8px; bottom:8px; z-index:2; padding:3px 8px; border-radius:4px;
    background:rgba(0,0,0,.6); font-size:14px; font-weight:600; }
  .dot { display:inline-block; width:8px; height:8px; border-radius:50%; background:var(--muted); margin-right:6px; vertical-align:middle; }
  .live .dot { background:var(--red); }
  #msg { position:absolute; inset:0; display:flex; align-items:center; justify-content:center; color:var(--muted); font-size:18px; }
</style>
</head>
<body>
<header><span><b>THE NEPO TEAM</b> · Noida live view</span><span id="clock"></span></header>
<div id="grid"></div>
<div id="msg">Loading cameras…</div>

<script type="module">
  // go2rtc's player (served from the same token path by go2rtc itself)
  import { VideoRTC } from './video-rtc.js';

  class CamView extends VideoRTC {
    oninit() {
      super.oninit();
      this.video.controls = false;
      this.video.muted = true;
      this.video.playsInline = true;
      this.background = true;          // keep playing even if the page is "hidden" (signage players)
      this.visibilityCheck = false;
    }
  }
  customElements.define('cam-view', CamView);

  // Clock in India time (the camera site)
  const clock = document.getElementById('clock');
  const fmt = new Intl.DateTimeFormat('en-IN', { timeZone:'Asia/Kolkata', weekday:'short', day:'2-digit', month:'short',
    hour:'2-digit', minute:'2-digit', second:'2-digit', hour12:false });
  const tick = () => clock.textContent = fmt.format(new Date()) + ' IST';
  tick(); setInterval(tick, 1000);

  // Optional URL filters: ?cams=reception,office  ?cols=3
  const params = new URLSearchParams(location.search);
  const only = (params.get('cams') || '').split(',').map(s => s.trim()).filter(Boolean);

  const res = await fetch('cameras.json', { cache:'no-store' });
  let cams = await res.json();
  if (only.length) cams = cams.filter(c => only.includes(c.id));

  const grid = document.getElementById('grid');
  const n = cams.length;
  const cols = Number(params.get('cols')) || (n <= 1 ? 1 : n <= 4 ? 2 : n <= 9 ? 3 : 4);
  const rows = Math.ceil(n / cols) || 1;
  grid.style.gridTemplateColumns = `repeat(${cols}, 1fr)`;
  grid.style.gridTemplateRows = `repeat(${rows}, 1fr)`;
  document.getElementById('msg').remove();

  for (const cam of cams) {
    const tile = document.createElement('div');
    tile.className = 'tile';
    const v = document.createElement('cam-view');
    v.mode = params.get('mode') || 'mse,hls,mjpeg';   // MSE over the HTTPS websocket; no UDP needed
    v.src = new URL('api/ws?src=' + encodeURIComponent(cam.id), location.href);
    const label = document.createElement('div');
    label.className = 'label';
    label.innerHTML = '<span class="dot"></span>';
    label.append(cam.name);
    tile.append(v, label);
    grid.append(tile);
    // mark tile live once frames arrive
    const watch = setInterval(() => {
      const vid = v.video;
      if (vid && vid.currentTime > 0 && !vid.paused) tile.classList.add('live');
      else tile.classList.remove('live');
    }, 2000);
  }

  // Safety net for 24/7 signage: full reload every 6 hours
  setTimeout(() => location.reload(), 6 * 60 * 60 * 1000);
</script>
</body>
</html>
HTML_EOF

# ---------- start ----------
cd "$APP_DIR"
docker compose pull -q
docker compose up -d --force-recreate
docker exec nepo-caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || true

# ---------- checks ----------
echo
echo "=== Checks ==="
MYIP=$(curl -fsS4 https://api.ipify.org || echo "?")
DNSIP=$(dig +short A "$DOMAIN" | tail -1)
if [[ "$DNSIP" == "$MYIP" ]]; then c_ok "DNS     : $DOMAIN -> $MYIP  ✓"
else c_warn "DNS     : $DOMAIN -> '${DNSIP:-nothing}' but this server is $MYIP. Add/fix the A record, then wait a few minutes."; fi

if timeout 5 bash -c "</dev/tcp/$NOIDA_IP/$RTSP_PORT" 2>/dev/null; then
  c_ok "Noida   : $NOIDA_IP:$RTSP_PORT is reachable  ✓"
else
  c_warn "Noida   : cannot reach $NOIDA_IP:$RTSP_PORT – check the router port forward / ISP."
fi

sleep 4
FIRST=$(python3 -c "import json;print(json.load(open('$APP_DIR/www/cameras.json'))[0]['id'])")
CODE=$(curl -s -o /tmp/nepo-frame.jpg -w '%{http_code}' --max-time 20 "http://127.0.0.1:1984/$TOKEN/api/frame.jpeg?src=$FIRST" || true)
SIZE=$(stat -c %s /tmp/nepo-frame.jpg 2>/dev/null || echo 0)
if [[ "${SIZE:-0}" -gt 1000 ]]; then c_ok "Video   : got a live frame from '$FIRST'  ✓"
else c_warn "Video   : no frame from '$FIRST' yet (HTTP ${CODE:-?}). Check NVR user/password, channel numbers and the port forward. Logs: docker logs nepo-go2rtc"; fi

echo
c_ok "Camera page (works only from: $ALLOWED_IPS):"
echo
echo "    https://$DOMAIN/$TOKEN/"
echo
echo "Options:  ?cams=$FIRST   (show only some cameras, comma-separated ids)"
echo "          ?cols=3        (force number of columns)"
echo
echo "Camera ids: $(python3 -c "import json;print(', '.join(c['id'] for c in json.load(open('$APP_DIR/www/cameras.json'))))")"
echo "Settings are in $SETTINGS (root only). Re-run this script to change anything."
