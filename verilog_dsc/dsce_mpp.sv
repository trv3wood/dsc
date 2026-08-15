// ------------------------------------------------------------------------------------------------
//     COPYRIGHT © 2015-2023, TRILINEAR TECHNOLOGIES, INC.
//     CONFIDENTIAL AND PROPRIETARY
//
//     THE SOURCE CODE CONTAINED HEREIN IS PROVIDED ON AN "AS IS" BASIS.
//     TRILINEAR TECHNOLOGIES, INC. DISCLAIMS ANY AND ALL WARRANTIES,
//     WHETHER EXPRESS, IMPLIED, OR STATUTORY, INCLUDING ANY IMPLIED
//     WARRANTIES OF MERCHANTABILITY OR OF FITNESS FOR A PARTICULAR PURPOSE.
//     IN NO EVENT SHALL TRILINEAR TECHNOLOGIES, INC. BE LIABLE FOR ANY
//     INCIDENTAL, PUNITIVE, OR CONSEQUENTIAL DAMAGES OF ANY KIND WHATSOEVER
//     ARISING FROM THE USE OF THIS SOURCE CODE.
//
//     THIS DISCLAIMER OF WARRANTY EXTENDS TO THE USER OF THIS SOURCE CODE
//     AND USER'S CUSTOMERS, EMPLOYEES, AGENTS, TRANSFEREES, SUCCESSORS,
//     AND ASSIGNS.
//
//     THIS IS NOT A GRANT OF PATENT RIGHTS
// ------------------------------------------------------------------------------------------------
//     DESCRIPTION : DSC encoder midpoint prediciton block.
// ------------------------------------------------------------------------------------------------

// ----------------------------------------------
//  includes
// ----------------------------------------------
import dsce_defs_pkg::*;


// ----------------------------------------------
//  entity declaration
// ----------------------------------------------
module dsce_mpp
#(
    parameter int pCOMPONENT_SELECT = 0                     // select chroma plane processing
)
(
    // clock and control interface
    input  logic                dsc_clk,                    // DSC processing clock
    input  logic                dsc_reset_n,                // DSC domain reset
    input  logic                dsc_pps_update,             // update pps parameters flag
    input  tDSC_PPS             cfg_pps,                    // parameter set output array

    // input samples
    input  logic                dsc_start_of_slice,         // start of new slice
    input  logic                dsc_group_valid_in,         // valid data in
    input  logic                dsc_group_last_in,          // last group in
    input  tDSC_QLEVEL          dsc_qlevel,                 // color specific qlevel value
    input  tDSC_COMPONENT       dsc_group_in [2:0],         // source group input
    input  tDSC_COMPONENT       dsc_right_in,               // rightmost residual value

    // output predictors
    output logic                dsc_predict_valid_out,      // valid predicted pixels out
    output logic                dsc_predict_last_out,       // last group out
    output tDSC_COMPONENT       dsc_predict_out [2:0],      // predicted group output
    output tDSC_RESIDUAL        dsc_residual_out [2:0]      // MPP residuals
);

    // ------------------------------------------------------------------------------------------------------------
    //                                          internal definitions
    // ------------------------------------------------------------------------------------------------------------

    logic           [3:0]       i_cpnt_bit_depth;
    logic           [15:0]      i_qlevel_mask;
    logic           [3:1]       i_valid_pipe;
    logic           [3:1]       i_last_pipe;
    tDSC_COMPONENT              i_right_sample;

    logic           [15:0]      i_cpnt_mid;
    logic           [4:0]       i_chroma_offset;

    tDSC_COMPONENT              i_predict_mpp;
    tDSC_RESIDUAL               i_calculated_residual [2:0];

    // ------------------------------------------------------------------------------------------------------------
    //                                             processes
    // ------------------------------------------------------------------------------------------------------------

    always_comb begin : SignalMap
        i_chroma_offset = (pCOMPONENT_SELECT == 0) ? 5'd1 : 5'd0;
        i_predict_mpp = i_cpnt_mid + (i_right_sample & i_qlevel_mask);

        for (int crx = 0; crx < 3; crx++) begin : CalculateResidualLoop
            i_calculated_residual[crx] = dsce_compute_residual(i_predict_mpp, dsc_group_in[crx]);
        end : CalculateResidualLoop
    end : SignalMap


    // midpoint prediction pipeline
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : MPP
        if (dsc_reset_n == 1'b0) begin
            dsc_predict_out <= '{default: kDSC_COMPONENT_INIT};
            dsc_residual_out <= '{default: kDSC_RESIDUAL_INIT};
            dsc_predict_valid_out <= 1'b0;
            dsc_predict_last_out <= 1'b0;

            i_valid_pipe <= 3'h0;
            i_last_pipe <= 3'h0;
            i_cpnt_mid <= 16'h0000;
            i_qlevel_mask <= 16'hffff;
            i_cpnt_bit_depth <= 4'd0;
            i_right_sample <= kDSC_COMPONENT_INIT;

        end else begin

            // --------------------------------------
            //  encode parameters and enable output
            // --------------------------------------
            if (dsc_pps_update == 1'b1) begin
                if (cfg_pps.bits_per_component == 4'd0 || cfg_pps.convert_rgb == 1'b0) begin
                    i_cpnt_bit_depth <= cfg_pps.bits_per_component - 4'd1;
                end else begin
                    i_cpnt_bit_depth <= cfg_pps.bits_per_component - i_chroma_offset;
                end // if
            end // if

            if (dsc_group_valid_in == 1'b1) begin
                i_qlevel_mask <= (16'hffff) >> (5'd16-dsc_qlevel);
            end // if

            if (i_valid_pipe[1] == 1'b1)  begin
                i_right_sample <= dsc_right_in;
            end // if

            i_valid_pipe <= {i_valid_pipe[2:1], dsc_group_valid_in};
            i_last_pipe <= {i_last_pipe[2:1], dsc_group_last_in};

            case (i_cpnt_bit_depth)
                4'd8:    i_cpnt_mid <= 16'h0100;
                4'd9:    i_cpnt_mid <= 16'h0200;
                4'd10:   i_cpnt_mid <= 16'h0400;
                4'd11:   i_cpnt_mid <= 16'h0800;
                4'd12:   i_cpnt_mid <= 16'h1000;
                4'd13:   i_cpnt_mid <= 16'h2000;
                4'd14:   i_cpnt_mid <= 16'h4000;
                4'd15:   i_cpnt_mid <= 16'h8000;
                default: i_cpnt_mid <= 16'h0080;
            endcase

            // --------------------------------------
            //  pipelined logic
            // --------------------------------------

            dsc_predict_valid_out <= i_valid_pipe[3];
            dsc_predict_last_out <= i_last_pipe[3];

            for (int px = 0; px < 3; px++) begin : ComputedOutputMappingLoop
                if (i_valid_pipe[2] == 1'b1) begin
                    dsc_predict_out[px] <= i_predict_mpp;
                    dsc_residual_out[px] <= i_calculated_residual[px];
                end // if
            end : ComputedOutputMappingLoop

        end // if
    end : MPP

endmodule : dsce_mpp

