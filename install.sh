#!/usr/bin/env bash
# =============================================================================
#  The Nepo Team – Cloud CCTV viewer (Noida NVR -> HTTPS web page for AbleSign)
#  Target: fresh Ubuntu 24.04 LTS droplet (DigitalOcean, BLR1 Bangalore)
#  Stack : go2rtc 1.9.15 (pulls RTSP from the NVR; optional laptop tab/window share via
#          WebRTC; optional iPhone screen via RTMP)
#          + Caddy 2.10.2 (HTTPS, IP lock)
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
ask ALLOWED_IPS   "Public IP(s) allowed to view, space-separated (AU office first)" "${ALLOWED_IPS:-}"

echo; echo "-- Noida NVR cameras (type 'none' to skip until the NVR/router are ready) --"
ask NOIDA_IP      "Noida office static public IP"                          "${NOIDA_IP:-none}"
[[ "$NOIDA_IP" == "none" ]] && NOIDA_IP=""
if [[ -n "$NOIDA_IP" ]]; then
  ask RTSP_PORT   "External RTSP port forwarded on the Noida router"       "${RTSP_PORT:-42554}"
  ask NVR_USER    "NVR view-only username"                                 "${NVR_USER:-signage}"
  if [[ -n "${NVR_PASS:-}" ]]; then
    read -r -s -p "NVR password for '$NVR_USER' [Enter = keep current]: " p || true; echo
    NVR_PASS=${p:-$NVR_PASS}
  else
    read -r -s -p "NVR password for '$NVR_USER': " NVR_PASS; echo
  fi
  ask CAMERAS     "Cameras as Name:Channel, comma-separated"               "${CAMERAS:-Reception:1,Director Room:2,Balcony:3,Office:4,Office B:5}"
  ask STREAM_TYPE "Stream quality – sub (recommended) or main"             "${STREAM_TYPE:-sub}"
fi
RTSP_PORT=${RTSP_PORT:-42554}; NVR_USER=${NVR_USER:-signage}; NVR_PASS=${NVR_PASS:-}
CAMERAS=${CAMERAS:-}; STREAM_TYPE=${STREAM_TYPE:-sub}

echo; echo "-- Laptop share tile (share a Chrome tab / app window from a laptop at the allowed IPs) --"
ask LAPTOP        "Add the laptop share tile? (y/n)"                       "${LAPTOP:-y}"
if [[ "$LAPTOP" == "y" ]]; then
  [[ -n "${LAPTOP_KEY:-}" ]] || LAPTOP_KEY=$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')
else
  LAPTOP=n
fi
LAPTOP_KEY=${LAPTOP_KEY:-}

echo; echo "-- iPhone screen tile (stream the Prama app from your phone with Larix Screencaster) --"
ask PHONE         "Add the iPhone screen tile? (y/n)"                      "${PHONE:-n}"
OLD_PHONE_IPS=${PHONE_IPS:-}
if [[ "$PHONE" == "y" ]]; then
  ask PHONE_IPS   "Public IP(s) the iPhone streams from ('any' = anywhere)" "${PHONE_IPS:-$ALLOWED_IPS}"
  [[ -n "${PHONE_KEY:-}" ]] || PHONE_KEY=$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')
else
  PHONE=n; PHONE_IPS=""
fi
PHONE_KEY=${PHONE_KEY:-}

[[ -n "$DOMAIN" && -n "$ALLOWED_IPS" ]] || die "Domain and allowed IPs are required."
[[ -n "$NOIDA_IP" || "$PHONE" == "y" || "$LAPTOP" == "y" ]] || die "Nothing to show: add the Noida NVR, the laptop tile and/or the iPhone tile."
if [[ -n "$NOIDA_IP" ]]; then
  [[ -n "$NVR_PASS" && -n "$CAMERAS" ]] || die "NVR password and cameras are required when the Noida NVR is set."
