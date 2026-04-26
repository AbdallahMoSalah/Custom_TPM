// =============================================================================
// tpm_spi_slave.v — 4-Wire SPI Slave
// =============================================================================
// Pins (5 GPIO total):
//   spi_csn  — chip-select, active-low  (input)
//   spi_sck  — clock, mode 0 idle-low   (input)
//   spi_mosi — host → chip              (input)
//   spi_miso — chip → host              (output)
//   irq      — response ready           (output, active-high)
//
// Protocol:
//   All transactions begin with CSn going low.
//   First byte transmitted by host is the OPCODE:
//     0xC0  WRITE  — subsequent bytes are the TPM command, stored in CMD_BUF
//     0x40  READ   — slave clocks out RSP_BUF bytes while host sends dummies
//   CSn going high ends the transaction.
//   After a WRITE, CSn-rise triggers cmd_start to the command processor.
//   IRQ goes high when the processor sets done=1.
//   IRQ clears after a READ transaction ends (CSn-rise after READ opcode).
//
// Metastability: all three SPI inputs pass through a 2-FF synchroniser.
// Max reliable SPI clock ≈ sys_clk / 5 (e.g. 10 MHz at 50 MHz sys_clk).
//
// Memory interface:
//   This module drives Port A of tpm_mem.
//   During WRITE: addr = byte_index (0x00..0x7E, CMD region)
//   During READ:  addr = 0x80 + byte_index   (RSP region)
//   pa_rdata is available one cycle after pa_addr is set.
// =============================================================================
`timescale 1ns/1ps

module tpm_spi_slave (
    input  wire       clk,
    input  wire       rstn,

    // Physical SPI pins
    input  wire       spi_csn,
    input  wire       spi_sck,
    input  wire       spi_mosi,
    output reg        spi_miso,

    // Memory port A
    output reg  [7:0] pa_addr,
    output reg  [7:0] pa_wdata,
    output reg        pa_we,
    input  wire [7:0] pa_rdata,   // 1 cycle after pa_addr is set

    // Control
    output reg        cmd_start,  // pulse on CSn-rise after WRITE
    input  wire       proc_busy,  // processor is running
    input  wire       proc_done,  // processor just finished
    output wire       irq         // stays high until READ transaction ends
);

// ---------------------------------------------------------------------------
// 2-FF synchronisers for async SPI inputs
// ---------------------------------------------------------------------------
reg [1:0] csn_ff, sck_ff, mosi_ff;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        csn_ff  <= 2'b11;
        sck_ff  <= 2'b00;
        mosi_ff <= 2'b00;
    end else begin
        csn_ff  <= {csn_ff[0],  spi_csn};
        sck_ff  <= {sck_ff[0],  spi_sck};
        mosi_ff <= {mosi_ff[0], spi_mosi};
    end
end

wire csn  = csn_ff[1];
wire sck  = sck_ff[1];
wire mosi = mosi_ff[1];

// Detect edges on synchronised signals
wire sck_rise  = ( sck_ff[0] & ~sck_ff[1]);
wire sck_fall  = (~sck_ff[0] &  sck_ff[1]);
wire csn_fall  = (~csn_ff[0] &  csn_ff[1]);
wire csn_rise  = ( csn_ff[0] & ~csn_ff[1]);

// ---------------------------------------------------------------------------
// IRQ register
// ---------------------------------------------------------------------------
reg irq_r;
assign irq = irq_r;

// ---------------------------------------------------------------------------
// SPI bit-level shift register & Transaction FSM
// MSB first on both MOSI and MISO.
// ---------------------------------------------------------------------------
reg [7:0] rx_sr;       // receive shift register
reg [7:0] tx_byte;     // current byte being transmitted
reg [2:0] bit_cnt;     // counts 7 down to 0 per byte
reg       byte_done;   // pulse: byte fully received

wire [7:0] rx_byte = rx_sr;

localparam TS_IDLE  = 3'd0;
localparam TS_OPCODE = 3'd1;   // waiting for first byte (opcode)
localparam TS_WRITE = 3'd2;    // receiving command bytes
localparam TS_READ  = 3'd3;    // transmitting response bytes
localparam TS_DONE  = 3'd4;    // CSn rose after WRITE — trigger processor

reg [2:0] ts_state;
reg [6:0] byte_idx;    // index within CMD_BUF or RSP_BUF (0..127)
reg       pre_fetch;   // we need to pre-fetch first RSP byte after opcode

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        irq_r     <= 1'b0;
        rx_sr     <= 8'h00;
        tx_byte   <= 8'hFF;
        bit_cnt   <= 3'd7;
        byte_done <= 1'b0;
        spi_miso  <= 1'b1;
        ts_state  <= TS_IDLE;
        byte_idx  <= 7'd0;
        cmd_start <= 1'b0;
        pa_we     <= 1'b0;
        pa_addr   <= 8'h00;
        pa_wdata  <= 8'h00;
        pre_fetch <= 1'b0;
    end else begin
        // Default values for pulses
        byte_done <= 1'b0;
        cmd_start <= 1'b0;
        pa_we     <= 1'b0;

        // IRQ trigger from processor
        if (proc_done) irq_r <= 1'b1;

        // -----------------------------------------------------------------
        // BIT-LEVEL LOGIC
        // -----------------------------------------------------------------
        if (csn) begin
            // Inactive: reset bit counter, keep MISO high
            bit_cnt  <= 3'd7;
            spi_miso <= 1'b1;
        end else begin
            // Sample MOSI on rising SCK
            if (sck_rise) begin
                rx_sr <= {rx_sr[6:0], mosi};
                if (bit_cnt == 3'd0) begin
                    byte_done <= 1'b1;
                    bit_cnt   <= 3'd7;
                end else begin
                    bit_cnt <= bit_cnt - 1;
                end
            end
            // Shift MISO out on falling SCK
            if (sck_fall) begin
                spi_miso <= tx_byte[7];
                tx_byte  <= {tx_byte[6:0], 1'b1};
            end
            // Pre-drive first MISO bit when CSn first falls
            if (csn_fall) begin
                spi_miso <= tx_byte[7];
            end
        end

        // -----------------------------------------------------------------
        // TRANSACTION FSM LOGIC
        // -----------------------------------------------------------------
        case (ts_state)

        TS_IDLE: begin
            if (csn_fall) begin
                byte_idx <= 7'd0;
                ts_state <= TS_OPCODE;
            end
        end

        TS_OPCODE: begin
            if (csn_rise) begin ts_state <= TS_IDLE; end  // aborted
            else if (byte_done) begin
                if (rx_byte == 8'hC0) begin
                    byte_idx <= 7'd0;
                    ts_state <= TS_WRITE;
                end else if (rx_byte == 8'h40) begin
                    // Pre-fetch RSP_BUF[0] so it is ready for MISO next byte
                    pa_addr   <= 8'h80;
                    byte_idx  <= 7'd0;
                    pre_fetch <= 1'b1;
                    ts_state  <= TS_READ;
                end else begin
                    ts_state <= TS_IDLE; // unknown opcode — ignore transaction
                end
            end
        end

        TS_WRITE: begin
            if (csn_rise) begin
                // End of WRITE — kick the command processor (if not busy)
                if (!proc_busy) cmd_start <= 1'b1;
                ts_state <= TS_IDLE;
            end else if (byte_done) begin
                if (byte_idx <= 7'd127) begin
                    pa_addr  <= {1'b0, byte_idx};   // 0x00..0x7F
                    pa_wdata <= rx_byte;
                    pa_we    <= 1'b1;
                    byte_idx <= byte_idx + 1;
                end
                // If CMD_BUF full: silently drop byte (overflow protection)
            end
        end

        TS_READ: begin
            if (csn_rise) begin
                irq_r    <= 1'b0;    // clear IRQ after read completes
                ts_state <= TS_IDLE;
            end else begin
                if (pre_fetch) begin
                    // First RSP byte now available in pa_rdata
                    tx_byte   <= pa_rdata;
                    pre_fetch <= 1'b0;
                end else if (byte_done) begin
                    // Last byte was clocked out; load next from memory
                    tx_byte  <= pa_rdata;       // pre-fetched previous cycle
                    byte_idx <= byte_idx + 1;
                    if (byte_idx < 7'd127)
                        pa_addr <= 8'h80 + byte_idx + 1;
                end
            end
        end

        default: ts_state <= TS_IDLE;
        endcase
    end
end

endmodule
