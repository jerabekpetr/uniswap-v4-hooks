#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

RPC_URL="http://localhost:8545"
ANVIL_PID=""

cleanup() {
    if [[ -n "$ANVIL_PID" ]]; then
        echo "[start.sh] Zastavuju Anvil (PID $ANVIL_PID)…"
        kill "$ANVIL_PID" 2>/dev/null || true
        wait "$ANVIL_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

command -v anvil >/dev/null || { echo "[start.sh] anvil nenalezen, nainstaluj Foundry." >&2; exit 1; }
command -v forge >/dev/null || { echo "[start.sh] forge nenalezen, nainstaluj Foundry." >&2; exit 1; }
command -v python3 >/dev/null || { echo "[start.sh] python3 nenalezen (potřeba pro FE server)." >&2; exit 1; }

echo "[start.sh] Startuju Anvil na portu 8545…"
anvil --silent &
ANVIL_PID=$!

# Čekej na RPC
for i in {1..30}; do
    if cast chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1; then
        break
    fi
    sleep 0.5
done
if ! cast chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1; then
    echo "[start.sh] Anvil neodpovídá po 15s" >&2
    exit 1
fi
echo "[start.sh] Anvil připraven."

# Použij první default anvil private key (všechny účty unlocked)
PK="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

echo "[start.sh] Deploy V4 artefaktů…"
forge script script/testing/00_DeployV4.s.sol \
    --rpc-url "$RPC_URL" --broadcast --private-key "$PK" --silent

if [[ ! -f frontend/v4-addresses.json ]]; then
    echo "[start.sh] frontend/v4-addresses.json nebyl vygenerován." >&2; exit 1
fi
echo "[start.sh] V4 adresy: $(cat frontend/v4-addresses.json)"

echo "[start.sh] Deploy Sentinel hooku…"
HOOK_DEPLOY_OUT=$(forge script script/sentinel/00_DeployHook.s.sol \
    --rpc-url "$RPC_URL" --broadcast --private-key "$PK" --json 2>/dev/null || true)

# Vytáhni adresu hooku z broadcast/ logu — spolehlivější než parse JSON
HOOK_ADDR=$(jq -r '.transactions[] | select(.contractName=="SentinelJITGuardHook") | .contractAddress' \
    broadcast/00_DeployHook.s.sol/31337/run-latest.json | head -n1)

if [[ -z "$HOOK_ADDR" || "$HOOK_ADDR" == "null" ]]; then
    echo "[start.sh] Nepodařilo se najít adresu hooku v broadcastu." >&2
    exit 1
fi
echo "[start.sh] Hook nasazen na: $HOOK_ADDR"

echo "[start.sh] Deploy Simulator…"
SENTINEL_HOOK_ADDRESS="$HOOK_ADDR" forge script script/sentinel/04_DeploySimulator.s.sol \
    --rpc-url "$RPC_URL" --broadcast --skip-simulation --private-key "$PK"

if [[ ! -f frontend/addresses.json ]]; then
    echo "[start.sh] frontend/addresses.json nebyl vygenerován." >&2
    exit 1
fi
echo "[start.sh] addresses.json:"
cat frontend/addresses.json

echo "[start.sh] Spouštím FE server na http://localhost:8000/simulation-sentinel.html …"
echo "[start.sh] Stiskni Ctrl+C pro ukončení (zavře i Anvil)."
cd frontend
python3 -m http.server 8000