fi
[[ "$RTSP_PORT" =~ ^[0-9]+$ ]] || die "RTSP port must be a number."
case "$STREAM_TYPE" in sub) SUFFIX=02 ;; main) SUFFIX=01 ;; *) die "Stream quality must be 'sub' or 'main'." ;; esac
for ip in $ALLOWED_IPS ${PHONE_IPS//any/}; do
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
PHONE=$(printf '%q' "$PHONE")
PHONE_IPS=$(printf '%q' "$PHONE_IPS")
PHONE_KEY=$(printf '%q' "$PHONE_KEY")
LAPTOP=$(printf '%q' "$LAPTOP")
LAPTOP_KEY=$(printf '%q' "$LAPTOP_KEY")
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
# Remove any previous rules for the share ports, then add the current ones
ufw_clear_port() {
  local n
  while n=$(ufw status numbered | grep -E "[[:space:]]$1(/(tcp|udp))?[[:space:]]" | head -1 | sed -E 's/^\[ *([0-9]+)\].*/\1/') && [[ -n "$n" ]]; do
    ufw --force delete "$n" >/dev/null
  done
}
ufw_clear_port 1935
ufw_clear_port 8555
if [[ "$PHONE" == "y" ]]; then   # RTMP from the iPhone
  if [[ " $PHONE_IPS " == *" any "* ]]; then ufw allow 1935/tcp >/dev/null
  else for ip in $PHONE_IPS; do ufw allow from "$ip" to any port 1935 proto tcp >/dev/null; done; fi
fi
if [[ "$LAPTOP" == "y" ]]; then  # WebRTC media from the laptop (same IPs as the viewers)
  for ip in $ALLOWED_IPS; do
    ufw allow from "$ip" to any port 8555 proto udp >/dev/null
    ufw allow from "$ip" to any port 8555 proto tcp >/dev/null
  done
fi
ufw --force enable >/dev/null

# ---------- generate config ----------
export NOIDA_IP RTSP_PORT NVR_USER NVR_PASS CAMERAS SUFFIX TOKEN APP_DIR PHONE PHONE_KEY LAPTOP LAPTOP_KEY
python3 - <<'PY'
import os, json, re, urllib.parse
user = urllib.parse.quote(os.environ["NVR_USER"], safe="")
pw   = urllib.parse.quote(os.environ["NVR_PASS"], safe="")
host, port, suffix = os.environ["NOIDA_IP"], os.environ["RTSP_PORT"], os.environ["SUFFIX"]
if ":" in host and not host.startswith("["): host = f"[{host}]"
cams, seen = [], set()
nvr = bool(host)
for item in (os.environ["CAMERAS"].split(",") if nvr else []):
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
    "rtmp:", '  listen: ":1935"' if os.environ["PHONE"] == "y" else '  listen: ""',
    "webrtc:", '  listen: ":8555"' if os.environ["LAPTOP"] == "y" else '  listen: ""',
    "srtp:", '  listen: ""',
    "streams:",
]
for c in cams:
    url = f"rtsp://{user}:{pw}@{host}:{port}/Streaming/Channels/{c['channel']}{suffix}"
    lines.append(f"  {c['id']}: {json.dumps(url)}")
tiles = [{"id": c["id"], "name": c["name"]} for c in cams]
if os.environ["LAPTOP"] == "y":
    lid = "l" + os.environ["LAPTOP_KEY"]       # secret: only this name accepts a WebRTC publish
    lines.append(f"  {lid}:")
    tiles.append({"id": lid, "name": "Laptop share"})
    with open(f"{app}/www/send.json", "w") as f: json.dump({"dst": lid}, f)
if os.environ["PHONE"] == "y":
    pid = "p" + os.environ["PHONE_KEY"]        # secret: only this name accepts an RTMP publish
    lines.append(f"  {pid}:")
    tiles.append({"id": pid, "name": "iPhone – Prama app"})
with open(f"{app}/go2rtc.yaml", "w") as f: f.write("\n".join(lines) + "\n")
os.chmod(f"{app}/go2rtc.yaml", 0o600)
with open(f"{app}/www/cameras.json", "w") as f:
    json.dump(tiles, f, indent=2)
print(f"  {len(tiles)} tile(s): " + ", ".join(t["name"] for t in tiles))
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
		@page path /$TOKEN/ /$TOKEN/index.html /$TOKEN/cameras.json /$TOKEN/send.html /$TOKEN/send.json
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

		# 4) Laptop share: WebRTC publish, only into the laptop tile's secret stream
		@publish {
			path /$TOKEN/api/webrtc
			query dst=l$LAPTOP_KEY
		}
		handle @publish {
			reverse_proxy 127.0.0.1:1984
		}

		# 5) Everything else
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

