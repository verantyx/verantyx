#!/bin/bash

# ==========================================
# Verantyx Hybrid Tunneling (Plan A)
# ==========================================

echo "🧠 Booting Verantyx 1930s API (FastAPI)..."
python3 -m uvicorn api:app --host 0.0.0.0 --port 8000 &
FASTAPI_PID=$!

# Wait for FastAPI to start
sleep 3

echo "🌐 Checking Cloudflare Tunnel (cloudflared)..."
if ! command -v cloudflared &> /dev/null; then
    echo "cloudflared not found. Please install it with: brew install cloudflare/cloudflare/cloudflared"
    kill $FASTAPI_PID
    exit 1
fi

echo "🚀 Opening Tunnel to the World! Share the URL below:"
cloudflared tunnel --url http://localhost:8000

echo "Shutting down..."
kill $FASTAPI_PID
