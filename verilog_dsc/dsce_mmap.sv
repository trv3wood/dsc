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
//     DESCRIPTION : Modified median adaptive prediction block.  This block operates on a single
//                   component of each group to form the predictor.
// ------------------------------------------------------------------------------------------------

// ----------------------------------------------
//  includes
// ----------------------------------------------
import dsce_defs_pkg::*;


// ----------------------------------------------
//  entity declaration
// ----------------------------------------------
module dsce_mmap
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
    input  logic                dsc_group_valid_in,         // valid data in
    input  logic                dsc_group_last_in,          // last group in
    input  logic                dsc_start_of_slice,         // start of a slice
    input  tDSC_COMPONENT       dsc_line_prev_in [5:0],     // pixels from the previous line
    input  tDSC_COMPONENT       dsc_group_in [2:0],         // current group input
    input  tDSC_COMPONENT       dsc_right_in,               // rightmost pixel, reconstructed
    input  tDSC_QLEVEL          dsc_qlevel,                 // color specific qlevel value

    // output predictors
    output logic                dsc_valid_out,              // valid predicted pixels out
    output tDSC_COMPONENT       dsc_predict_out [2:0],      // predicted group output
    output tDSC_RESIDUAL        dsc_residual_out [2:0]      // MMAP residuals
);

    // ------------------------------------------------------------------------------------------------------------
    //                                          internal definitions
    // ------------------------------------------------------------------------------------------------------------

    logic                       i_first_line;
    logic                       i_first_group;
    logic                       i_last_group;
    tDSC_COMPONENT              i_midrange_sample;
    tDSC_COMPONENT              i_component_max;

    enum {
        eMMS_PARTIAL_S0,
        eMMS_P0_S1,
        eMMS_P1_S2,
        eMMS_P2_S3
    } i_mmap_state;

    // 0 = sample stage valid, 1 = blend stage valid
    logic [1:0]                 i_pipe_slice;
    logic [2:0]                 i_pipe_last;

    tDSC_QLEVEL                 i_qlevel;
    logic [15:0]                i_filter [3:0];
    logic [15:0]                i_right_sample;
    logic signed [16:0]         i_diff [3:0];
    logic signed [16:0]         i_blend [3:0];
    logic [15:0]                i_min [2:0], i_min_reg [2:1];
    logic [15:0]                i_max [2:0], i_max_reg [2:1];
    logic signed [16:0]         i_predict_pipeline [1:0];

    logic signed [16:0]         i_predict_calculation_stage_0 [2:0];
    logic signed [16:0]         i_predict_calculation_stage_1 [2:0];

    tDSC_RESIDUAL               i_residual_calculation [2:0];

    tDSC_COMPONENT              i_group_in [2:0];
    tDSC_RESIDUAL               i_quantized_residual [1:0];

    localparam int kFILTER_B = 0;
    localparam int kFILTER_C = 1;
    localparam int kFILTER_D = 2;
    localparam int kFILTER_E = 3;

    localparam int kPREVIOUS_LINE_G = 0;
    localparam int kPREVIOUS_LINE_C = 1;
    localparam int kPREVIOUS_LINE_B = 2;
    localparam int kPREVIOUS_LINE_D = 3;
    localparam int kPREVIOUS_LINE_E = 4;
    localparam int kPREVIOUS_LINE_F = 5;


    // ------------------------------------------------------------------------------------------------------------
    //                                          support functions
    // ------------------------------------------------------------------------------------------------------------

    //
    //  calculate the inverse quantized residual
    //
    function automatic tDSC_RESIDUAL dsce_invquant_residual (
        input logic signed [16:0]   predict_sample,
        input tDSC_COMPONENT orig_sample,
        input tDSC_QLEVEL    qlevel
    );
        tDSC_RESIDUAL full_residual;
        tDSC_RESIDUAL quant_residual;

        full_residual = $signed({1'b0, orig_sample}) - predict_sample;
        quant_residual = dsce_quantization(full_residual, qlevel);
        dsce_invquant_residual = dsce_invquantization(quant_residual, qlevel);
    endfunction : dsce_invquant_residual


    //
    //  component filtering function
    //
    function automatic logic [16:0] dsce_filter3 (
        input logic [16:0] left,
        input logic [16:0] center,
        input logic [16:0] right
    );
        logic [18:0] i_pixel_sum;

        i_pixel_sum = ({2'b00, left} + {1'b0, center, 1'b0}) + ({2'b00, right} + 18'd2);
        dsce_filter3 = i_pixel_sum[18:2];
    endfunction : dsce_filter3

    //
    //  difference clamp to range
    //
    function automatic logic signed [16:0] dsce_clamp_diff (
        input logic signed [16:0] diff,
        input tDSC_QLEVEL         qlevel
    );
        logic signed [16:0] pos_clamp, neg_clamp;
        logic [1:0]         compare;
        logic signed [16:0] result;

        if (qlevel == kDSC_QLEVEL_ZERO) begin
            pos_clamp = 17'h00000;
            neg_clamp = 17'h00000; //17'h1ffff;
        end else begin
            pos_clamp = 17'h00001 << (qlevel - 5'd1);
            neg_clamp = 17'h1ffff << (qlevel - 5'd1);
        end // if

        compare[0] = (diff > pos_clamp) ? 1'b1 : 1'b0;
        compare[1] = (diff < neg_clamp) ? 1'b1 : 1'b0;

        case (compare)
            2'b01:    result = pos_clamp;
            2'b10:    result = neg_clamp;
            default:  result = diff;
        endcase

        return (result);
    endfunction : dsce_clamp_diff

    //
    //  clamp the predicted pixels
    //
    function automatic logic signed [16:0] dsce_clamp_sample (
        input logic [16:0] sample_in,
        input logic [15:0] sample_min,
        input logic [15:0] sample_max
    );
        logic [1:0]  compare;

        compare[0] = (sample_in[15:0] < sample_min) ? 1'b1 : 1'b0;
        compare[1] = (sample_in[15:0] > sample_max) ? 1'b1 : 1'b0;

        if (sample_in[16] == 1'b1) begin
            dsce_clamp_sample = {1'b0, sample_min};
        end else begin
            case (compare)
                2'b01:   dsce_clamp_sample = {1'b0, sample_min};
                2'b10:   dsce_clamp_sample = {1'b0, sample_max};
                default: dsce_clamp_sample = sample_in;
            endcase
        end // if
    endfunction : dsce_clamp_sample


    // ------------------------------------------------------------------------------------------------------------
    //                                             processes
    // ------------------------------------------------------------------------------------------------------------

    // signal assignments
    always_comb begin : SignalMap
        // create the filtered inputs from the previous line
        i_filter[kFILTER_B] = dsce_filter3(dsc_line_prev_in[kPREVIOUS_LINE_C], dsc_line_prev_in[kPREVIOUS_LINE_B], dsc_line_prev_in[kPREVIOUS_LINE_D]);
        i_filter[kFILTER_C] = dsce_filter3(dsc_line_prev_in[kPREVIOUS_LINE_G], dsc_line_prev_in[kPREVIOUS_LINE_C], dsc_line_prev_in[kPREVIOUS_LINE_B]);
        i_filter[kFILTER_D] = dsce_filter3(dsc_line_prev_in[kPREVIOUS_LINE_B], dsc_line_prev_in[kPREVIOUS_LINE_D], dsc_line_prev_in[kPREVIOUS_LINE_E]);
        i_filter[kFILTER_E] = dsce_filter3(dsc_line_prev_in[kPREVIOUS_LINE_D], dsc_line_prev_in[kPREVIOUS_LINE_E], dsc_line_prev_in[kPREVIOUS_LINE_F]);

        // compute the raw differences
        i_diff[kFILTER_B] = dsce_clamp_diff($signed({1'b0, i_filter[kFILTER_B]}) - $signed({1'b0, dsc_line_prev_in[kPREVIOUS_LINE_B]}), dsc_qlevel);
        i_diff[kFILTER_C] = dsce_clamp_diff($signed({1'b0, i_filter[kFILTER_C]}) - $signed({1'b0, dsc_line_prev_in[kPREVIOUS_LINE_C]}), dsc_qlevel);
        i_diff[kFILTER_D] = dsce_clamp_diff($signed({1'b0, i_filter[kFILTER_D]}) - $signed({1'b0, dsc_line_prev_in[kPREVIOUS_LINE_D]}), dsc_qlevel);
        i_diff[kFILTER_E] = dsce_clamp_diff($signed({1'b0, i_filter[kFILTER_E]}) - $signed({1'b0, dsc_line_prev_in[kPREVIOUS_LINE_E]}), dsc_qlevel);

        // min/max prediction values
        if (i_first_line == 1'b1) begin
            i_min = '{default: 16'd0};
            i_max = '{default:i_component_max};
        end else begin
            i_min[0] = dsce_min_2(i_right_sample, i_blend[kFILTER_B]);
            i_max[0] = dsce_max_2(i_right_sample, i_blend[kFILTER_B]);
            i_min[1] = dsce_min_2(i_min[0], i_blend[kFILTER_D]);
            i_max[1] = dsce_max_2(i_max[0], i_blend[kFILTER_D]);
            i_min[2] = dsce_min_2(i_min[1], i_blend[kFILTER_E]);
            i_max[2] = dsce_max_2(i_max[1], i_blend[kFILTER_E]);
        end // if

    end : SignalMap


    // -------------------------------------------------------
    //  prediction calculations for pipeline retiming
    // -------------------------------------------------------
    always_comb begin : PredictionCalculations
        // ----- pipeline stage 0 ----- //
        i_predict_calculation_stage_0[0] = dsce_clamp_sample(i_right_sample + i_blend[kFILTER_B] - i_blend[kFILTER_C], i_min[0], i_max[0]);
        i_predict_calculation_stage_0[1] = i_right_sample + i_blend[kFILTER_D] - i_blend[kFILTER_C];
        i_predict_calculation_stage_0[2] = i_right_sample + i_blend[kFILTER_E] - i_blend[kFILTER_C];

        i_quantized_residual[0] = dsce_invquant_residual(i_predict_pipeline[0], i_group_in[0], i_qlevel);

        // ----- pipeline stage 1 ----- //
        i_predict_calculation_stage_1[0] = i_predict_pipeline[0];
        i_predict_calculation_stage_1[1] = dsce_clamp_sample(i_predict_pipeline[1] + i_quantized_residual[0], i_min_reg[1], i_max_reg[1]);

        i_quantized_residual[1] = dsce_invquant_residual(i_predict_calculation_stage_1[1], i_group_in[1], i_qlevel);

        i_predict_calculation_stage_1[2] = {1'b0, dsce_clamp_sample(i_predict_calculation_stage_0[2] + i_quantized_residual[0] + i_quantized_residual[1], i_min_reg[2], i_max_reg[2])};
    end : PredictionCalculations


    // -------------------------------------------------------
    //  residual calculations
    // -------------------------------------------------------
    always_comb begin : ResidualCalculations
        i_residual_calculation[0] = dsce_compute_residual(i_predict_pipeline[0], i_group_in[0]);
        i_residual_calculation[1] = dsce_compute_residual(i_predict_calculation_stage_1[1], i_group_in[1]);
        i_residual_calculation[2] = dsce_compute_residual(i_predict_calculation_stage_1[2], i_group_in[2]);
    end : ResidualCalculations


    // -------------------------------------------------------
    //  encoding parameters and data staging
    // -------------------------------------------------------
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : Staging
        if (dsc_reset_n == 1'b0) begin
            i_component_max <= 16'h0000;
            i_first_line <= 1'b1;
            i_first_group <= 1'b0;
            i_last_group <= 1'b0;
            i_qlevel <= kDSC_QLEVEL_ZERO;
            i_pipe_last <= 3'b000;
            i_pipe_slice <= 2'b00;
            i_midrange_sample <= kDSC_COMPONENT_INIT;
            i_right_sample <= kDSC_COMPONENT_INIT;
            i_min_reg <= '{default: 16'h0000};
            i_max_reg <= '{default: 16'hffff};

        end else begin

            // pps parameters
            if (dsc_pps_update == 1'b1) begin
                case (cfg_pps.bits_per_component)
                    4'd0:    begin i_midrange_sample <= 16'h1000;
                                   i_component_max <= 16'hffff;
                             end
                    4'd10:   begin i_midrange_sample <= (pCOMPONENT_SELECT == 0) ? 16'h0200 : 16'h0400;
                                   i_component_max   <= (pCOMPONENT_SELECT == 0) ? 16'h03ff : 16'h07ff;
                             end
                    4'd12:   begin i_midrange_sample <= (pCOMPONENT_SELECT == 0) ? 16'h0800 : 16'h1000;
                                   i_component_max   <= (pCOMPONENT_SELECT == 0) ? 16'h0fff : 16'h1fff;
                             end
                    4'd14:   begin i_midrange_sample <= (pCOMPONENT_SELECT == 0) ? 16'h2000 : 16'h4000;
                                   i_component_max   <= (pCOMPONENT_SELECT == 0) ? 16'h3fff : 16'h7fff;
                             end
                    default: begin i_midrange_sample <= (pCOMPONENT_SELECT == 0) ? 16'h0080 : 16'h0100;
                                   i_component_max   <= (pCOMPONENT_SELECT == 0) ? 16'h00ff : 16'h01ff;
                             end
                endcase
            end // if

            // pipeline the valid flags
            i_pipe_last <= {i_pipe_last[1:0], dsc_group_last_in};
            i_pipe_slice <= {i_pipe_slice[0], dsc_start_of_slice};

            // track the vertical position within the slice
            if (i_pipe_slice[1] == 1'b1) begin
                i_first_line <= 1'b1;
            end else if (i_pipe_last[2] == 1'b1) begin
                i_first_line <= 1'b0;
            end // if

            // flag the last group
            if (dsc_start_of_slice == 1'b1) begin
                i_last_group <= 1'b0;
            end else begin
                if (dsc_group_valid_in == 1'b1 && dsc_group_last_in == 1'b1) begin
                    i_last_group <= 1'b1;
                end else if (i_mmap_state == eMMS_P2_S3) begin
                    i_last_group <= 1'b0;
                end // if
            end // if

            if (dsc_start_of_slice == 1'b1) begin
                i_first_group <= 1'b1;
            end else if (i_mmap_state == eMMS_P2_S3) begin
                i_first_group <= i_pipe_last[2];
            end // if

            // register the sample to the right
            if (dsc_start_of_slice == 1'b1 || (i_last_group == 1'b1 && i_mmap_state == eMMS_P2_S3)) begin
                i_right_sample <= i_midrange_sample;
            end else if (dsc_group_valid_in == 1'b1 && i_first_group == 1'b0) begin
                i_right_sample <= dsc_right_in;
            end // if

            // pipeline the quantization level
            if (dsc_group_valid_in == 1'b1) begin
                i_qlevel <= dsc_qlevel;
            end // if

            // register the min and max values for reuse
            if (i_mmap_state == eMMS_P0_S1) begin
                i_min_reg[2] <= i_min[2];
                i_max_reg[2] <= i_max[2];
                i_min_reg[1] <= i_min[1];
                i_max_reg[1] <= i_max[1];
            end // if
        end // if
    end : Staging


    // -------------------------------------------------------
    //  MMAP processing pipeline
    // -------------------------------------------------------
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : PipeState
        if (dsc_reset_n == 1'b0) begin
            i_mmap_state <= eMMS_PARTIAL_S0;
        end else begin

            if (dsc_start_of_slice == 1'b1) begin
                i_mmap_state <= eMMS_PARTIAL_S0;
            end else begin
                case (i_mmap_state)
                    eMMS_PARTIAL_S0: if (dsc_group_valid_in == 1'b1) i_mmap_state <= eMMS_P0_S1;
                    eMMS_P0_S1:      i_mmap_state <= eMMS_P1_S2;
                    eMMS_P1_S2:      i_mmap_state <= eMMS_P2_S3;
                    eMMS_P2_S3:      i_mmap_state <= eMMS_PARTIAL_S0;
                    default:         i_mmap_state <= eMMS_PARTIAL_S0;
                endcase
            end // if
        end // if
    end : PipeState


    // -------------------------------------------------------
    //  MMAP processing pipeline
    // -------------------------------------------------------
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : Prediction
        if (dsc_reset_n == 1'b0) begin
            dsc_valid_out <= 1'b0;
            dsc_predict_out <= '{default: 16'sd0};
            dsc_residual_out <= '{default: kDSC_RESIDUAL_INIT};

            i_blend <= '{default:16'sd0};
            i_group_in <= '{default: kDSC_COMPONENT_INIT};
            i_predict_pipeline <= '{default: 17'sd0};

        end else begin

            // group input
            if (dsc_group_valid_in == 1'b1) i_group_in <= dsc_group_in;

            // blended pixels
            i_blend[kFILTER_B] <= $signed({1'b0, dsc_line_prev_in[kPREVIOUS_LINE_B]}) + i_diff[kFILTER_B];
            i_blend[kFILTER_C] <= (i_first_group == 1'b0 || i_first_line == 1'b1) ? $signed({1'b0, dsc_line_prev_in[kPREVIOUS_LINE_C]}) + i_diff[kFILTER_C] : {1'b0, i_midrange_sample};
            i_blend[kFILTER_D] <= $signed({1'b0, dsc_line_prev_in[kPREVIOUS_LINE_D]}) + i_diff[kFILTER_D];
            i_blend[kFILTER_E] <= $signed({1'b0, dsc_line_prev_in[kPREVIOUS_LINE_E]}) + i_diff[kFILTER_E];

            // predict pipeline stage
            i_predict_pipeline <= i_predict_calculation_stage_0[1:0];

            // valid output in S0, predict and residual valid in S3 for decision logic
            dsc_valid_out <= (i_mmap_state == eMMS_P2_S3) ? 1'b1 : 1'b0;

            if (i_mmap_state == eMMS_P1_S2) begin
                for (int pox = 0; pox < 3; pox++)  dsc_predict_out[pox] <= i_predict_calculation_stage_1[pox][15:0];
                dsc_residual_out <= i_residual_calculation;
            end // if

        end // if
    end : Prediction

endmodule : dsce_mmap

