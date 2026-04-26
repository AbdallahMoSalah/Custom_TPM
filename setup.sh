#!/usr/bin/env bash
# =============================================================================
# setup.sh — Clone sha256_core and run iverilog simulation
# Run from micro_tpm_v3/ root directory
# =============================================================================
set -e

echo "=== Micro-TPM v3 Setup ==="

if [ ! -d "cores/sha256/src" ]; then
    echo "[1] Cloning secworks/sha256..."
    git clone --depth 1 https://github.com/secworks/sha256.git cores/sha256
else
    echo "[1] secworks/sha256 already present."
fi

mkdir -p build

echo "[2] Compiling with Icarus Verilog..."
iverilog -Wall -g2001 -o build/tpm_tb \
    tb/tpm_tb.v \
    rtl/tpm_top.v \
    rtl/tpm_spi_slave.v \
    rtl/tpm_cmd_proc.v \
    rtl/tpm_sha256_wrap.v \
    rtl/tpm_mem.v \
    rtl/tpm_trng.v \
    rtl/tpm_pcr_bank.v \
    cores/sha256/src/rtl/sha256_core.v \
    cores/sha256/src/rtl/sha256_w_mem.v \
    cores/sha256/src/rtl/sha256_k_constants.v

echo "[3] Running simulation..."
./build/tpm_tb

echo ""
echo "Waveforms : gtkwave tpm_tb.vcd"
echo "Synthesis : librelane config.json"
