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
//     DESCRIPTION : DSU-VLC block for the DSC encoder.  This block produces the target bits for
//                   the input residual and the number of bits used to code the block.
// ------------------------------------------------------------------------------------------------

// ----------------------------------------------
//  includes
// ----------------------------------------------
import dsce_defs_pkg::*;

// ----------------------------------------------
//  entity declaration
// ----------------------------------------------
module dsce_vlc
#(
    parameter int pCOLOR_SELECT = 0                                 // select the color plane (for prefix bits)
)
(
    // clock and control interface
    input  logic                    dsc_clk,                        // DSC processing clock
    input  logic                    dsc_reset_n,                    // DSC domain reset
    input  logic                    dsc_pps_update,                 // update pps parameters flag
    input  tDSC_PPS                 cfg_pps,                        // parameter set output array

    // input data group
    input  logic                    dsc_start_of_slice,             // beginning of a slice marker
    input  logic                    dsc_predict_valid_in,           // valid data in
    input  logic                    dsc_predict_last_in,            // last flag input
    input  tDSC_RESIDUAL            dsc_residual_in [2:0],          // current group residuals
    input  logic [4:0]              dsc_residual_size_in,           // residual size
    input  logic [4:0]              dsc_vlc_size_in,                // adjustment size input
    input  tDSC_QLEVEL              dsc_primary_qp_in,              // primary QP value
    input  tDSC_QLEVEL              dsc_qlevel_y_in,                // quant level, y
    input  tDSC_QLEVEL              dsc_qlevel_c_in,                // quant level, co/cg
    input  logic                    dsc_ich_selected_in,            // ICH mode selected
    input  tDSC_ICH_INDEX           dsc_ich_index_in,               // ICH mode index
    input  tDSC_FLAT_FLAGS          dsc_flatness_in,                // group flatness indicator

    // RC outputs
    output logic                    dsc_unit_size_valid,            // coded unit size and rc unit size valid
    output logic [5:0]              dsc_coded_unit_size,            // actual coded size for the unit
    output logic [5:0]              dsc_rc_size_unit,               // group size for rate control

    // vlc coded data out
    output logic                    dsc_vlc_valid_out,              // valid vlc bits out
    output logic                    dsc_vlc_last_out,               // last output flag
    output logic [4:0]              dsc_vlc_size_out,               // stream size output
    output logic [15:0]             dsc_vlc_data_out                // stream data output
);

    // ------------------------------------------------------------------------------------------------------------
    //                                          internal definitions
    // ------------------------------------------------------------------------------------------------------------

    // values selected based on the color plane
    logic [4:0]                     i_component_bit_depth;
    tDSC_QLEVEL                     i_qlevel_in;
    tDSC_QLEVEL                     i_flatness_max_qp, i_flatness_min_qp;
    logic [4:0]                     i_max_residual_size;
    logic [4:0]                     i_coded_residual_size;

    // pipelined inputs
    logic                           i_ich_selected_in;
    tDSC_RESIDUAL                   i_residual_in [2:0];
    logic [4:0]                     i_residual_size_in;
    tDSC_ICH_INDEX                  i_ich_index_in;

    // calculate the adjusted prediction size
    logic [4:0]                     i_predicted_size;
    logic [4:0]                     i_adj_predicted_size;
    logic signed [5:0]              i_qlevel_change;
    tDSC_QLEVEL                     i_prev_qlevel;
    logic                           i_prev_ich;

    // ich sizes
    logic [4:0]                     i_ich_prefix_code_size;

    // flatness codes
    logic                           i_next_flatness_check;
    logic                           i_next_flatness_flag;
    logic [4:0]                     i_flatness_size;
    logic                           i_first_group_in_slice_line;
    logic [1:0]                     i_group_index;

    // prefix signals
    logic signed [5:0]              i_residual_size_diff;
    logic signed [5:0]              i_max_residual_size_diff;
    logic [4:0]                     i_one_bits;
    logic [4:0]                     i_prefix_size;
    logic [15:0]                    i_prefix_data;
    logic [15:0]                    i_next_flatness_bit;
    logic [4:0]                     i_s0_size;
    logic [15:0]                    i_s0_data;

    // output management
    logic [3:1]                     i_pipe_valid;
    logic [3:1]                     i_pipe_last;
    logic [3:0]                     i_pipeline_state;


    // ------------------------------------------------------------------------------------------------------------
    //                                             processes
    // ------------------------------------------------------------------------------------------------------------

    // signal assignments
    always_comb begin : SignalMap
        // select inputs based on the color plane
        case (pCOLOR_SELECT)
            1:        i_qlevel_in = dsc_qlevel_c_in;
            2:        i_qlevel_in = dsc_qlevel_c_in;
            default:  i_qlevel_in = dsc_qlevel_y_in;
        endcase

        // pipeline state mapping
        i_pipeline_state = {i_pipe_valid, dsc_predict_valid_in};

        // change in the quantization level
        i_max_residual_size = i_component_bit_depth - i_qlevel_in;
        i_qlevel_change = {1'b0, i_prev_qlevel} - {1'b0, i_qlevel_in};

        // adjusted prediction size for the current group
        i_adj_predicted_size = dsce_clamp_size($signed({1'b0, i_predicted_size}) + i_qlevel_change, i_max_residual_size-5'd1);

        // size of the difference
        i_residual_size_diff = {1'b0, dsc_residual_size_in} - {1'b0, i_adj_predicted_size};
        i_max_residual_size_diff = {1'b0, i_max_residual_size} - {1'b0, i_adj_predicted_size} + 6'd1;

        // prefix determination
        case ({i_prev_ich, dsc_ich_selected_in})
            2'b00:  begin
                i_one_bits = ((dsc_residual_size_in < i_max_residual_size) || (pCOLOR_SELECT == 0)) ? 5'd1 : 5'd0;
                i_prefix_size = (i_residual_size_diff[5] == 1'b1 || i_residual_size_diff[4:0] == 5'd0) ? 5'd1 : i_residual_size_diff[4:0] + i_one_bits;
            end // P-P

            2'b01:  begin
                i_one_bits = 5'd0;
                if (pCOLOR_SELECT == 0) begin
                    i_prefix_size = (i_max_residual_size_diff[5] == 1'b1) ? 5'd1 : i_max_residual_size_diff[4:0];
                end else begin
                    i_prefix_size = 5'd0;
                end // if;
            end // P-I

            2'b10:  begin
                i_one_bits = (dsc_residual_size_in < i_max_residual_size) ? 5'd1 : 5'd0;

                if (pCOLOR_SELECT == 0) begin
                    i_prefix_size = (i_residual_size_diff[5] == 1'b1) ? (5'd1 + i_one_bits) : (i_residual_size_diff[4:0] + i_one_bits + 5'd1);
                end else begin
                    i_prefix_size = (i_residual_size_diff[5] == 1'b1) ? i_one_bits : (i_residual_size_diff[4:0] + i_one_bits);
                end // if
            end // I-P

            2'b11:  begin
                i_one_bits = (pCOLOR_SELECT == 0) ? 5'd1 : 5'd0;
                i_prefix_size = (pCOLOR_SELECT == 0) ? 5'd1 : 5'd0;
            end // I-I

            default:  begin
                i_one_bits = 5'd0;
                i_prefix_size = 5'd1;
            end // default
        endcase

        i_prefix_data = (i_one_bits == 5'd0) ? 16'h0000 : 16'h0001;
        i_ich_prefix_code_size = (i_prev_ich == 1'b1) ? 5'd1 : (i_component_bit_depth + 5'd1) - (dsc_qlevel_y_in + i_adj_predicted_size);

        // size calculations
        i_coded_residual_size = (i_residual_size_diff[5] == 1'b1) ? i_adj_predicted_size : dsc_residual_size_in[4:0];

        // flatness logic
        i_next_flatness_check = (pCOLOR_SELECT == 0 && (dsc_primary_qp_in >= i_flatness_min_qp && dsc_primary_qp_in <= i_flatness_max_qp)) ? 1'b1 : 1'b0;
        i_next_flatness_bit = {15'd0, dsc_flatness_in.next_flatness_flag} << i_prefix_size;
        i_flatness_size = 5'd0;
        if (i_group_index == 2'd3) begin
            i_flatness_size = {4'b0000, i_next_flatness_check};
        end else if (i_group_index == 2'd0 && pCOLOR_SELECT == 0 && dsc_flatness_in.send_flatness) begin
            // group 0 会发送上一 supergroup 的 flatness 语法；码控长度必须与
            // 下方 i_s0_size 实际写入 bitstream 的 2/3 bit 保持一致。
            i_flatness_size =
                (dsc_primary_qp_in >= dsce_get_somewhat_flat_threshold(cfg_pps.bits_per_component)) ?
                5'd3 : 5'd2;
        end

        // PipeS0 只发送 prefix。ICH index 保持为独立片段，和官方模型的
        // syntax 边界一致，避免跨 muxword 边界时依赖片段合并等价性。
        i_s0_size = i_prefix_size;
        i_s0_data = i_prefix_data;
        case (i_group_index)
            2'd3: begin
                i_s0_size = i_prefix_size + {4'd0, i_next_flatness_check};
                i_s0_data = i_prefix_data | i_next_flatness_bit;
            end
            2'd0: begin
                if (pCOLOR_SELECT == 0 && dsc_flatness_in.send_flatness) begin
                    if (dsc_primary_qp_in >= dsce_get_somewhat_flat_threshold(cfg_pps.bits_per_component)) begin
                        i_s0_size = i_prefix_size + 5'd3;
                        i_s0_data = ({13'd0, dsc_flatness_in.flatness_type,
                                     dsc_flatness_in.first_flat} << i_prefix_size) |
                                    i_prefix_data;
                    end else begin
                        i_s0_size = i_prefix_size + 5'd2;
                        i_s0_data = ({14'd0, dsc_flatness_in.first_flat} << i_prefix_size) |
                                    i_prefix_data;
                    end
                end
            end
            default: begin end
        endcase
    end : SignalMap


    // -------------------------------------------------------
    //  rate control output
    // -------------------------------------------------------
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : RateControlValues
        if (dsc_reset_n == 1'b0) begin
            dsc_unit_size_valid <= 1'b0;
            dsc_coded_unit_size <= 6'd0;
            dsc_rc_size_unit <= 6'd0;

        end else begin

            // keep stable from s1 to s1
            if (i_pipeline_state[0] == 1'b1) begin
                dsc_unit_size_valid <= 1'b1;
                if (dsc_ich_selected_in == 1'b0) begin
                    dsc_coded_unit_size <= (i_flatness_size + i_prefix_size) + ({i_coded_residual_size, 1'b0} + i_coded_residual_size);
                    dsc_rc_size_unit <= 5'd1 + {dsc_residual_size_in, 1'b0} + dsc_residual_size_in;
                end else begin
                    if (pCOLOR_SELECT == 0) begin
                        dsc_coded_unit_size <= i_flatness_size + {1'b0, i_ich_prefix_code_size} + 6'd5;
                        dsc_rc_size_unit <= 6'd6;
                    end else begin
                        dsc_coded_unit_size <= 6'd5;
                        dsc_rc_size_unit <= 6'd5;
                    end // if
                end // if
            end else begin
                dsc_unit_size_valid <= 1'b0;
            end // if
        end // if
    end : RateControlValues


    // -------------------------------------------------------
    //  Group / supergroup tracking
    // -------------------------------------------------------
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : GroupTracking
        if (dsc_reset_n == 1'b0) begin
            i_group_index <= 2'd0;
            i_first_group_in_slice_line <= 1'b0;

            i_ich_selected_in <= 1'b0;
            i_ich_index_in <= kDSC_ICH_INDEX_INIT;
            i_residual_size_in <= 5'd0;
            i_residual_in <= '{default: kDSC_RESIDUAL_INIT};

        end else begin

            // ----- index tracking for flatness insertion ----- //
            if (dsc_start_of_slice == 1'b1) begin
                i_group_index <= 2'd0;
            end else if (i_pipeline_state[3] == 1'b1) begin
                i_group_index <= i_group_index + 2'd1;
            end // if

            // ----- flatness never inserted for the first group in a slice line ----- //
            if (dsc_start_of_slice == 1'b1) begin
                i_first_group_in_slice_line <= 1'b1;
            end else if (i_pipeline_state[0] == 1'b1) begin
                i_first_group_in_slice_line <= (i_pipe_last[2] == 1'b1) ? 1'b1 : 1'b0;
            end // if

            // ----- register values to remain unchanged during the group time ----- //
            if (i_pipeline_state[0] == 1'b1) begin
                i_ich_index_in <= dsc_ich_index_in;
                i_residual_in <= dsc_residual_in;
                i_residual_size_in <= i_coded_residual_size;
                i_ich_selected_in <= dsc_ich_selected_in;
            end // if

        end // if
    end : GroupTracking


    // -------------------------------------------------------
    //  VLC coding
    // -------------------------------------------------------
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : VLC
        if (dsc_reset_n == 1'b0) begin
            dsc_vlc_valid_out <= 1'b0;
            dsc_vlc_size_out <= 5'd0;
            dsc_vlc_data_out <= 16'h0000;
            dsc_vlc_last_out <= 1'b0;

            i_component_bit_depth <= 5'd0;
            i_next_flatness_flag <= 1'b0;
            i_flatness_min_qp <= kDSC_QLEVEL_ZERO;
            i_flatness_max_qp <= kDSC_QLEVEL_ZERO;
            i_pipe_valid[3:1] <= 3'b000;
            i_pipe_last[3:1] <= 3'b000;
            i_predicted_size <= 5'd0;
            i_prev_qlevel <= kDSC_QLEVEL_ZERO;
            i_prev_ich <= 1'b0;

        end else begin

            // local signal retiming
            if (dsc_pps_update == 1'b1) begin
                if (pCOLOR_SELECT == 0) begin
                    i_component_bit_depth <= {1'b0, cfg_pps.bits_per_component};
                    i_flatness_min_qp <= cfg_pps.flatness_min_qp;
                    i_flatness_max_qp <= cfg_pps.flatness_max_qp;
                end else begin
                    i_component_bit_depth <= {1'b0, cfg_pps.bits_per_component} + cfg_pps.convert_rgb;
                    i_flatness_min_qp <= kDSC_QLEVEL_ZERO;
                    i_flatness_max_qp <= kDSC_QLEVEL_ZERO;
                end // if
            end // if

            // pipeline staging
            i_pipe_valid[3:1] <= {i_pipe_valid[2:1], dsc_predict_valid_in};
            i_pipe_last[3:1] <= {i_pipe_last[2:1], dsc_predict_last_in};

            // quantization level tracking
            if (dsc_start_of_slice == 1'b1) begin
                i_prev_qlevel <= kDSC_QLEVEL_ZERO;
                i_prev_ich <= 1'b0;
            end else if (i_pipeline_state[0] == 1'b1) begin
                i_prev_qlevel <= i_qlevel_in;
                i_prev_ich <= dsc_ich_selected_in;
            end // if

            // adjusted predicted size
            if (dsc_start_of_slice == 1'b1) begin
                i_predicted_size <= 5'd0;
            end else if (i_pipeline_state[0] == 1'b1 && dsc_ich_selected_in == 1'b0) begin
                i_predicted_size <= dsc_vlc_size_in;
            end // if

            // pipeline staging, multiple enables
            dsc_vlc_last_out <= 1'b0;
            dsc_vlc_valid_out <= 1'b0;

            // flatness is inserted in state 8 to preserve bit stream order (prior to luma)
            casez (i_pipeline_state)
                // flatness + prefix
                4'b???1:  begin  :  PipeS0
                    dsc_vlc_valid_out <= 1'b1;
                    i_next_flatness_flag <= i_next_flatness_check;
                    dsc_vlc_size_out <= i_s0_size;
                    dsc_vlc_data_out <= i_s0_data;
                    if (i_s0_size == 5'd0)
                        dsc_vlc_valid_out <= 1'b0;
                end : PipeS0

                // residual 0 / ICH index
                4'b0010:  begin  :  PipeS1
                    dsc_vlc_valid_out <= 1'b1;

                    if (i_ich_selected_in == 1'b1) begin
                        dsc_vlc_size_out <= 5'd5;
                        dsc_vlc_data_out <= {11'd0, i_ich_index_in};
                        dsc_vlc_last_out <= i_pipe_last[1];
                    end else begin
                        dsc_vlc_size_out <= i_residual_size_in;
                        dsc_vlc_data_out <= i_residual_in[0][15:0];
                    end // if
                end : PipeS1

                // residual 1
                4'b0100:  begin  :  PipeS2
                    if (i_ich_selected_in == 1'b1) begin
                        dsc_vlc_valid_out <= 1'b0;
                    end else begin
                        dsc_vlc_valid_out <= 1'b1;
                        dsc_vlc_size_out <= i_residual_size_in;
                        dsc_vlc_data_out <= i_residual_in[1][15:0];
                    end // if
                end : PipeS2

                // residual 2
                // PipeS3 在 valid 后 3 拍求值，此时 dsc_ich_selected_in（组合、仅 valid 拍有效）
                // 已随真实 ICH 的时序回落为 0，必须与 PipeS1/S2 一致使用寄存的 i_ich_selected_in，
                // 否则 ICH 组的第三个残差不会被抑制，产生多余的片段。
                4'b1000:  begin  :  PipeS3
                    if (i_ich_selected_in == 1'b1) begin
                        dsc_vlc_valid_out <= 1'b0;
                    end else begin
                        dsc_vlc_valid_out <= 1'b1;
                        dsc_vlc_last_out <= i_pipe_last[3];
                        dsc_vlc_size_out <= i_residual_size_in;
                        dsc_vlc_data_out <= i_residual_in[2][15:0];
                    end // if
                end : PipeS3

                default:  begin
                    dsc_vlc_valid_out <= 1'b0;
                    dsc_vlc_last_out <= 1'b0;
                    dsc_vlc_size_out <= 5'd0;
                    dsc_vlc_data_out <= 16'h0000;
                end // default
            endcase

        end // if
    end : VLC

endmodule : dsce_vlc
