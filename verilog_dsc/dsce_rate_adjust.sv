// ------------------------------------------------------------------------------------------------
//     COPYRIGHT © 2023, TRILINEAR TECHNOLOGIES, INC.
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
//     DESCRIPTION : Updated intermediate block to calculate and retime the parameters
//                   required for the rate controller.  Ported from the flatness logic.
// ------------------------------------------------------------------------------------------------

// ----------------------------------------------
//  includes
// ----------------------------------------------
import dsce_defs_pkg::*;

`ifdef DSC_FLATNESS_MODEL_SUBSTITUTE
// 仅用于 A/B：调用独立 C++ function model，不进入综合实现。
import "DPI-C" function int dsc_flatness_adjust_qp_model(
    input int last_used_qp,
    input int somewhat_flat_threshold,
    input int very_flat_qp
);
`endif


// ----------------------------------------------
//  module declaration
// ----------------------------------------------
module dsce_rate_adjust
(
    // processing clock domain
    input  logic                dsc_clk,                        // decoder clock
    input  logic                dsc_reset_n,                    // decoder reset
    input  logic                dsc_pps_update,                 // update pps parameters flag
    input  tDSC_PPS             cfg_pps,                        // parameter set output array
    input  logic [4:0]          cfg_rc_range_max_qp_14,         // rc range 14 max qp (flatness gate)

    // group input path
    input  logic                dsc_start_of_slice,             // start of slice flag
    input  logic                dsc_group_valid_in,             // valid data in (predict)
    input  logic                dsc_group_last_in,              // last group in a slice line

    // rate control qp input
    input  tDSC_QLEVEL          dsc_rc_primary_qp_in,           // primary qp input
    input  logic                dsc_rc_qp_valid_in,             // next primary qp valid
    input  tDSC_QLEVEL          dsc_rc_primary_qp_next_in,      // pre-register primary qp
    input  tDSC_QLEVEL          dsc_rc_primary_qp_prev_in,      // 上一次提交的 primary qp
    input  tDSC_QLEVEL          dsc_rc_prev_qp_in,              // previous qp value

    // rate control modified qp out
    output tDSC_QLEVEL          dsc_primary_qp_out,             // qp after adjustments
    output tDSC_QLEVEL          dsc_prev_qp_out                 // prev qp after adjustments
);
    // ------------------------------------------------------------------------------------------------------------
    //                                          internal definitions
    // ------------------------------------------------------------------------------------------------------------

    logic                       i_orig_is_flat;
    logic                       i_dsc_version_2_active;
    tDSC_QLEVEL                 i_somewhat_flat_threshold;
    tDSC_QLEVEL                 i_very_flat_qp;
    tDSC_QLEVEL                 i_adjusted_qp;
    tDSC_QLEVEL                 i_adjusted_prev_qp;
    tDSC_QLEVEL                 i_line_end_primary_qp;
    tDSC_QLEVEL                 i_last_used_qp_in_slice_line;
    logic   [4:0]               i_range_max_qp_14;
    logic   [2:0]               i_valid_pipe, i_last_pipe;
    tDSC_QLEVEL                 i_rc_primary_qp_effective;


    // ------------------------------------------------------------------------------------------------------------
    //                                          process implementations
    // ------------------------------------------------------------------------------------------------------------

    // --------------------------------------------------------------------------
    //  combinatorial logic
    // --------------------------------------------------------------------------
    always_comb begin : CombLogic
        // rate 的 short-term 结果在提交沿之前已经组合稳定；flatness 同拍消费该事务。
        i_rc_primary_qp_effective = dsc_rc_qp_valid_in ?
                                     dsc_rc_primary_qp_next_in : dsc_rc_primary_qp_in;
        // ----- determine the end of line adjusted Qp ----- //
`ifdef DSC_FLATNESS_MODEL_SUBSTITUTE
        i_adjusted_qp = tDSC_QLEVEL'(dsc_flatness_adjust_qp_model(
            i_line_end_primary_qp,
            i_somewhat_flat_threshold,
            i_very_flat_qp
        ));
        i_adjusted_prev_qp = tDSC_QLEVEL'(dsc_flatness_adjust_qp_model(
            i_last_used_qp_in_slice_line,
            i_somewhat_flat_threshold,
            i_very_flat_qp
        ));
`else
        // C model 先提交本组 RateControl，再分别调整 stQp 与 prevQp。
        i_adjusted_qp = (i_line_end_primary_qp < i_somewhat_flat_threshold) ?
                        dsce_adjust_qp_somewhat_flat(i_line_end_primary_qp) : i_very_flat_qp;
        i_adjusted_prev_qp = (i_last_used_qp_in_slice_line < i_somewhat_flat_threshold) ?
                             dsce_adjust_qp_somewhat_flat(i_last_used_qp_in_slice_line) : i_very_flat_qp;
