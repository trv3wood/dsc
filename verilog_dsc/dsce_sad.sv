// ------------------------------------------------------------------------------------------------
//     COPYRIGHT © 2015-2021, TRILINEAR TECHNOLOGIES, INC.
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
//     DESCRIPTION : Summed absolute difference for the calculation of the bpSad value
//                   required for finding the lowest bpVector.
//
//                      reference array is [8:0] with 0 the left-most pixel
//                      search array is [8:0] with 0 the left-most pixel
// ------------------------------------------------------------------------------------------------


// ----------------------------------------------
//  includes
// ----------------------------------------------
import dsce_defs_pkg::*;


// ----------------------------------------------
//  entity declaration
// ----------------------------------------------
module dsce_sad
(
    // clock and control interface
    input  logic                    dsc_clk,            // DSC processing clock
    input  logic                    dsc_reset_n,        // DSC domain reset
    input  var tDSC_COLOR_MODE      dsc_color_mode,     // color mode

    // data path, two lines
    input  logic                    dsc_valid_in,       // valid data in
    input  tDSC_PIXEL               dsc_ref_in [8:0],   // reference pixels
    input  tDSC_PIXEL               dsc_search_in [8:0],// search pixels
    output logic                    dsc_valid_out,      // valid predicted pixels out
    output logic [7:0]              dsc_bpsad           // 9 pixel candidate vector SAD
);

    // ------------------------------------------------------------------------------------------------------------
    //                                          internal definitions
    // ------------------------------------------------------------------------------------------------------------

    // packed differences
    logic [9:0]         i_mad_y [8:0];
    logic [9:0]         i_mad_co [8:0];
    logic [9:0]         i_mad_cg [8:0];

    // packed arrays
    logic [9:0]         i_sad3x1 [2:0];
    logic [10:0]        i_sad3x1_final [2:0];
    logic [10:0]        i_sad9x1;
    logic               i_sad3x1_valid;

    // compute the difference of a single component
    function automatic logic [5:0] modified_abs_diff (
        input [15:0] ref_cpnt,
        input [15:0] src_cpnt
    );
        logic signed [16:0] signed_diff;
        logic [15:0] abs_diff;

        signed_diff = $signed({1'b0, ref_cpnt}) - $signed({1'b0, src_cpnt});
        abs_diff = (signed_diff[16] == 1'b1) ? (~signed_diff[15:0] + 16'd1) : signed_diff[15:0];
        modified_abs_diff = (abs_diff[15] == 1'b1) ? 6'h3f : abs_diff[14:9];
    endfunction : modified_abs_diff

    // ------------------------------------------------------------------------------------------------------------
    //                                             processes
    // ------------------------------------------------------------------------------------------------------------

    genvar dx;
    generate for (dx = 0; dx < 9; dx++) begin : gen_component_mad
            assign i_mad_y[dx]  = {4'h0, modified_abs_diff(dsc_ref_in[dx].y,  dsc_search_in[dx].y)};
            assign i_mad_co[dx] = {4'h0, modified_abs_diff(dsc_ref_in[dx].co, dsc_search_in[dx].co)};
            assign i_mad_cg[dx] = {4'h0, modified_abs_diff(dsc_ref_in[dx].cg, dsc_search_in[dx].cg)};
    end endgenerate

    always_comb begin : Clamp
        i_sad3x1_final[0] = (i_sad3x1[0][9] == 1'b1) ? 11'd511 : {2'b00, i_sad3x1[0][8:0]};
        i_sad3x1_final[1] = (i_sad3x1[1][9] == 1'b1) ? 11'd511 : {2'b00, i_sad3x1[1][8:0]};
        i_sad3x1_final[2] = (i_sad3x1[2][9] == 1'b1) ? 11'd511 : {2'b00, i_sad3x1[2][8:0]};

        i_sad9x1 = (i_sad3x1_final[0] + i_sad3x1_final[1]) + i_sad3x1_final[2];            // 9-bit sums to 11 bits
    end : Clamp

    // -------------------------------------------------------
    //  pipeline stages
    // -------------------------------------------------------

    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : PipelineStages
        if (dsc_reset_n == 1'b0) begin
            i_sad3x1 <= '{default:10'd0};
            dsc_bpsad <= 8'd0;
            i_sad3x1_valid <= 1'b0;
            dsc_valid_out <= 1'b0;

        end else begin
            // 3x1 values
            i_sad3x1[0] <= ((i_mad_y[0] + i_mad_co[0]) + (i_mad_cg[0] + i_mad_y[1])) + ((i_mad_co[1] + i_mad_cg[1]) + (i_mad_y[2] + i_mad_co[2])) + i_mad_cg[2];
            i_sad3x1[1] <= ((i_mad_y[3] + i_mad_co[3]) + (i_mad_cg[3] + i_mad_y[4])) + ((i_mad_co[4] + i_mad_cg[4]) + (i_mad_y[5] + i_mad_co[5])) + i_mad_cg[5];
            i_sad3x1[2] <= ((i_mad_y[6] + i_mad_co[6]) + (i_mad_cg[6] + i_mad_y[7])) + ((i_mad_co[7] + i_mad_cg[7]) + (i_mad_y[8] + i_mad_co[8])) + i_mad_cg[8];
            i_sad3x1_valid <= dsc_valid_in;

            // output sum stages
            dsc_valid_out <= i_sad3x1_valid;
            dsc_bpsad <= i_sad9x1[10:3];
        end // if
    end : PipelineStages

endmodule : dsce_sad

