// =============================================================================
// tpm_tb.v — Micro-TPM v3 Testbench
// =============================================================================
// Drives the SPI interface exactly as a host MCU would.
// Tests: GetRandom, PCR_Extend, PCR_Read, HMAC.
`timescale 1ns/1ps

module tpm_tb;

// ---------------------------------------------------------------------------
// Clock and reset
// ---------------------------------------------------------------------------
reg clk = 0;
always #25 clk = ~clk;  // 20 MHz system clock (50 ns period)

reg rstn = 0;
initial begin #150 rstn = 1; end

// ---------------------------------------------------------------------------
// SPI signals
// ---------------------------------------------------------------------------
reg  spi_csn  = 1;
reg  spi_sck  = 0;
reg  spi_mosi = 0;
wire spi_miso;
wire irq;

// ---------------------------------------------------------------------------
// DUT
// ---------------------------------------------------------------------------
tpm_top dut (
    .clk      (clk),
    .rstn     (rstn),
    .spi_csn  (spi_csn),
    .spi_sck  (spi_sck),
    .spi_mosi (spi_mosi),
    .spi_miso (spi_miso),
    .irq      (irq)
);

// ---------------------------------------------------------------------------
// SPI master tasks (mode 0, MSB first)
// Each SPI bit takes ~10 system clock cycles (500ns) → SPI ≈ 2 MHz
// Rule: SPI period must be >> 5× sys_clk so the 2-FF synchroniser sees edges.
task spi_clock_bit;
    input  tx_bit;
    output rx_bit;
    begin
        spi_mosi = tx_bit;
        #150;             // setup (3 sys clk)
        spi_sck  = 1;
        #150;             // hold — sample MISO here (3 sys clk)
        rx_bit   = spi_miso;
        spi_sck  = 0;
        #150;
    end
endtask

task spi_byte;
    input  [7:0] tx;
    output [7:0] rx;
    reg miso_b;
    integer k;
    begin
        rx = 0;
        for (k = 7; k >= 0; k = k-1) begin
            spi_clock_bit(tx[k], miso_b);
            rx[k] = miso_b;
        end
    end
endtask

// Assert CSn, send opcode + bytes, deassert CSn
task spi_write;
    input integer n;
    reg [7:0] dummy;
    integer i;
    begin
        spi_csn = 0; #50;
        spi_byte(8'hC0, dummy);         // WRITE opcode
        for (i = 0; i < n; i = i+1)
            spi_byte(cmd[i], dummy);
        #50; spi_csn = 1; #100;         // CSn rise triggers processing
    end
endtask

// Assert CSn, send READ opcode, clock out n response bytes
task spi_read;
    input integer n;
    reg [7:0] dummy;
    integer i;
    begin
        spi_csn = 0; #50;
        spi_byte(8'h40, dummy);         // READ opcode
        for (i = 0; i < n; i = i+1)
            spi_byte(8'hFF, rsp[i]);    // dummy in, data out
        #50; spi_csn = 1; #100;
    end
endtask

task wait_irq;
    integer t;
    begin
        t = 0;
        while (!irq && t < 1_000_000) begin @(posedge clk); t = t+1; end
        if (t >= 1_000_000) $display("[TIMEOUT] IRQ never asserted");
    end
endtask

// ---------------------------------------------------------------------------
// Shared buffers
// ---------------------------------------------------------------------------
reg [7:0] cmd [0:127];
reg [7:0] rsp [0:127];

task pack32;
    input integer off;
    input [31:0] v;
    begin
        cmd[off]   = v[31:24]; cmd[off+1] = v[23:16];
        cmd[off+2] = v[15:8];  cmd[off+3] = v[7:0];
    end
endtask
task pack16;
    input integer off;
    input [15:0] v;
    begin cmd[off] = v[15:8]; cmd[off+1] = v[7:0]; end
endtask

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
integer i;
reg [31:0] rc;

initial begin
    $dumpfile("tpm_tb.vcd");
    $dumpvars(0, tpm_tb);

    wait (rstn); @(posedge clk); #200;

    // ═══════════════════════════════════════════════════════════════════════
    $display("\n=== Test 1: TPM2_GetRandom (32 bytes) ===");
    // Header: tag(2) + size(4) + code(4) + bytesRequested(2) = 12 bytes
    pack16(0,  16'h8001);           // tag
    pack32(2,  32'd12);             // size
    pack32(6,  32'h0000_017B);      // CC_GetRandom
    pack16(10, 16'h0020);           // bytesRequested = 32

    spi_write(12);
    wait_irq;
    // DEBUG: dump RSP_BUF directly from memory before SPI read
    $display("  [DBG] RSP_BUF[0..13] = %02X %02X %02X %02X %02X %02X %02X %02X %02X %02X %02X %02X %02X %02X",
        tpm_tb.dut.u_mem.mem[8'h80], tpm_tb.dut.u_mem.mem[8'h81],
        tpm_tb.dut.u_mem.mem[8'h82], tpm_tb.dut.u_mem.mem[8'h83],
        tpm_tb.dut.u_mem.mem[8'h84], tpm_tb.dut.u_mem.mem[8'h85],
        tpm_tb.dut.u_mem.mem[8'h86], tpm_tb.dut.u_mem.mem[8'h87],
        tpm_tb.dut.u_mem.mem[8'h88], tpm_tb.dut.u_mem.mem[8'h89],
        tpm_tb.dut.u_mem.mem[8'h8A], tpm_tb.dut.u_mem.mem[8'h8B],
        tpm_tb.dut.u_mem.mem[8'h8C], tpm_tb.dut.u_mem.mem[8'h8D]);
    spi_read(44);                   // 10 hdr + 2 outSize + 32 rand bytes

    rc = {rsp[6],rsp[7],rsp[8],rsp[9]};
    $display("  rspCode = 0x%08X (expect 0x00000000)", rc);
    $display("  rand[0] = 0x%02X  rand[1] = 0x%02X", rsp[12], rsp[13]);
    if (rc == 0) $display("  PASS"); else $display("  FAIL");


    // ═══════════════════════════════════════════════════════════════════════
    $display("\n=== Test 2: TPM2_PCR_Extend (PCR[0]) ===");
    // Header(10) + handle(4) + count(4) + algID(2) + digest(32) = 52 bytes
    pack16(0,  16'h8001);
    pack32(2,  32'd52);
    pack32(6,  32'h0000_0182);      // CC_PCR_Extend
    pack32(10, 32'h0000_0000);      // PCR handle = 0
    pack32(14, 32'h0000_0001);      // count = 1
    pack16(18, 16'h000B);           // algID = SHA-256
    for (i = 20; i < 52; i = i+1)  // 32-byte measurement = 0xAA..AA
        cmd[i] = 8'hAA;

    spi_write(52);
    wait_irq;
    spi_read(10);                   // response = header only (10 bytes)

    rc = {rsp[6],rsp[7],rsp[8],rsp[9]};
    $display("  rspCode = 0x%08X (expect 0x00000000)", rc);
    if (rc == 0) $display("  PASS"); else $display("  FAIL");

    // ═══════════════════════════════════════════════════════════════════════
    $display("\n=== Test 3: TPM2_PCR_Read (PCR[0]) ===");
    pack16(0,  16'h8001);
    pack32(2,  32'd14);
    pack32(6,  32'h0000_017E);      // CC_PCR_Read
    pack32(10, 32'h0000_0000);      // PCR handle = 0

    spi_write(14);
    wait_irq;
    spi_read(42);                   // 10 hdr + 32 PCR bytes

    rc = {rsp[6],rsp[7],rsp[8],rsp[9]};
    $display("  rspCode      = 0x%08X", rc);
    $display("  PCR[0][31:0] = 0x%02X%02X%02X%02X",
             rsp[10],rsp[11],rsp[12],rsp[13]);
    // PCR should not be all-zero (was extended with 0xAA..AA above)
    if (rc == 0) $display("  PASS"); else $display("  FAIL");

    // ═══════════════════════════════════════════════════════════════════════
    $display("\n=== Test 4: TPM2_HMAC (key=0xAA*32, msg=0xBB*32) ===");
    // Header(10) + key(32) + msg(32) = 74 bytes
    pack16(0, 16'h8001);
    pack32(2, 32'd74);
    pack32(6, 32'h0000_015D);       // CC_HMAC
    for (i = 10; i < 42; i = i+1) cmd[i] = 8'hAA;   // 32-byte key
    for (i = 42; i < 74; i = i+1) cmd[i] = 8'hBB;   // 32-byte message

    spi_write(74);
    wait_irq;
    spi_read(42);                   // 10 hdr + 32 HMAC bytes

    rc = {rsp[6],rsp[7],rsp[8],rsp[9]};
    $display("  rspCode        = 0x%08X", rc);
    $display("  HMAC[255:224]  = 0x%02X%02X%02X%02X",
             rsp[10],rsp[11],rsp[12],rsp[13]);
    if (rc == 0) $display("  PASS"); else $display("  FAIL");

    $display("\n=== All tests done ===");
    #500; $finish;
end

initial begin #20_000_000; $display("WATCHDOG"); $finish; end

endmodule