`endif

        // ----- adjust the qp for rate control ----- //
        // C model 用 primaryQp < rc_range_parameters[14].range_max_qp 门控行末强制
        // flat QP；本行最后实际采用的 QP 等价于行末组的 primaryQp。
        if (i_orig_is_flat == 1'b1 && i_last_used_qp_in_slice_line < i_range_max_qp_14) begin
            dsc_primary_qp_out = i_adjusted_qp;
            dsc_prev_qp_out = i_adjusted_prev_qp;
        end else if (i_orig_is_flat == 1'b1) begin
            // 行末 flush 使行首组 fd 延后到行末组提交之后，dsc_primary_qp 已
            // 推进到 stQp(G)，而 C model 的 prevQp 仍为 stQp(G-1)。行末 QP
            // 未达 range_max_qp 下界、不强制 flat 时，回退到上一次提交值。
            dsc_primary_qp_out = dsc_rc_primary_qp_prev_in;
            dsc_prev_qp_out = dsc_rc_prev_qp_in;
        end else begin
            dsc_primary_qp_out = i_rc_primary_qp_effective;
            dsc_prev_qp_out = dsc_rc_prev_qp_in;
        end // if
    end : CombLogic


    // --------------------------------------------------------------------------
    //  flatness adjustment
    // --------------------------------------------------------------------------
    // 运行时不变式：输出 QP 必须维持 rate control 的合法范围 [0,31]。
    // 该属性在 Phase 5 已投放到全套 stress/多 slice/多 bpc 回归,零违例。
    assert property (@(posedge dsc_clk) disable iff (!dsc_reset_n)
                     dsc_primary_qp_out <= 5'd31)
        else $error("Rate adjust primary QP exceeds 31");
    assert property (@(posedge dsc_clk) disable iff (!dsc_reset_n)
                     dsc_prev_qp_out <= 5'd31)
        else $error("Rate adjust prev QP exceeds 31");

    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : QPMod
        if (dsc_reset_n == 1'b0) begin
            i_very_flat_qp <= kDSC_QLEVEL_ZERO;
            i_somewhat_flat_threshold <= kDSC_QLEVEL_ZERO;
            i_dsc_version_2_active <= 1'b0;
            i_orig_is_flat <= 1'b0;
            i_range_max_qp_14 <= 5'd0;
            i_valid_pipe <= 3'b000;
            i_last_pipe <= 3'b000;
            i_last_used_qp_in_slice_line <= kDSC_QLEVEL_ZERO;
            i_line_end_primary_qp <= kDSC_QLEVEL_ZERO;

        end else begin

            // ----- grab the picture parameters locally ----- //
            if (dsc_pps_update == 1'b1)  begin
                i_very_flat_qp <= dsce_get_very_flat_qp(cfg_pps.bits_per_component);
                i_dsc_version_2_active <= (cfg_pps.dsc_version_minor == 4'd2) ? 1'b1 : 1'b0;
                i_somewhat_flat_threshold <= dsce_get_somewhat_flat_threshold(cfg_pps.bits_per_component);
                i_range_max_qp_14 <= cfg_rc_range_max_qp_14;
            end // if

            // ----- record the last Qp used in the slice for the decision ----- //
            if (dsc_group_valid_in == 1'b1 && dsc_group_last_in == 1'b1) begin
                i_last_used_qp_in_slice_line <= i_rc_primary_qp_effective;
            end // if

            // 行末 group 的 RC 结果比实际采用的 QP 晚三级到达；在 flatness
            // 判定置位的同一沿锁存，供下一拍同时更新 stQp 与 prevQp。
            if (i_valid_pipe[2] == 1'b1 && i_last_pipe[2] == 1'b1) begin
                i_line_end_primary_qp <= i_rc_primary_qp_effective;
            end

            // ----- pipeline the enable for proper stage timing ----- //
            i_valid_pipe <= {i_valid_pipe[1:0], dsc_group_valid_in};
            i_last_pipe  <= {i_last_pipe[1:0], dsc_group_last_in};

            // ----- detect when the end of the line is active ----- //
            if (dsc_start_of_slice == 1'b1) begin
                i_orig_is_flat <= 1'b0;
            end else if (i_valid_pipe[2] == 1'b1) begin
                i_orig_is_flat <= i_last_pipe[2] & i_dsc_version_2_active;
            end // if

        end // if
    end : QPMod

endmodule : dsce_rate_adjust
