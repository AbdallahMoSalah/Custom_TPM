#!/bin/bash
set -e

echo "=== Compiling SPI Slave Testbench ==="
vlog tb/tpm_spi_slave_tb.v rtl/tpm_spi_slave.v rtl/tpm_mem.v

echo ""
echo "=== Running Simulation ==="
vsim -c -do "run -all; quit" work.tpm_spi_slave_tb
