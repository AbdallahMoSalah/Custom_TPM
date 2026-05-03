`timescale 1ns/1ps

module tpm_spi_slave_tb;

    reg clk;
    reg rstn;

    // SPI signals
    reg  spi_csn;
    reg  spi_sck;
    reg  spi_mosi;
    wire spi_miso;

    // Memory Port A (connected to spi_slave)
    wire [7:0] pa_addr;
    wire [7:0] pa_wdata;
    wire [7:0] pa_rdata;
    wire       pa_we;

    // Memory Port B (used by testbench to mock tpm_cmd_proc)
    reg  [7:0] pb_addr;
    reg  [7:0] pb_wdata;
    wire [7:0] pb_rdata;
    reg        pb_we;

    // Control signals
    wire cmd_start;
    reg  proc_busy;
    reg  proc_done;
    reg  proc_err;
    wire irq;

    // Instantiate SPI Slave
    tpm_spi_slave u_spi_slave (
        .clk(clk),
        .rstn(rstn),
        .spi_csn(spi_csn),
        .spi_sck(spi_sck),
        .spi_mosi(spi_mosi),
        .spi_miso(spi_miso),
        .pa_addr(pa_addr),
        .pa_wdata(pa_wdata),
        .pa_rdata(pa_rdata),
        .pa_we(pa_we),
        .cmd_start(cmd_start),
        .proc_busy(proc_busy),
        .proc_done(proc_done),
        .irq(irq)
    );

    // Instantiate Memory
    tpm_mem u_mem (
        .clk(clk),
        .pa_addr(pa_addr),
        .pa_wdata(pa_wdata),
        .pa_rdata(pa_rdata),
        .pa_we(pa_we),
        .pb_addr(pb_addr),
        .pb_wdata(pb_wdata),
        .pb_rdata(pb_rdata),
        .pb_we(pb_we)
    );

    // Clock generation (100 MHz)
    initial begin
        clk = 0;
        forever #25 clk = ~clk; // 20 MHz (50 ns period)
    end

    // SPI byte transmission task (CPOL=0, CPHA=0)
    task spi_byte;
        input  [7:0] tx_data;
        output [7:0] rx_data;
        integer i;
        begin
            rx_data = 8'h00;
            for (i = 7; i >= 0; i = i - 1) begin
                spi_mosi = tx_data[i];
                #150; // setup (3 sys clk)
                spi_sck = 1;
                #150; // hold (3 sys clk)
                rx_data[i] = spi_miso;
                spi_sck = 0;
                #150;
            end
        end
    endtask

    reg [7:0] dummy_rx;
    reg [7:0] rx_bytes [0:3];
    integer i;

    initial begin
        // Initialize inputs
        rstn = 0;
        spi_csn = 1;
        spi_sck = 0;
        spi_mosi = 0;
        proc_busy = 0;
        proc_done = 0;
        proc_err = 0;
        pb_we = 0;
        pb_addr = 0;
        pb_wdata = 0;

        #50 rstn = 1;
        #50;

        $display("---------------------------------------------------------");
        $display("1. MOCKING TPM RESPONSE (Writing to RSP_BUF 0x80..0x83)");
        $display("---------------------------------------------------------");
        @(posedge clk); pb_we = 1; pb_addr = 8'h80; pb_wdata = 8'h11;
        @(posedge clk); pb_we = 1; pb_addr = 8'h81; pb_wdata = 8'h22;
        @(posedge clk); pb_we = 1; pb_addr = 8'h82; pb_wdata = 8'h33;
        @(posedge clk); pb_we = 1; pb_addr = 8'h83; pb_wdata = 8'h44;
        @(posedge clk); pb_we = 0;
        $display("Wrote: [0x80]=0x11, [0x81]=0x22, [0x82]=0x33, [0x83]=0x44");
        #50;

        $display("\n---------------------------------------------------------");
        $display("2. SPI WRITE COMMAND (Writing 0xAA 0xBB 0xCC 0xDD)");
        $display("---------------------------------------------------------");
        spi_csn = 0; #20;
        spi_byte(8'hC0, dummy_rx); // OPCODE = WRITE
        spi_byte(8'hAA, dummy_rx); // Byte 0
        spi_byte(8'hBB, dummy_rx); // Byte 1
        spi_byte(8'hCC, dummy_rx); // Byte 2
        spi_byte(8'hDD, dummy_rx); // Byte 3
        #20; spi_csn = 1; #50;

        // Verify memory using Port B
        @(posedge clk); pb_addr = 8'h00; @(posedge clk); #1; $display("Read from Mem[0x00]: 0x%02X", pb_rdata);
        @(posedge clk); pb_addr = 8'h01; @(posedge clk); #1; $display("Read from Mem[0x01]: 0x%02X", pb_rdata);
        @(posedge clk); pb_addr = 8'h02; @(posedge clk); #1; $display("Read from Mem[0x02]: 0x%02X", pb_rdata);
        @(posedge clk); pb_addr = 8'h03; @(posedge clk); #1; $display("Read from Mem[0x03]: 0x%02X", pb_rdata);

        $display("\n---------------------------------------------------------");
        $display("3. SPI READ COMMAND (Reading from 0x80..0x83)");
        $display("---------------------------------------------------------");
        spi_csn = 0; #20;
        spi_byte(8'h40, dummy_rx); // OPCODE = READ
        
        for (i = 0; i < 4; i = i + 1) begin
            spi_byte(8'hFF, rx_bytes[i]);
            $display("SPI Received Byte %0d: 0x%02X", i, rx_bytes[i]);
        end
        #20; spi_csn = 1; #50;

        $display("\n---------------------------------------------------------");
        if (rx_bytes[0] == 8'h11 && rx_bytes[1] == 8'h22 && rx_bytes[2] == 8'h33 && rx_bytes[3] == 8'h44) begin
            $display("RESULT: PASS! The SPI Slave works correctly.");
        end else begin
            $display("RESULT: FAIL! The data received over SPI does not match what was written to Memory.");
            $display("Notice how the first byte is wrong, and the rest are shifted by 1 byte!");
        end
        $display("---------------------------------------------------------\n");

        $finish;
    end

endmodule