cat > "$APP_DIR/www/send.html" <<'SEND_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<meta name="referrer" content="no-referrer">
<title>The Nepo Team – Share to CCTV screen</title>
<style>
  :root { --bg:#0B0F19; --card:#111827; --line:#1F2937; --text:#F3F4F6; --muted:#9CA3AF; --cyan:#00D2FE; --blue:#1E88E5; --red:#EF4444; --green:#22C55E; }
  * { box-sizing:border-box; }
  body { margin:0; min-height:100vh; background:var(--bg); color:var(--text);
    font-family: system-ui, -apple-system, "Segoe UI", Roboto, Arial, sans-serif; display:flex; justify-content:center; padding:24px 16px; }
  main { width:100%; max-width:860px; }
  h1 { font-size:20px; margin:0 0 4px; } h1 b { color:var(--cyan); letter-spacing:.06em; }
  p { color:var(--muted); margin:0 0 16px; line-height:1.5; }
  .card { background:var(--card); border:1px solid var(--line); border-radius:12px; padding:16px; margin-bottom:16px; }
  .row { display:flex; gap:12px; align-items:center; flex-wrap:wrap; }
  button { font:inherit; font-weight:700; border:0; border-radius:10px; padding:12px 18px; cursor:pointer; }
  #start { background:linear-gradient(90deg,var(--blue),var(--cyan)); color:var(--bg); }
  #stop { background:#374151; color:var(--text); }
  button:disabled { opacity:.45; cursor:default; }
  select { font:inherit; background:var(--bg); color:var(--text); border:1px solid var(--line); border-radius:8px; padding:10px; }
  #status { font-weight:600; } .dot { display:inline-block; width:10px; height:10px; border-radius:50%; background:var(--muted); margin-right:8px; }
  .live .dot { background:var(--red); } .ok { color:var(--green); }
  video { width:100%; background:#000; border-radius:8px; aspect-ratio:16/9; object-fit:contain; display:block; }
  ol { color:var(--muted); line-height:1.7; margin:0; padding-left:20px; }
</style>
</head>
<body>
<main>
  <h1><b>THE NEPO TEAM</b> · Share to the CCTV screen</h1>
  <p>Shares one Chrome tab, app window or screen from this laptop to the "Laptop share" tile on the camera page. Nothing is recorded.</p>

  <div class="card">
    <div class="row">
      <button id="start">Start sharing</button>
      <button id="stop" disabled>Stop</button>
      <select id="quality" title="Quality">
        <option value="720">720p · 15 fps (recommended)</option>
        <option value="1080">1080p · 15 fps</option>
        <option value="480">480p · 10 fps (slow internet)</option>
      </select>
      <span id="status"><span class="dot"></span>Not sharing</span>
    </div>
  </div>

  <div class="card"><video id="preview" muted playsinline autoplay></video></div>

  <div class="card">
    <ol>
      <li>Open the camera view first: the Prama/PramaVMS app full-screen, or your iPhone mirrored to this Mac.</li>
      <li>Click <b>Start sharing</b> and pick that <b>Window</b> (or a Chrome tab), then <b>Share</b>.</li>
      <li>Keep this tab open and the laptop awake and plugged in. Sharing resumes by itself after a network drop.</li>
      <li>Mac only: the first time, allow Chrome in System Settings → Privacy &amp; Security → Screen Recording, then restart Chrome.</li>
    </ol>
  </div>
</main>

<script type="module">
  const $ = id => document.getElementById(id);
  const statusEl = $('status');
  const set = (text, live=false, ok=false) => {
    statusEl.className = live ? 'live' : '';
    statusEl.innerHTML = '<span class="dot"></span>' + (ok ? '<span class="ok">' + text + '</span>' : text);
  };
  const { dst } = await (await fetch('send.json', { cache:'no-store' })).json();

  let stream = null, pc = null, wantOn = false, retryTimer = 0, wakeLock = null;

  async function connect() {
    clearTimeout(retryTimer);
    if (pc) { try { pc.close(); } catch {} pc = null; }
    if (!wantOn || !stream) return;
    set('Connecting…', true);
    pc = new RTCPeerConnection();
    for (const t of stream.getVideoTracks()) {
      const tr = pc.addTransceiver(t, { direction: 'sendonly' });
      const caps = RTCRtpSender.getCapabilities && RTCRtpSender.getCapabilities('video');
      if (caps && tr.setCodecPreferences) {               // H.264 plays everywhere (incl. Fire TV)
        const h264 = caps.codecs.filter(c => /h264/i.test(c.mimeType));
        const rest = caps.codecs.filter(c => !/h264/i.test(c.mimeType));
        if (h264.length) tr.setCodecPreferences([...h264, ...rest]);
      }
    }
    pc.onconnectionstatechange = () => {
      const s = pc && pc.connectionState;
      if (s === 'connected') set('Live on the CCTV screen', true, true);
      if (s === 'failed' || s === 'disconnected') { set('Connection lost – retrying…', true); retryTimer = setTimeout(connect, 3000); }
    };
    try {
      await pc.setLocalDescription(await pc.createOffer());
      await new Promise(r => {
        if (pc.iceGatheringState === 'complete') return r();
        pc.onicegatheringstatechange = () => pc.iceGatheringState === 'complete' && r();
        setTimeout(r, 2500);
      });
      const res = await fetch('api/webrtc?dst=' + encodeURIComponent(dst), { method: 'POST', body: pc.localDescription.sdp });
      if (!res.ok) throw new Error('Server answered ' + res.status);
      await pc.setRemoteDescription({ type: 'answer', sdp: await res.text() });
    } catch (e) {
      set('Could not connect (' + e.message + ') – retrying…', true);
      retryTimer = setTimeout(connect, 5000);
    }
  }

  async function start() {
    const q = $('quality').value;
    const h = q === '1080' ? 1080 : q === '480' ? 480 : 720;
    const fps = q === '480' ? 10 : 15;
    try {
      stream = await navigator.mediaDevices.getDisplayMedia({
        video: { height: { ideal: h, max: h }, frameRate: { ideal: fps, max: fps } },
        audio: false, selfBrowserSurface: 'exclude', surfaceSwitching: 'include'
      });
    } catch { set('Sharing cancelled'); return; }
    const track = stream.getVideoTracks()[0];
    track.contentHint = 'motion';
    track.onended = stop;                                  // user pressed Chrome's "Stop sharing"
    $('preview').srcObject = stream;
    wantOn = true; $('start').disabled = true; $('stop').disabled = false; $('quality').disabled = true;
    try { wakeLock = await navigator.wakeLock?.request('screen'); } catch {}
    connect();
  }

  function stop() {
    wantOn = false; clearTimeout(retryTimer);
    if (pc) { try { pc.close(); } catch {} pc = null; }
    if (stream) { stream.getTracks().forEach(t => t.stop()); stream = null; }
    $('preview').srcObject = null;
    $('start').disabled = false; $('stop').disabled = true; $('quality').disabled = false;
    try { wakeLock?.release(); } catch {} wakeLock = null;
    set('Not sharing');
  }

  $('start').onclick = start;
  $('stop').onclick = stop;
  document.addEventListener('visibilitychange', async () => {
    if (wantOn && document.visibilityState === 'visible' && !wakeLock) { try { wakeLock = await navigator.wakeLock?.request('screen'); } catch {} }
  });
</script>
</body>
</html>
SEND_EOF
[[ "$LAPTOP" == "y" ]] || rm -f "$APP_DIR/www/send.json" "$APP_DIR/www/send.html"

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

FIRST=$(python3 -c "import json;print(json.load(open('$APP_DIR/www/cameras.json'))[0]['id'])")
if [[ -n "$NOIDA_IP" ]]; then
  if timeout 5 bash -c "</dev/tcp/$NOIDA_IP/$RTSP_PORT" 2>/dev/null; then
    c_ok "Noida   : $NOIDA_IP:$RTSP_PORT is reachable  ✓"
  else
    c_warn "Noida   : cannot reach $NOIDA_IP:$RTSP_PORT – check the router port forward / ISP."
  fi
  sleep 4
  CODE=$(curl -s -o /tmp/nepo-frame.jpg -w '%{http_code}' --max-time 20 "http://127.0.0.1:1984/$TOKEN/api/frame.jpeg?src=$FIRST" || true)
  SIZE=$(stat -c %s /tmp/nepo-frame.jpg 2>/dev/null || echo 0)
  if [[ "${SIZE:-0}" -gt 1000 ]]; then c_ok "Video   : got a live frame from '$FIRST'  ✓"
  else c_warn "Video   : no frame from '$FIRST' yet (HTTP ${CODE:-?}). Check NVR user/password, channel numbers and the port forward. Logs: docker logs nepo-go2rtc"; fi
else
  c_warn "Noida   : skipped (no NVR configured yet)"
fi

echo
c_ok "Camera page (works only from: $ALLOWED_IPS):"
echo
echo "    https://$DOMAIN/$TOKEN/"
echo
echo "Options:  ?cams=$FIRST   (show only some cameras, comma-separated ids)"
echo "          ?cols=3        (force number of columns)"
echo
echo "Camera ids: $(python3 -c "import json;print(', '.join(c['id'] for c in json.load(open('$APP_DIR/www/cameras.json'))))")"
if [[ "$LAPTOP" == "y" ]]; then
  echo
  c_ok "Laptop share page (open in Chrome on a laptop at: $ALLOWED_IPS):"
  echo "    https://$DOMAIN/$TOKEN/send.html"
fi
if [[ "$PHONE" == "y" ]]; then
  echo
  c_ok "iPhone (Larix Screencaster → Settings → Connections → New connection):"
  echo "    Name : Nepo CCTV"
  echo "    URL  : rtmp://$DOMAIN:1935/p$PHONE_KEY/screen"
  echo "    (accepted only from: $PHONE_IPS)"
fi
echo "Settings are in $SETTINGS (root only). Re-run this script to change anything."
