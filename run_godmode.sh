#!/usr/bin/env bash
set -e

SOLC_BIN=$(which solc 2>/dev/null || echo "/data/data/com.termux/files/usr/bin/solc")

if [ ! -x "$SOLC_BIN" ]; then
    echo "[!] solc binary not found. Installing via pkg..."
    pkg install -y solidity
    SOLC_BIN=$(which solc)
fi

echo "[+] Using solc at: $SOLC_BIN"

cat << TOML > foundry.toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
solc = "${SOLC_BIN}"
TOML

mkdir -p lib
if [ ! -d "lib/openzeppelin-contracts" ]; then
    echo "[+] Cloning OpenZeppelin contracts..."
    git clone --depth 1 https://github.com/openzeppelin/openzeppelin-contracts lib/openzeppelin-contracts
fi

if [ ! -d "lib/forge-std" ]; then
    echo "[+] Cloning Forge Standard Library..."
    git clone --depth 1 https://github.com/foundry-rs/forge-std lib/forge-std
fi

echo "[+] Running full Foundry test suite..."
forge test -vvvv
