// =============================================================================
// tpm_trng.v — True Random Number Generator
// =============================================================================
// Three independent ring-oscillator cells. Each cell is an odd chain of
// inverters connected in feedback. On real silicon the oscillation frequency
// drifts due to thermal noise — this jitter is the physical entropy source.
//
// (* keep *) stops Yosys from removing the combinational feedback loops.
// Verify in the post-synthesis netlist that all three rings survived.
//
// Simulation note: ring oscillator loops evaluate to X in RTL simulation.
//   Compile with +define+SIMULATION to use $random-based byte generation.
//
// Output: one random byte every ~DECIM clock cycles after enable.
// =============================================================================
`timescale 1ns/1ps

module tpm_trng #(parameter DECIM = 16)(
    input  wire       clk,
    input  wire       rstn,
    input  wire       enable,
    output reg  [7:0] data,
    output reg        valid
);

`ifdef SIMULATION
// ---------------------------------------------------------------------------
// Simulation model: generate a fresh $random byte every DECIM clocks.
// Ring oscillator combinational loops are X in simulation (no initial state).
// ---------------------------------------------------------------------------
reg [$clog2(DECIM)-1:0] sim_cnt;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        sim_cnt <= 0;
        data    <= 8'hA5;
        valid   <= 0;
    end else begin
        valid <= 0;
        if (enable) begin
            if (sim_cnt == DECIM - 1) begin
                sim_cnt <= 0;
                data    <= $random;
                valid   <= 1;
            end else begin
                sim_cnt <= sim_cnt + 1;
            end
        end else begin
            sim_cnt <= 0;
        end
    end
end

`else
// ---------------------------------------------------------------------------
// Ring oscillators (3 cells, different lengths → different frequencies)
// ---------------------------------------------------------------------------
(* keep *) wire [4:0]  ro0;   // 5-inverter ring
(* keep *) wire [6:0]  ro1;   // 7-inverter ring
(* keep *) wire [8:0]  ro2;   // 9-inverter ring

assign ro0[0] = ~ro0[4];
assign ro0[1] = ~ro0[0];
assign ro0[2] = ~ro0[1];
assign ro0[3] = ~ro0[2];
assign ro0[4] = ~ro0[3];

assign ro1[0] = ~ro1[6];
assign ro1[1] = ~ro1[0];
assign ro1[2] = ~ro1[1];
assign ro1[3] = ~ro1[2];
assign ro1[4] = ~ro1[3];
assign ro1[5] = ~ro1[4];
assign ro1[6] = ~ro1[5];

assign ro2[0] = ~ro2[8];
assign ro2[1] = ~ro2[0];
assign ro2[2] = ~ro2[1];
assign ro2[3] = ~ro2[2];
assign ro2[4] = ~ro2[3];
assign ro2[5] = ~ro2[4];
assign ro2[6] = ~ro2[5];
assign ro2[7] = ~ro2[6];
assign ro2[8] = ~ro2[7];

// XOR three oscillator outputs
wire raw = ro0[0] ^ ro1[0] ^ ro2[0];

// ---------------------------------------------------------------------------
// Decimation: sample raw every DECIM system clock cycles
// ---------------------------------------------------------------------------
reg [$clog2(DECIM)-1:0] dcnt;
reg                      pulse;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin dcnt <= 0; pulse <= 0; end
    else if (enable) begin
        pulse <= 0;
        if (dcnt == DECIM-1) begin dcnt <= 0; pulse <= 1; end
        else                      dcnt <= dcnt + 1;
    end else begin dcnt <= 0; pulse <= 0; end
end

// ---------------------------------------------------------------------------
// Von Neumann de-bias
// ---------------------------------------------------------------------------
reg vn_phase, vn_prev, vn_bit, vn_ok;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin vn_phase<=0; vn_prev<=0; vn_bit<=0; vn_ok<=0; end
    else begin
        vn_ok <= 0;
        if (pulse) begin
            if (!vn_phase) begin vn_prev <= raw; vn_phase <= 1; end
            else begin
                vn_phase <= 0;
                if (raw != vn_prev) begin vn_bit <= raw; vn_ok <= 1; end
            end
        end
    end
end

// ---------------------------------------------------------------------------
// 8-bit shift register
// ---------------------------------------------------------------------------
reg [7:0] sr;
reg [2:0] bcnt;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin sr<=0; bcnt<=0; data<=0; valid<=0; end
    else begin
        valid <= 0;
        if (vn_ok) begin
            sr   <= {sr[6:0], vn_bit};
            bcnt <= bcnt + 1;
            if (bcnt == 7) begin data <= {sr[6:0], vn_bit}; valid <= 1; end
        end
    end
end
`endif

endmodule
