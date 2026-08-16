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
//     DESCRIPTION : ICH decision logic.  Accepts the ICH values and the predict values to
//                   determine when ICH mode should be selected.
// ------------------------------------------------------------------------------------------------

// ----------------------------------------------
//  includes
// ----------------------------------------------
import dsce_defs_pkg::*;


// ----------------------------------------------
//  entity declaration
// ----------------------------------------------
module dsce_ich_decision
(
    // clock and control interface
    input  logic                    dsc_clk,                        // DSC processing clock
    input  logic                    dsc_reset_n,                    // DSC domain reset
    input  logic [3:0]              cfg_bits_per_component,         // bpc of the original image
    input  logic                    cfg_convert_rgb,                // color conversion enabled
    input  logic [3:0]              cfg_dsc_version_minor,          // minor revision
    input  logic [2:0]              cfg_slice_alignment,            // slice alignment flags

    // original pixel input path
    input  logic                    dsc_start_of_slice,             // start of slice processing flag
    input  logic                    dsc_group_valid_in,             // valid original data in
    input  logic                    dsc_group_last_in,              // last original data in
    input  tDSC_PIXEL               dsc_group_in [2:0],             // current source group
    input  logic                    dsc_ich_next_is_very_flat,      // next group is very flat
    input  logic [4:0]              dsc_vlc_size_in [2:0],          // vlc adjustment size
    input  tDSC_QLEVEL              dsc_qlevel_y_in,                // qlevel, luma
    input  tDSC_QLEVEL              dsc_qlevel_c_in,                // qlevel, luma
    input  logic                    dsc_force_mpp_in,               // force MPP mode

    // predict and ICH inputs
    input  logic                    dsc_predict_valid_in,           // valid predict data in
    input  tDSC_PIXEL               dsc_predict_group_in [2:0],     // predicted group input
    input  logic [4:0]              dsc_residual_size_in [2:0],     // max size of the residuals
    input  logic [2:0]              dsc_ich_hit,                    // ICH hit for each entry
    input  tDSC_ICH_INDEX           dsc_ich_index_in [2:0],         // ICH candidate index
    input  tDSC_PIXEL               dsc_ich_pixel_in [2:0],         // ICH pixel value

    // ICH candidate selection
    output logic                    dsc_ich_valid_out,              // ICH decision valid
    output logic                    dsc_ich_select_out,             // ICH mode selected
    output tDSC_ICH_INDEX           dsc_ich_index_out [2:0],        // ICH index output
    output tDSC_PIXEL               dsc_ich_group_out [2:0]         // ICH values out
);

    // ------------------------------------------------------------------------------------------------------------
    //                                          internal definitions
    // ------------------------------------------------------------------------------------------------------------

    // initial calculations
    tDSC_PIXEL                      i_prev_group_in [2:0];
    logic                           i_prev_group_last;
    tDSC_PIXEL                      i_predict_coding_error [2:0];
    tDSC_PIXEL                      i_ich_coding_error [2:0];
    logic   [4:0]                   i_predicted_size [2:0];

    // logErrICHMode calculations
    tDSC_PIXEL                      i_shifted_ich_coding_error [2:0];
    logic   [15:0]                  i_max_error_ich_mode [2:0];
    logic   [5:0]                   i_log_err_ich_mode;

    // logErrPMode calculations
    tDSC_PIXEL                      i_shifted_predict_coding_error [2:0];
    logic   [15:0]                  i_max_error_predict_mode [2:0];
    logic   [5:0]                   i_log_err_predict_mode;

    // bitsPMode
    logic   [4:0]                   i_component_bit_depth [1:0];
    tDSC_QLEVEL                     i_qlevel [1:0];
    logic   [4:0]                   i_max_residual_size [1:0];
    logic   [4:0]                   i_adj_predicted_size [2:0];
    logic signed [5:0]              i_qlevel_change [1:0];
    logic   [6:0]                   i_bits_p_component [2:0];
    logic   [6:0]                   i_bits_p_mode;

    // bitsICHMode
    logic   [5:0]                   i_escape_code_size;
    logic   [4:0]                   i_offset_ich_mode;
    logic   [5:0]                   i_bits_ich_mode;

    // cost values
    logic   [8:0]                   i_predict_mode_cost;
    logic   [8:0]                   i_ich_mode_cost;

    // registered values
    tDSC_QLEVEL                     i_prev_qlevel [1:0];
    logic                           i_prev_ich;

    // ICH 选择跨模块连接候选命中位；连续赋值确保端口更新后在同一时隙重新求值。
    assign dsc_ich_select_out = dsc_predict_valid_in && (&dsc_ich_hit) &&
                                ((cfg_dsc_version_minor == 4'd1 || dsc_ich_next_is_very_flat) ?
                                 ((i_log_err_ich_mode <= i_log_err_predict_mode) &&
                                  (i_ich_mode_cost < i_predict_mode_cost)) :
                                 (i_ich_mode_cost < i_predict_mode_cost));

    // ------------------------------------------------------------------------------------------------------------
    //                                            multiply by 3 function
    // ------------------------------------------------------------------------------------------------------------
    function automatic logic [6:0] dsce_size_times_three (
        input logic [4:0] size
    );
        return ({1'b0, size, 1'b0} + {2'b00, size});
    endfunction : dsce_size_times_three


    // ------------------------------------------------------------------------------------------------------------
    //                                             processes
    // ------------------------------------------------------------------------------------------------------------

    // -------------------------------------------------------
    //  calculate the component/pixel differences
    // -------------------------------------------------------
    always_comb begin : ComparisonMath
        for (int px = 0; px < 3; px++) begin : PredictErrorCalculationLoop
            if (i_prev_group_last == 1'b0 || cfg_slice_alignment[px] == 1'b1) begin
                i_predict_coding_error[px] = dsce_abs_diff_pixel(i_prev_group_in[px], dsc_predict_group_in[px]);
            end else begin
                i_predict_coding_error[px] = kDSC_PIXEL_INIT;
            end // if
            i_ich_coding_error[px] = dsce_abs_diff_pixel(i_prev_group_in[px], dsc_ich_pixel_in[px]);
        end : PredictErrorCalculationLoop
    end : ComparisonMath


    // -------------------------------------------------------
    //  ICH mode error calculations
    // -------------------------------------------------------
    always_comb begin : ErrICHMode
        for (int sx = 0; sx < 3; sx++) begin : SelectedErrorLoop
            case (cfg_bits_per_component)
                4'd10:      i_shifted_ich_coding_error[sx] = dsce_shift_pixel(i_ich_coding_error[sx], 4'd2);
                4'd12:      i_shifted_ich_coding_error[sx] = dsce_shift_pixel(i_ich_coding_error[sx], 4'd4);
                4'd14:      i_shifted_ich_coding_error[sx] = dsce_shift_pixel(i_ich_coding_error[sx], 4'd6);
                4'd0:       i_shifted_ich_coding_error[sx] = dsce_shift_pixel(i_ich_coding_error[sx], 4'd8);
                default:    i_shifted_ich_coding_error[sx] = dsce_shift_pixel(i_ich_coding_error[sx], 4'd0);
            endcase
        end : SelectedErrorLoop

        i_max_error_ich_mode[0] = dsce_max_3(i_shifted_ich_coding_error[0].y,  i_shifted_ich_coding_error[1].y,  i_shifted_ich_coding_error[2].y);
        i_max_error_ich_mode[1] = dsce_max_3(i_shifted_ich_coding_error[0].co, i_shifted_ich_coding_error[1].co, i_shifted_ich_coding_error[2].co);
        i_max_error_ich_mode[2] = dsce_max_3(i_shifted_ich_coding_error[0].cg, i_shifted_ich_coding_error[1].cg, i_shifted_ich_coding_error[2].cg);

        // section 6.5.3.2 final calculation
        if (cfg_dsc_version_minor == 4'd1) begin
            i_log_err_ich_mode = {1'b0, dsce_ceil_log2(i_max_error_ich_mode[0]), 1'b0} + {2'b00, dsce_ceil_log2(i_max_error_ich_mode[1])} + {2'b00, dsce_ceil_log2(i_max_error_ich_mode[2])};
        end else begin
            i_log_err_ich_mode = {2'b00, dsce_ceil_log2(i_max_error_ich_mode[0])} + {2'b00, dsce_ceil_log2(i_max_error_ich_mode[1])} + {2'b00, dsce_ceil_log2(i_max_error_ich_mode[2])};
        end // if
    end : ErrICHMode


    // -------------------------------------------------------
    //  Predict mode error calculations
    // -------------------------------------------------------
    always_comb begin : ErrPredictMode
        for (int sx = 0; sx < 3; sx++) begin : SelectedErrorLoop
            case (cfg_bits_per_component)
                4'd10:      i_shifted_predict_coding_error[sx] = dsce_shift_pixel(i_predict_coding_error[sx], 4'd2);
                4'd12:      i_shifted_predict_coding_error[sx] = dsce_shift_pixel(i_predict_coding_error[sx], 4'd4);
                4'd14:      i_shifted_predict_coding_error[sx] = dsce_shift_pixel(i_predict_coding_error[sx], 4'd6);
                4'd0:       i_shifted_predict_coding_error[sx] = dsce_shift_pixel(i_predict_coding_error[sx], 4'd8);
                default:    i_shifted_predict_coding_error[sx] = dsce_shift_pixel(i_predict_coding_error[sx], 4'd0);
            endcase
        end : SelectedErrorLoop

        i_max_error_predict_mode[0] = dsce_max_3(i_shifted_predict_coding_error[0].y,  i_shifted_predict_coding_error[1].y,  i_shifted_predict_coding_error[2].y);
        i_max_error_predict_mode[1] = dsce_max_3(i_shifted_predict_coding_error[0].co, i_shifted_predict_coding_error[1].co, i_shifted_predict_coding_error[2].co);
        i_max_error_predict_mode[2] = dsce_max_3(i_shifted_predict_coding_error[0].cg, i_shifted_predict_coding_error[1].cg, i_shifted_predict_coding_error[2].cg);

        // section 6.5.3.2 final calculation
        if (cfg_dsc_version_minor == 4'd1) begin
            i_log_err_predict_mode = {1'b0, dsce_ceil_log2(i_max_error_predict_mode[0]), 1'b0} + dsce_ceil_log2(i_max_error_predict_mode[1]) + {2'b00, dsce_ceil_log2(i_max_error_predict_mode[2])};
        end else begin
            i_log_err_predict_mode = {2'b00, dsce_ceil_log2(i_max_error_predict_mode[0])} + {2'b00, dsce_ceil_log2(i_max_error_predict_mode[1])} + {2'b00, dsce_ceil_log2(i_max_error_predict_mode[2])};
        end // if
    end : ErrPredictMode


    // -------------------------------------------------------
    //  Number of bits determination
    // -------------------------------------------------------
    always_comb begin : CodedBitCount
        i_component_bit_depth[0] = {1'b0, cfg_bits_per_component};
        i_component_bit_depth[1] = {1'b0, cfg_bits_per_component} + cfg_convert_rgb;

        // Y or C values
        for (int ux = 0; ux < 2; ux++) begin : UnitLoop
            i_qlevel_change[ux] = {1'b0, i_prev_qlevel[ux]} - {1'b0, i_qlevel[ux]};
            i_max_residual_size[ux] = i_component_bit_depth[ux] - i_qlevel[ux];
        end : UnitLoop

        // component values
        i_adj_predicted_size[0] = dsce_clamp_size($signed({1'b0, i_predicted_size[0]}) + i_qlevel_change[0], i_max_residual_size[0]-5'd1);
        i_adj_predicted_size[1] = dsce_clamp_size($signed({1'b0, i_predicted_size[1]}) + i_qlevel_change[1], i_max_residual_size[1]-5'd1);
        i_adj_predicted_size[2] = dsce_clamp_size($signed({1'b0, i_predicted_size[2]}) + i_qlevel_change[1], i_max_residual_size[1]-5'd1);

        // bitsPMode calculation
        if (dsc_residual_size_in[0] < i_adj_predicted_size[0]) begin
            i_bits_p_component[0] = 7'd1 + dsce_size_times_three(i_adj_predicted_size[0]);
        end else if (dsc_residual_size_in[0] < i_max_residual_size[0] && i_prev_ich == 1'b1) begin
            i_bits_p_component[0] = 7'd2 + dsc_residual_size_in[0] - i_adj_predicted_size[0] + dsce_size_times_three(dsc_residual_size_in[0]);
        end else begin
            i_bits_p_component[0] = 7'd1 + dsc_residual_size_in[0] - i_adj_predicted_size[0] + dsce_size_times_three(dsc_residual_size_in[0]);
        end // if

        if (dsc_residual_size_in[1] < i_adj_predicted_size[1]) begin
            i_bits_p_component[1] = 7'd1 + dsce_size_times_three(i_adj_predicted_size[1]);
        end else if (dsc_residual_size_in[1] == i_max_residual_size[1]) begin
            i_bits_p_component[1] = dsc_residual_size_in[1] - i_adj_predicted_size[1] + dsce_size_times_three(dsc_residual_size_in[1]);
        end else begin
            i_bits_p_component[1] = 7'd1 + dsc_residual_size_in[1] - i_adj_predicted_size[1] + dsce_size_times_three(dsc_residual_size_in[1]);
        end // if

        if (dsc_residual_size_in[2] < i_adj_predicted_size[2]) begin
            i_bits_p_component[2] = 7'd1 + dsce_size_times_three(i_adj_predicted_size[2]);
        end else if (dsc_residual_size_in[2] == i_max_residual_size[1]) begin
            i_bits_p_component[2] = dsc_residual_size_in[2] - i_adj_predicted_size[2] + dsce_size_times_three(dsc_residual_size_in[2]);
        end else begin
            i_bits_p_component[2] = 7'd1 + dsc_residual_size_in[2] - i_adj_predicted_size[2] + dsce_size_times_three(dsc_residual_size_in[2]);
        end // if

        i_bits_p_mode = (i_bits_p_component[0] + i_bits_p_component[1]) + (i_bits_p_component[2]);

        // bitsICHMode calculation, previous ICH or escape code
        i_escape_code_size = {1'b0, i_component_bit_depth[kBPC_Y]} + 5'd1 - {1'b0, i_qlevel[0]};

        if (i_prev_ich == 1'b1) begin
            i_offset_ich_mode = 5'd1;
        end else begin
            i_offset_ich_mode = i_escape_code_size - i_adj_predicted_size[0];
        end // if

        i_bits_ich_mode = 6'd15 + i_offset_ich_mode;
    end : CodedBitCount


    // -------------------------------------------------------
    //  Final selection for ICH mode
    // -------------------------------------------------------
    always_comb begin : ICHSelection
        i_predict_mode_cost = {2'b00, i_bits_p_mode} + {i_log_err_predict_mode, 2'b00};
        i_ich_mode_cost = {3'b000, i_bits_ich_mode} + {1'b0, i_log_err_ich_mode, 2'b00};

        dsc_ich_valid_out = dsc_predict_valid_in;
        dsc_ich_index_out = dsc_ich_index_in;
        dsc_ich_group_out = dsc_ich_pixel_in;
    end : ICHSelection


    // -------------------------------------------------------
    //  pipeline register timing
    // -------------------------------------------------------
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : PipelineRegisters
        if (dsc_reset_n == 1'b0) begin
            i_prev_group_in <= '{default: kDSC_PIXEL_INIT};
            i_qlevel <= '{default: kDSC_QLEVEL_ZERO};
            i_prev_qlevel <= '{default: kDSC_QLEVEL_ZERO};
            i_prev_ich <= 1'b0;
            i_prev_group_last <= 1'b0;
            i_predicted_size <= '{default: 5'd0};

        end else begin


            // ----- S0 ----- //
            if (dsc_start_of_slice == 1'b1) begin
                i_qlevel <= '{default: kDSC_QLEVEL_ZERO};
                i_prev_qlevel <= '{default: kDSC_QLEVEL_ZERO};
                i_prev_ich <= 1'b0;
                i_prev_group_last <= 1'b0;
                i_prev_group_in <= '{default: kDSC_PIXEL_INIT};
            end else if (dsc_group_valid_in == 1'b1) begin
                i_qlevel <= '{dsc_qlevel_c_in, dsc_qlevel_y_in};
                i_prev_qlevel <= i_qlevel;
                i_prev_ich <= dsc_ich_select_out & ~dsc_force_mpp_in;
                i_prev_group_last <= dsc_group_last_in;
                i_prev_group_in <= dsc_group_in;
            end // if

            // ----- S0 results ----- //
            if (dsc_ich_valid_out == 1'b1 && (dsc_ich_select_out == 1'b0 || dsc_force_mpp_in == 1'b1)) begin
                i_predicted_size <= dsc_vlc_size_in;
            end // if

        end // if
    end : PipelineRegisters

endmodule : dsce_ich_decision
