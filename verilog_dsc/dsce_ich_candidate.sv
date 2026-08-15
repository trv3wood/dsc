// ------------------------------------------------------------------------------------------------
//     COPYRIGHT © 2021-2023, TRILINEAR TECHNOLOGIES, INC.
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
//     DESCRIPTION : ICH history buffer.  Rebuild to support faster processing times of the
//                   new architecture.  Outputs and array of entries including a valid flag.
// ------------------------------------------------------------------------------------------------

// ----------------------------------------------
//  includes
// ----------------------------------------------
import dsce_defs_pkg::*;


// ----------------------------------------------
//  entity declaration
// ----------------------------------------------
module dsce_ich_candidate
(
    // clock and control interface
    input  logic                    dsc_clk,                        // DSC processing clock
    input  logic                    dsc_reset_n,                    // DSC domain reset
    input  logic [3:0]              cfg_bits_per_component,         // PPS value

    // slice control signals
    input  logic                    dsc_start_of_slice,             // start of the current slice
    input  logic                    dsc_start_of_slice_line,        // start of slice line indicator

    // original pixel input path
    input  logic                    dsc_group_valid_in,             // valid original data in
    input  logic                    dsc_group_last_in,              // last group in the slice
    input  tDSC_PIXEL               dsc_group_in [2:0],             // current source group
    input  tDSC_QLEVEL              dsc_primary_qp,                 // primary QP value

    // ich history input
    input  logic [31:0]             dsc_ich_entry_valid_in,         // ICH entry valid flag
    input  tDSC_PIXEL               dsc_ich_entry_in [31:0],        // ICH pixel values

    // ICH candidate selection
    output logic [2:0]              dsc_ich_hit,                    // ICH hit for each entry
    output tDSC_ICH_INDEX           dsc_ich_index_out [2:0],        // ICH output index
    output tDSC_PIXEL               dsc_ich_pixel_out [2:0]         // ICH pixel value

);

    // ------------------------------------------------------------------------------------------------------------
    //                                          internal definitions
    // ------------------------------------------------------------------------------------------------------------

    // initial calculations
    tDSC_PIXEL                      i_ich_coding_error [2:0] [31:0];
    logic   [16:0]                  i_weighted_sad [2:0] [31:0];

    // maxQerr calculation
    tDSC_QLEVEL                     i_adjusted_bpc;
    tDSC_QLEVEL                     i_adjusted_qp;
    tDSC_QLEVEL                     i_modified_qp;
    tDSC_QLEVEL                     i_mapped_qlevel_y, i_mapped_qlevel_c;
    logic   [15:0]                  i_max_q_error_y, i_max_q_error_c;

    // threshold check per original pixel
    logic   [31:0]                  i_threshold_met_y  [2:0];
    logic   [31:0]                  i_threshold_met_co [2:0];
    logic   [31:0]                  i_threshold_met_cg [2:0];
    logic   [31:0]                  i_suitable_check [2:0];

    // ICH index selection
    tDSC_ICH_INDEX                  i_min_index_stage_1 [2:0] [7:0];
    logic   [16:0]                  i_min_sad_stage_1   [2:0] [7:0];
    tDSC_ICH_INDEX                  i_min_index_stage_2 [2:0] [1:0];
    logic   [16:0]                  i_min_sad_stage_2   [2:0] [1:0];
    tDSC_ICH_INDEX                  i_ich_index_out [2:0];

    // output stage
    logic                           i_enable_pipe;

    // ------------------------------------------------------------------------------------------------------------
    //                                             processes
    // ------------------------------------------------------------------------------------------------------------


    // -------------------------------------------------------
    //  calculate the component/pixel differences
    // -------------------------------------------------------
    always_comb begin : ComparisonMath
        for (int ex = 0; ex < 32; ex++) begin : ICHErrorCalculationLoop
            i_ich_coding_error[0][ex] = dsce_abs_diff_pixel(dsc_group_in[0], dsc_ich_entry_in[ex]);
            i_ich_coding_error[1][ex] = dsce_abs_diff_pixel(dsc_group_in[1], dsc_ich_entry_in[ex]);
            i_ich_coding_error[2][ex] = dsce_abs_diff_pixel(dsc_group_in[2], dsc_ich_entry_in[ex]);

            i_weighted_sad[0][ex] = dsce_weighted_sad_from_diff(i_ich_coding_error[0][ex]);
            i_weighted_sad[1][ex] = dsce_weighted_sad_from_diff(i_ich_coding_error[1][ex]);
            i_weighted_sad[2][ex] = dsce_weighted_sad_from_diff(i_ich_coding_error[2][ex]);
        end : ICHErrorCalculationLoop
    end : ComparisonMath


    // -------------------------------------------------------
    //  determine the maxQerr value
    // -------------------------------------------------------
    always_comb begin : MaxQError
        // maxQerr calculation for Y and C
        i_adjusted_bpc = {cfg_bits_per_component, 1'b0} - 5'd1;
        i_adjusted_qp  = dsc_primary_qp + 5'd2;
        i_modified_qp  = (i_adjusted_qp < i_adjusted_bpc) ? i_adjusted_qp : i_adjusted_bpc;

        i_mapped_qlevel_y = dsce_qp_to_qlevel(kBPC_Y, cfg_bits_per_component, i_modified_qp);
        i_mapped_qlevel_c = dsce_qp_to_qlevel(kBPC_C, cfg_bits_per_component, i_modified_qp);

        i_max_q_error_y = 16'h0001 << (i_mapped_qlevel_y - 5'd1);
        i_max_q_error_c = 16'h0001 << (i_mapped_qlevel_c - 5'd1);
    end : MaxQError


    // -------------------------------------------------------
    //  ICH mode decision threshold check
    // -------------------------------------------------------
    always_comb begin : ThresholdCheck
        for (int tx = 0; tx < 32; tx++) begin : ThresholdCheckLoop
            for (int cx = 0; cx < 3; cx++) begin : GroupCheckLoop
                i_threshold_met_y[cx][tx]  = (i_ich_coding_error[cx][tx].y  > i_max_q_error_y) ? 1'b0 : dsc_ich_entry_valid_in[tx];
                i_threshold_met_co[cx][tx] = (i_ich_coding_error[cx][tx].co > i_max_q_error_c) ? 1'b0 : dsc_ich_entry_valid_in[tx];
                i_threshold_met_cg[cx][tx] = (i_ich_coding_error[cx][tx].cg > i_max_q_error_c) ? 1'b0 : dsc_ich_entry_valid_in[tx];
            end : GroupCheckLoop
        end : ThresholdCheckLoop

        for (int sx = 0; sx < 32; sx++) begin : SuitableCheckLoop
            i_suitable_check[0][sx] = i_threshold_met_y[0][sx] & i_threshold_met_co[0][sx] & i_threshold_met_cg[0][sx];
            i_suitable_check[1][sx] = i_threshold_met_y[1][sx] & i_threshold_met_co[1][sx] & i_threshold_met_cg[1][sx];
            i_suitable_check[2][sx] = i_threshold_met_y[2][sx] & i_threshold_met_co[2][sx] & i_threshold_met_cg[2][sx];
        end : SuitableCheckLoop
    end : ThresholdCheck


    // -------------------------------------------------------
    //  ICH index selection
    // -------------------------------------------------------
    always_comb begin : CandidateIndexSelect
        for (int cx = 0; cx < 3; cx++) begin : CandidateIndexLoop
            // stage 1
            dsce_min_sad4('{5'd31, 5'd30, 5'd29, 5'd28}, i_weighted_sad[cx][31:28], i_min_index_stage_1[cx][7], i_min_sad_stage_1[cx][7]);
            dsce_min_sad4('{5'd27, 5'd26, 5'd25, 5'd24}, i_weighted_sad[cx][27:24], i_min_index_stage_1[cx][6], i_min_sad_stage_1[cx][6]);
            dsce_min_sad4('{5'd23, 5'd22, 5'd21, 5'd20}, i_weighted_sad[cx][23:20], i_min_index_stage_1[cx][5], i_min_sad_stage_1[cx][5]);
            dsce_min_sad4('{5'd19, 5'd18, 5'd17, 5'd16}, i_weighted_sad[cx][19:16], i_min_index_stage_1[cx][4], i_min_sad_stage_1[cx][4]);
            dsce_min_sad4('{5'd15, 5'd14, 5'd13, 5'd12}, i_weighted_sad[cx][15:12], i_min_index_stage_1[cx][3], i_min_sad_stage_1[cx][3]);
            dsce_min_sad4('{5'd11, 5'd10, 5'd9,  5'd8 }, i_weighted_sad[cx][11:8],  i_min_index_stage_1[cx][2], i_min_sad_stage_1[cx][2]);
            dsce_min_sad4('{5'd7,  5'd6,  5'd5,  5'd4 }, i_weighted_sad[cx][7:4],   i_min_index_stage_1[cx][1], i_min_sad_stage_1[cx][1]);
            dsce_min_sad4('{5'd3,  5'd2,  5'd1,  5'd0 }, i_weighted_sad[cx][3:0],   i_min_index_stage_1[cx][0], i_min_sad_stage_1[cx][0]);

            // stage 2
            dsce_min_sad4(i_min_index_stage_1[cx][7:4], i_min_sad_stage_1[cx][7:4], i_min_index_stage_2[cx][1], i_min_sad_stage_2[cx][1]);
            dsce_min_sad4(i_min_index_stage_1[cx][3:0], i_min_sad_stage_1[cx][3:0], i_min_index_stage_2[cx][0], i_min_sad_stage_2[cx][0]);

            // selected index
            i_ich_index_out[cx] = (i_min_sad_stage_2[cx][1] < i_min_sad_stage_2[cx][0]) ? i_min_index_stage_2[cx][1] : i_min_index_stage_2[cx][0];
        end : CandidateIndexLoop
    end : CandidateIndexSelect


    // -------------------------------------------------------
    //  registered outputs for index selection and pixels
    // -------------------------------------------------------
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : OutputStage
        if (dsc_reset_n == 1'b0) begin
            dsc_ich_index_out <= '{default: kDSC_ICH_INDEX_INIT};
            dsc_ich_pixel_out <= '{default: kDSC_PIXEL_INIT};
            dsc_ich_hit <= 3'b000;
            i_enable_pipe <= 1'b0;

        end else begin

            // valid pipeline enable
            i_enable_pipe <= dsc_group_valid_in;

            // final index selection
            for (int px = 0; px < 3; px++) begin : OutputStageLoop
                if (i_enable_pipe == 1'b1) begin
                    dsc_ich_index_out[px] <= i_ich_index_out[px];
                    dsc_ich_pixel_out[px] <= dsc_ich_entry_in[i_ich_index_out[px]];
                end // if
            end : OutputStageLoop

            // first stage check result
            if (i_enable_pipe == 1'b1) begin
                dsc_ich_hit[0] <= (i_suitable_check[0] == 32'h0000_0000) ? 1'b0 : 1'b1;
                dsc_ich_hit[1] <= (i_suitable_check[1] == 32'h0000_0000) ? 1'b0 : 1'b1;
                dsc_ich_hit[2] <= (i_suitable_check[2] == 32'h0000_0000) ? 1'b0 : 1'b1;
            end // if
        end // if
    end : OutputStage

endmodule : dsce_ich_candidate

