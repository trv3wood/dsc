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
//     DESCRIPTION : BP vector selection logic.
// ------------------------------------------------------------------------------------------------

// ----------------------------------------------
//  includes
// ----------------------------------------------
import dsce_defs_pkg::*;


// ----------------------------------------------
//  entity declaration
// ----------------------------------------------
module dsce_bpvector
(
    // clock and control interface
    input  logic                        dsc_clk,                // DSC processing clock
    input  logic                        dsc_reset_n,            // DSC domain reset
    input  tDSCE_CONFIG                 cfg_dsc_encoder,        // general encoder configuration
    input  logic                        dsc_pps_update,         // update pps parameters flag
    input  tDSC_PPS                     cfg_pps,                // parameter set output array

    // input path, current group, previous line group
    input  logic                        dsc_valid_in,           // valid data in
    input  logic                        dsc_last_in,            // last group in a slice(???)
    input  tDSC_PIXEL                   dsc_group_in [2:0],     // source group input
    input  tDSC_PIXEL                   dsc_prev_line_in [5:0], // group from the previous line
    input  tDSC_PIXEL                   dsc_recon_group_in [2:0], // 上一组重建像素反馈

    // pipelined output path
    output logic                        dsc_valid_out,          // valid predicted pixels out
    output logic                        dsc_last_out,           // last group flag output
    output logic                        dsc_use_bp,             // block prediction select
    output logic [3:0]                  dsc_bpvector,           // selected block vector
    output tDSC_PIXEL                   dsc_predict_out [2:0],  // BP prediction
    output tDSC_RESIDUAL_PIXEL          dsc_residual_out [2:0]  // BP residuals
);

    // ------------------------------------------------------------------------------------------------------------
    //                                          internal definitions
    // ------------------------------------------------------------------------------------------------------------

    tDSC_PIXEL          i_prev_line [18:0];
    logic               i_prev_line_valid;
    logic               i_prev_line_last;

    logic [7:0]         i_bpsad [8:0];
    logic               i_sad_valid;
    logic [1:0]         i_sad_last;

    logic [35:0]        i_compare;
    logic [7:0]         i_decision;

    logic               i_last_group_is_partial;
    logic [10:0]        i_bpcount;
    logic [15:0]        i_hpos;

    genvar sx;
    int rx;

    // ------------------------------------------------------------------------------------------------------------
    //                                             processes
    // ------------------------------------------------------------------------------------------------------------

    always_comb begin : DecisionTree
        // 36 comparators total
        i_compare[0]  = (i_bpsad[0] < i_bpsad[1]) ? 1'b1 : 1'b0;
        i_compare[1]  = (i_bpsad[0] < i_bpsad[2]) ? 1'b1 : 1'b0;
        i_compare[2]  = (i_bpsad[0] < i_bpsad[3]) ? 1'b1 : 1'b0;
        i_compare[3]  = (i_bpsad[0] < i_bpsad[4]) ? 1'b1 : 1'b0;
        i_compare[4]  = (i_bpsad[0] < i_bpsad[5]) ? 1'b1 : 1'b0;
        i_compare[5]  = (i_bpsad[0] < i_bpsad[6]) ? 1'b1 : 1'b0;
        i_compare[6]  = (i_bpsad[0] < i_bpsad[7]) ? 1'b1 : 1'b0;
        i_compare[7]  = (i_bpsad[0] < i_bpsad[8]) ? 1'b1 : 1'b0;

        i_compare[8]  = (i_bpsad[1] < i_bpsad[2]) ? 1'b1 : 1'b0;
        i_compare[9]  = (i_bpsad[1] < i_bpsad[3]) ? 1'b1 : 1'b0;
        i_compare[10] = (i_bpsad[1] < i_bpsad[4]) ? 1'b1 : 1'b0;
        i_compare[11] = (i_bpsad[1] < i_bpsad[5]) ? 1'b1 : 1'b0;
        i_compare[12] = (i_bpsad[1] < i_bpsad[6]) ? 1'b1 : 1'b0;
        i_compare[13] = (i_bpsad[1] < i_bpsad[7]) ? 1'b1 : 1'b0;
        i_compare[14] = (i_bpsad[1] < i_bpsad[8]) ? 1'b1 : 1'b0;

        i_compare[15] = (i_bpsad[2] < i_bpsad[3]) ? 1'b1 : 1'b0;
        i_compare[16] = (i_bpsad[2] < i_bpsad[4]) ? 1'b1 : 1'b0;
        i_compare[17] = (i_bpsad[2] < i_bpsad[5]) ? 1'b1 : 1'b0;
        i_compare[18] = (i_bpsad[2] < i_bpsad[6]) ? 1'b1 : 1'b0;
        i_compare[19] = (i_bpsad[2] < i_bpsad[7]) ? 1'b1 : 1'b0;
        i_compare[20] = (i_bpsad[2] < i_bpsad[8]) ? 1'b1 : 1'b0;

        i_compare[21] = (i_bpsad[3] < i_bpsad[4]) ? 1'b1 : 1'b0;
        i_compare[22] = (i_bpsad[3] < i_bpsad[5]) ? 1'b1 : 1'b0;
        i_compare[23] = (i_bpsad[3] < i_bpsad[6]) ? 1'b1 : 1'b0;
        i_compare[24] = (i_bpsad[3] < i_bpsad[7]) ? 1'b1 : 1'b0;
        i_compare[25] = (i_bpsad[3] < i_bpsad[8]) ? 1'b1 : 1'b0;

        i_compare[26] = (i_bpsad[4] < i_bpsad[5]) ? 1'b1 : 1'b0;
        i_compare[27] = (i_bpsad[4] < i_bpsad[6]) ? 1'b1 : 1'b0;
        i_compare[28] = (i_bpsad[4] < i_bpsad[7]) ? 1'b1 : 1'b0;
        i_compare[29] = (i_bpsad[4] < i_bpsad[8]) ? 1'b1 : 1'b0;

        i_compare[30] = (i_bpsad[5] < i_bpsad[6]) ? 1'b1 : 1'b0;
        i_compare[31] = (i_bpsad[5] < i_bpsad[7]) ? 1'b1 : 1'b0;
        i_compare[32] = (i_bpsad[5] < i_bpsad[8]) ? 1'b1 : 1'b0;

        i_compare[33] = (i_bpsad[6] < i_bpsad[7]) ? 1'b1 : 1'b0;
        i_compare[34] = (i_bpsad[6] < i_bpsad[8]) ? 1'b1 : 1'b0;

        i_compare[35] = (i_bpsad[7] < i_bpsad[8]) ? 1'b1 : 1'b0;

        // decision maker
        i_decision[0] = ((i_compare[0] && i_compare[1]) && (i_compare[2] && i_compare[3])) && ((i_compare[4] && i_compare[5]) && (i_compare[6] && i_compare[7]));
        i_decision[1] = ((!i_compare[0] && i_compare[8]) && (i_compare[9] && i_compare[10])) && ((i_compare[11] && i_compare[12]) && (i_compare[13] && i_compare[14]));
        i_decision[2] = ((!i_compare[1] && !i_compare[8]) && (i_compare[15] && i_compare[16])) && ((i_compare[17] && i_compare[18]) && (i_compare[19] && i_compare[20]));
        i_decision[3] = ((!i_compare[2] && !i_compare[9]) && (!i_compare[15] && i_compare[21])) && ((i_compare[22] && i_compare[23]) && (i_compare[24] && i_compare[25]));
        i_decision[4] = ((!i_compare[3] && !i_compare[10]) && (!i_compare[16] && !i_compare[21])) && ((i_compare[26] && i_compare[27]) && (i_compare[28] && i_compare[29]));
        i_decision[5] = ((!i_compare[4] && !i_compare[11]) && (!i_compare[17] && !i_compare[22])) && ((!i_compare[26] && i_compare[30]) && (i_compare[31] && i_compare[32]));
        i_decision[6] = ((!i_compare[5] && !i_compare[12]) && (!i_compare[18] && !i_compare[23])) && ((!i_compare[27] && !i_compare[30]) && (i_compare[33] && i_compare[34]));
        i_decision[7] = ((!i_compare[6] && !i_compare[13]) && (!i_compare[19] && !i_compare[24])) && ((!i_compare[28] && !i_compare[31]) && (!i_compare[33] && i_compare[35]));

        // register copy
        i_last_group_is_partial = (cfg_dsc_encoder.slice_width_alignment == 3'b111) ? 1'b0 : 1'b1;
    end : DecisionTree


    // -------------------------------------------------------
    //  Previous line buffering
    // -------------------------------------------------------
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : PixelBuffer
        if (dsc_reset_n == 1'b0) begin
            i_prev_line_valid <= 1'b0;
            i_prev_line_last <= 1'b0;
            i_prev_line <= '{default: kDSC_PIXEL_INIT};

        end else begin

            // store the previous pixels
            if (dsc_valid_in == 1'b1) begin
                i_prev_line[18:13] <= dsc_prev_line_in;
                i_prev_line[12:0]  <= i_prev_line[18:6];
            end // if

            i_prev_line_valid <= dsc_valid_in;
            i_prev_line_last <= dsc_last_in;

        end // if
    end : PixelBuffer


    // -------------------------------------------------------
    //  SAD decision staging
    // -------------------------------------------------------

    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : DecisionStage
        if (dsc_reset_n == 1'b0) begin
            dsc_valid_out <= 1'b0;
            dsc_last_out <= 1'b0;
            dsc_bpvector <= 4'd0;
            dsc_use_bp <= 1'b0;
            dsc_residual_out <= '{default:kDSC_RESIDUAL_PIXEL_INIT};
            dsc_predict_out <= '{default:kDSC_PIXEL_INIT};

            i_bpcount <= 11'd0;
            i_sad_last <= 2'b00;
            i_hpos <= 16'd0;

        end else begin

            // unused (will be deprecated in revision 2.5)
            dsc_use_bp <= 1'b0;

            // pipeline the last signal
            i_sad_last <= {i_sad_last[0], i_prev_line_last};

            // sort the vectors
            dsc_valid_out <= i_sad_valid;
            dsc_last_out <= i_sad_last[1];

            case (i_decision)
                8'h01:   dsc_bpvector <= 4'd0;
                8'h02:   dsc_bpvector <= 4'd1;
                8'h04:   dsc_bpvector <= 4'd2;
                8'h08:   dsc_bpvector <= 4'd3;
                8'h10:   dsc_bpvector <= 4'd4;
                8'h20:   dsc_bpvector <= 4'd5;
                8'h40:   dsc_bpvector <= 4'd6;
                8'h80:   dsc_bpvector <= 4'd7;
                default: dsc_bpvector <= 4'd8;
            endcase

            // keep track of the count
            if (i_sad_valid == 1'b1) begin
                if (i_decision == 8'h01 || (i_sad_last[1] == 1'b1 && i_last_group_is_partial == 1'b1) || dsc_last_out == 1'b1) begin
                    i_bpcount <= 11'd0;
                end else if (i_hpos > 16'd9) begin
                    i_bpcount <= i_bpcount + 11'd1;
                end // if
            end // if

            // horizontal position
            if (dsc_last_out == 1'b1) begin
                i_hpos <= 16'd0;
            end else if (i_sad_valid == 1'b1) begin
                i_hpos <= i_hpos + 16'd3;
            end // if

            // residual calculation
            for (rx = 0; rx < 3; rx++) begin : ResidualLoop
                dsc_residual_out[rx].res_y  <= dsce_compute_residual(dsc_prev_line_in[rx].y, dsc_group_in[rx].y);
                dsc_residual_out[rx].res_co <= dsce_compute_residual(dsc_prev_line_in[rx].co, dsc_group_in[rx].co);
                dsc_residual_out[rx].res_cg <= dsce_compute_residual(dsc_prev_line_in[rx].cg, dsc_group_in[rx].cg);
                dsc_predict_out[rx] <= dsc_group_in[rx];
            end : ResidualLoop
        end // if
    end : DecisionStage


    // ------------------------------------------------------------------------------------------------------------
    //                                             SAD blocks
    // ------------------------------------------------------------------------------------------------------------

    dsce_sad  dsce_sad_m1_inst
    (
        // clock and control interface
        .dsc_clk            (dsc_clk),
        .dsc_reset_n        (dsc_reset_n),
        .dsc_color_mode     (kDSC_COLOR_DEFAULT),
        // data path, two lines
        .dsc_valid_in       (i_prev_line_valid),
        .dsc_ref_in         (i_prev_line[18:10]),
        .dsc_search_in      (i_prev_line[17:9]),
        .dsc_valid_out      (i_sad_valid),
        .dsc_bpsad          (i_bpsad[0])
    );

    generate for (sx = 1; sx < 9; sx++) begin : gen_sad_array
        dsce_sad  dsce_sad_array_inst
        (
            // clock and control interface
            .dsc_clk            (dsc_clk),
            .dsc_reset_n        (dsc_reset_n),
            .dsc_color_mode     (kDSC_COLOR_DEFAULT),
            // data path, two lines
            .dsc_valid_in       (i_prev_line_valid),
            .dsc_ref_in         (i_prev_line[18:10]),
            .dsc_search_in      (i_prev_line[16-sx:8-sx]),
            .dsc_valid_out      (),
            .dsc_bpsad          (i_bpsad[sx])
        );
    end endgenerate

endmodule : dsce_bpvector
