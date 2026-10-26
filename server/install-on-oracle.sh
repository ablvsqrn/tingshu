#!/bin/bash
# Install the TingShu TTS proxy on the Oracle sg-free-01 box (Ubuntu, ARM64).
# Run as the normal user (ubuntu):  bash install-on-oracle.sh
set -euo pipefail

APP_DIR="$HOME/tingshu-tts"
mkdir -p "$APP_DIR"
cp server.py requirements.txt "$APP_DIR/"

python3 -m venv "$APP_DIR/.venv"
"$APP_DIR/.venv/bin/pip" install -q -U pip
"$APP_DIR/.venv/bin/pip" install -q -r "$APP_DIR/requirements.txt"

cat > /tmp/tingshu-tts.service <<EOF
[Unit]
Description=TingShu Edge TTS proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/.venv/bin/python $APP_DIR/server.py
Restart=always
RestartSec=3
Environment=TINGSHU_PORT=8765

[Install]
WantedBy=multi-user.target
EOF
sudo cp /tmp/tingshu-tts.service /etc/systemd/system/tingshu-tts.service
sudo systemctl daemon-reload
sudo systemctl enable --now tingshu-tts

sleep 2
curl -s http://127.0.0.1:8765/health && echo
echo "OK. From the phone (Tailscale on) open: http://100.70.147.99:8765/health"
echo "To upgrade edge-tts later: $APP_DIR/.venv/bin/pip install -U edge-tts && sudo systemctl restart tingshu-tts"
