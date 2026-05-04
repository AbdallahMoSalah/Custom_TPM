#!/usr/bin/env bash
# =============================================================================
# run_questa.sh — Compile and run simulation using Questa Sim
# =============================================================================
set -e

echo "=== Micro-TPM v3 Setup (Questa Sim) ==="

if [ ! -d "cores/sha256/src" ]; then
    echo "[1] Cloning secworks/sha256..."
    git clone --depth 1 https://github.com/secworks/sha256.git cores/sha256
else
    echo "[1] secworks/sha256 already present."
fi

echo "[2] Creating working library..."
vlib work

echo "[3] Compiling with vlog..."
vlog +define+SIMULATION \
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

echo "[4] Running simulation with vsim..."
vsim -voptargs=+acc -c -do "run -all; quit" work.tpm_tb
