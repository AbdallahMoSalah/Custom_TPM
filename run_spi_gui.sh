#!/bin/bash
set -e

echo "=== Compiling SPI Slave Testbench ==="
vlog tb/tpm_spi_slave_tb.v rtl/tpm_spi_slave.v rtl/tpm_mem.v

echo ""
echo "=== Opening GUI for Simulation ==="
vsim -voptargs=+acc work.tpm_spi_slave_tb
