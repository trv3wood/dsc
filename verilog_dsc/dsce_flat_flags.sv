// ------------------------------------------------------------------------------------------------
//     COPYRIGHT © 2023, TRILINEAR TECHNOLOGIES, INC.
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
//     DESCRIPTION : Flatness determination block.  The flatness determination changes
//                   both the QP value and the previous QP value to align with the way
//                   that the model operates.
//
//                   VLC/RC flags - generated in stage S0 along with the current group
//                   ICH flags    - generated in stage S3 from the current group Qp value
// ------------------------------------------------------------------------------------------------

// ----------------------------------------------
//  includes
// ----------------------------------------------
import dsce_defs_pkg::*;


// ----------------------------------------------
//  entity declaration
// ----------------------------------------------
module dsce_flat_flags
(
    // clock and control interface
    input   logic           dsc_clk,                        // DSC processing clock
    input   logic           dsc_reset_n,                    // DSC domain reset
    input   logic           dsc_pps_update,                 // update pps parameters flag
    input   tDSC_PPS        cfg_pps,                        // parameter set output array
    input   logic [4:0]     cfg_rc_range_max_qp_14,         // rc range parameter for entry 14

    // input data path from the flatness checks
    input   logic           dsc_start_of_slice,             // first group in a slice
    input   logic           dsc_group_valid_in,             // valid group pixels in
    input   logic           dsc_group_last_in,              // last group in
    input   tDSC_PIXEL      dsc_group_in [2:0],             // group input
    input   tDSC_PIXEL      dsc_check_diff_in [2:1],        // differences over the check 1 pixels

    // quantization level
    input  tDSC_QLEVEL      dsc_primary_qp,                 // primary qp input

    // output data path
    output logic            dsc_group_valid_out,            // valid predicted pixels out
    output logic            dsc_group_last_out,             // last group in slice line output
    output tDSC_PIXEL       dsc_group_out [2:0],            // group output
    output tDSC_FLAT_FLAGS  dsc_vlc_flat_flags_out,         // flatness flags for the group
    output logic            dsc_ich_next_is_very_flat       // very flat signal for ICH
);

    // ------------------------------------------------------------------------------------------------------------
    //                                          internal definitions
    // ------------------------------------------------------------------------------------------------------------

    // ----- group buffers ----- //
    logic   [1:0]           i_input_supergroup_index;
    logic   [3:0]           i_buffer_valid;
    tDSC_PIXEL              i_super_group_0 [2:0];
    tDSC_PIXEL              i_sg_0_check_diff[2:1];
    tDSC_PIXEL              i_super_group_1 [2:0];
    tDSC_PIXEL              i_sg_1_check_diff[2:1];
    tDSC_PIXEL              i_super_group_2 [2:0];
    tDSC_PIXEL              i_sg_2_check_diff[2:1];
    tDSC_PIXEL              i_super_group_3 [2:0];
    tDSC_PIXEL              i_sg_3_check_diff[2:1];

    // ----- pipeline signals ----- //
    logic   [3:1]           i_stage_valid;
    logic   [2:0]           i_flush_count;
    logic                   i_flush_group;

    // ----- picture parameters ----- //
    logic [15:0]            i_very_flat_thresh;
    logic [3:0]             i_bits_per_component;
    logic                   i_dsc_version_2_active;
    tDSC_QLEVEL             i_flatness_max_qp, i_flatness_min_qp;

    // ----- flatness determination, ICH ----- //
    logic   [2:1]           i_ich_stage_valid;
    tDSC_QLEVEL             i_ich_qp;
    tDSC_QLEVEL             i_ich_qlevel_y;
    tDSC_QLEVEL             i_ich_qlevel_c;
    logic   [15:0]          i_quant_divisor_y, i_quant_divisor_c;
    logic   [15:0]          i_somewhat_flat_threshold_y;
    logic   [15:0]          i_somewhat_flat_threshold_c;
    logic   [2:0]           i_very_flat_check_1;
    logic   [2:0]           i_very_flat_check_2;
    logic   [2:0]           i_somewhat_flat_check_1;
    logic   [2:0]           i_somewhat_flat_check_2;

    // ----- legacy and debug signals ----- //
    logic                   i_perform_flatness_check;
    logic   [1:0]           i_output_supergroup_index;
    logic                   i_current_first_flat_valid;
    logic   [1:0]           i_current_first_flat;
    logic                   i_current_flatness_type;
    logic                   i_next_first_flat_valid;
    logic   [1:0]           i_next_first_flat;
    logic                   i_next_flatness_type;
    logic   [1:0]           i_candidate_type [3:0];
    tDSC_QLEVEL             i_flat_qp;
    tDSC_QLEVEL             i_flat_qlevel_y;
    tDSC_QLEVEL             i_flat_qlevel_c;
    logic   [15:0]          i_flat_threshold_y;
    logic   [15:0]          i_flat_threshold_c;

    function automatic logic [1:0] dsce_flatness_type(
        input tDSC_PIXEL check_1,
        input tDSC_PIXEL check_2
    );
        logic very_flat_1;
        logic somewhat_flat_1;
        logic very_flat_2;
        logic somewhat_flat_2;

        very_flat_1 = check_1.y <= i_very_flat_thresh &&
                      check_1.co <= i_very_flat_thresh &&
                      check_1.cg <= i_very_flat_thresh;
        somewhat_flat_1 = check_1.y <= i_flat_threshold_y &&
                          check_1.co <= i_flat_threshold_c &&
                          check_1.cg <= i_flat_threshold_c;
        very_flat_2 = check_2.y <= i_very_flat_thresh &&
                      check_2.co <= i_very_flat_thresh &&
                      check_2.cg <= i_very_flat_thresh;
        somewhat_flat_2 = check_2.y <= i_flat_threshold_y &&
                          check_2.co <= i_flat_threshold_c &&
                          check_2.cg <= i_flat_threshold_c;

        if (very_flat_1 || (!somewhat_flat_1 && very_flat_2))
            return 2'd2;
        if (somewhat_flat_1 || somewhat_flat_2)
            return 2'd1;
        return 2'd0;
    endfunction


    // ------------------------------------------------------------------------------------------------------------
    //                                             processes
    // ------------------------------------------------------------------------------------------------------------

    // signal assignments
    always_comb begin : SignalMap
        // ----- control flags ----- //

        // only calculate flatness when allowed by the primary_qp value
        i_perform_flatness_check = (dsc_primary_qp >= i_flatness_min_qp && dsc_primary_qp <= i_flatness_max_qp) ? 1'b1 : 1'b0;

        i_flat_qp = dsce_adjust_qp_somewhat_flat(dsc_primary_qp);
        i_flat_qlevel_y = dsce_qp_to_qlevel(kBPC_Y_FLAG, i_bits_per_component, i_flat_qp);
        i_flat_qlevel_c = dsce_qp_to_qlevel(kBPC_C_FLAG, i_bits_per_component, i_flat_qp);
        if (i_dsc_version_2_active && !cfg_pps.convert_rgb && i_flat_qlevel_c != 0)
            i_flat_qlevel_c = i_flat_qlevel_c - 1'b1;
        i_flat_threshold_y = dsce_max_2(i_very_flat_thresh, dsce_quant_divisor(i_flat_qlevel_y));
        i_flat_threshold_c = dsce_max_2(i_very_flat_thresh, dsce_quant_divisor(i_flat_qlevel_c));

        // group 3 输出时，队列中的 1/2/3 和当前输入正好覆盖下一个 supergroup。
        i_candidate_type[0] = dsce_flatness_type(i_sg_1_check_diff[1], i_sg_1_check_diff[2]);
        i_candidate_type[1] = dsce_flatness_type(i_sg_2_check_diff[1], i_sg_2_check_diff[2]);
        i_candidate_type[2] = dsce_flatness_type(i_sg_3_check_diff[1], i_sg_3_check_diff[2]);
        i_candidate_type[3] = dsce_flatness_type(dsc_check_diff_in[1], dsc_check_diff_in[2]);

        // quantization divisors
        i_quant_divisor_y = dsce_quant_divisor(i_ich_qlevel_y);
        i_quant_divisor_c = dsce_quant_divisor(i_ich_qlevel_c);

        // ----- very flat checks for ICH ----- //
        i_ich_qp = dsce_adjust_qp_somewhat_flat(dsc_primary_qp);

        i_very_flat_check_1[0] = (i_sg_0_check_diff[1].y  > i_very_flat_thresh) ? 1'b0 : 1'b1;
        i_very_flat_check_1[1] = (i_sg_0_check_diff[1].co > i_very_flat_thresh) ? 1'b0 : 1'b1;
        i_very_flat_check_1[2] = (i_sg_0_check_diff[1].cg > i_very_flat_thresh) ? 1'b0 : 1'b1;

        i_somewhat_flat_check_1[0] = (i_sg_0_check_diff[1].y > i_somewhat_flat_threshold_y) ? 1'b0 : 1'b1;
        i_somewhat_flat_check_1[1] = (i_sg_0_check_diff[1].y > i_somewhat_flat_threshold_c) ? 1'b0 : 1'b1;
        i_somewhat_flat_check_1[2] = (i_sg_0_check_diff[1].y > i_somewhat_flat_threshold_c) ? 1'b0 : 1'b1;

        i_very_flat_check_2[0] = (i_sg_0_check_diff[2].y  > i_very_flat_thresh) ? 1'b0 : 1'b1;
        i_very_flat_check_2[1] = (i_sg_0_check_diff[2].co > i_very_flat_thresh) ? 1'b0 : 1'b1;
        i_very_flat_check_2[2] = (i_sg_0_check_diff[2].cg > i_very_flat_thresh) ? 1'b0 : 1'b1;

        i_somewhat_flat_check_2[0] = (i_sg_0_check_diff[1].y > i_somewhat_flat_threshold_y) ? 1'b0 : 1'b1;
        i_somewhat_flat_check_2[1] = (i_sg_0_check_diff[1].y > i_somewhat_flat_threshold_c) ? 1'b0 : 1'b1;
        i_somewhat_flat_check_2[2] = (i_sg_0_check_diff[1].y > i_somewhat_flat_threshold_c) ? 1'b0 : 1'b1;

    end : SignalMap


    // -------------------------------------------------------
    //  internal processing pipeline logic
    // -------------------------------------------------------
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : PipelineLogic
        if (dsc_reset_n == 1'b0) begin
            dsc_group_valid_out <= 1'b0;
            dsc_group_last_out <= 1'b0;
            dsc_group_out <= '{default: kDSC_PIXEL_INIT};
            dsc_vlc_flat_flags_out <= kDSC_FLAT_FLAGS_INIT;

            i_stage_valid <= 3'b000;
            i_flush_count <= 3'd0;
            i_flush_group <= 1'b0;
            i_output_supergroup_index <= 2'd0;
            i_current_first_flat_valid <= 1'b0;
            i_current_first_flat <= 2'd0;
            i_current_flatness_type <= 1'b0;

        end else begin

            // ----- default signal states ----- //
            dsc_group_valid_out <= 1'b0;
            dsc_group_last_out <= 1'b0;
            i_flush_group <= 1'b0;
            i_stage_valid <= 3'b000;

            // ----- stage 0, input valid ----- //
            if (dsc_group_valid_in == 1'b1 || i_flush_group == 1'b1) begin
                i_stage_valid[1] <= 1'b1;
                if (dsc_group_last_in == 1'b1) begin
                    i_flush_count <= 3'd5;
                end // if
            end // if

            // ----- stage 1 ----- //
            if (i_stage_valid[1] == 1'b1) begin
                i_stage_valid[2] <= 1'b1;
            end // if

            // ----- stage 2 ----- //
            if (i_stage_valid[2] == 1'b1) begin
                i_stage_valid[3] <= 1'b1;
            end // if

            // ----- stage 3 ----- //
            if (i_stage_valid[3] == 1'b1) begin
                // group output
                if (i_buffer_valid[0] == 1'b1) begin
                    logic scan_prev_flat;
                    dsc_group_valid_out <= 1'b1;
                    dsc_group_out <= i_super_group_0;
                    dsc_group_last_out <= (i_flush_count == 3'd1) ? 1'b1 : 1'b0;
                    dsc_vlc_flat_flags_out <= kDSC_FLAT_FLAGS_INIT;

                    dsc_vlc_flat_flags_out.group_flatness_type <=
                        (i_current_first_flat_valid && i_output_supergroup_index == i_current_first_flat) ?
                        (i_current_flatness_type ? kDSC_VERY_FLAT : kDSC_SOMEWHAT_FLAT) : kDSC_NOT_FLAT;
                    if (i_dsc_version_2_active && i_flush_count == 3'd1)
                        dsc_vlc_flat_flags_out.group_flatness_type <= kDSC_VERY_FLAT;

                    if (i_output_supergroup_index == 2'd0 && i_current_first_flat_valid) begin
                        dsc_vlc_flat_flags_out.send_flatness <= 1'b1;
                        dsc_vlc_flat_flags_out.first_flat <= i_current_first_flat;
                        dsc_vlc_flat_flags_out.flatness_type <= i_current_flatness_type;
                    end

                    if (i_output_supergroup_index == 2'd3) begin
                        i_next_first_flat_valid = 1'b0;
                        i_next_first_flat = 2'd0;
                        i_next_flatness_type = 1'b0;
                        scan_prev_flat = i_current_first_flat_valid;
                        if (i_perform_flatness_check) begin
                            for (int fx = 0; fx < 4; fx++) begin
                                if (!i_next_first_flat_valid && !scan_prev_flat && i_candidate_type[fx] != 0) begin
                                    i_next_first_flat_valid = 1'b1;
                                    i_next_first_flat = fx[1:0];
                                    i_next_flatness_type = i_candidate_type[fx] == 2'd2;
                                end
                                scan_prev_flat = i_candidate_type[fx] != 0;
                            end
                        end
                        dsc_vlc_flat_flags_out.next_flatness_flag <= i_next_first_flat_valid;
                        i_current_first_flat_valid <= i_next_first_flat_valid;
                        i_current_first_flat <= i_next_first_flat;
                        i_current_flatness_type <= i_next_flatness_type;
                    end

                    i_output_supergroup_index <= i_output_supergroup_index + 2'd1;
                end // if

                // flush logic
                if (i_flush_count[2:1] != 2'd0) begin
                    i_flush_group <= 1'b1;
                    i_flush_count <= i_flush_count - 3'd1;
                end else begin
                    i_flush_count <= 3'd0;
                end // if
            end // if

        end // if
    end : PipelineLogic


    // -------------------------------------------------------
    //  next group is very flat determination for ICH
    // -------------------------------------------------------
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : ICHFlags
        if (dsc_reset_n == 1'b0) begin
            dsc_ich_next_is_very_flat <= 1'b0;

            i_ich_stage_valid <= 2'b00;
            i_ich_qlevel_y <= kDSC_QLEVEL_ZERO;
            i_ich_qlevel_c <= kDSC_QLEVEL_ZERO;
            i_somewhat_flat_threshold_y <= 16'h0000;
            i_somewhat_flat_threshold_c <= 16'h0000;

        end else begin

            // ----- default signal states ----- //
            i_ich_stage_valid <= 2'b00;

            // ----- stage 0, very flat checks 1 and 2 ----- //
            if (dsc_group_valid_out == 1'b1) begin
                i_ich_stage_valid[1] <= 1'b1;
                i_ich_qlevel_y <= dsce_qp_to_qlevel(kBPC_Y, i_bits_per_component, i_ich_qp);
                i_ich_qlevel_c <= dsce_qp_to_qlevel(kBPC_C, i_bits_per_component, i_ich_qp);
            end // if

            // ----- stage 1, register somewhat flat threshold ----- //
            if (i_ich_stage_valid[1] == 1'b1) begin
                i_ich_stage_valid[2] <= 1'b1;
                i_somewhat_flat_threshold_y <= dsce_max_2(i_very_flat_thresh, i_quant_divisor_y);
                i_somewhat_flat_threshold_c <= dsce_max_2(i_very_flat_thresh, i_quant_divisor_c);
            end // if

            // ----- stage 2, register all checks ----- //
            if (i_ich_stage_valid[2] == 1'b1) begin
                if (i_very_flat_check_1 == 3'b111 || (i_somewhat_flat_check_1 != 3'b111 && i_very_flat_check_2 == 3'b111)) begin
                    dsc_ich_next_is_very_flat <= i_dsc_version_2_active;
                end else begin
                    dsc_ich_next_is_very_flat <= 1'b0;
                end // if
            end // if

        end // if
    end : ICHFlags


    // -------------------------------------------------------
    //  group storage and indexing
    // -------------------------------------------------------
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : GroupPipeline
        if (dsc_reset_n == 1'b0) begin
            i_super_group_0 <= '{default: kDSC_PIXEL_INIT};
            i_sg_0_check_diff <= '{default: kDSC_PIXEL_INIT};
            i_super_group_1 <= '{default: kDSC_PIXEL_INIT};
            i_sg_1_check_diff <= '{default: kDSC_PIXEL_INIT};
            i_super_group_2 <= '{default: kDSC_PIXEL_INIT};
            i_sg_2_check_diff <= '{default: kDSC_PIXEL_INIT};
            i_super_group_3 <= '{default: kDSC_PIXEL_INIT};
            i_sg_3_check_diff <= '{default: kDSC_PIXEL_INIT};

            i_input_supergroup_index <= 2'd0;
            i_buffer_valid <= 4'b0000;

        end else begin

            // ----- track the supergroup ----- //
            if (dsc_start_of_slice == 1'b1) begin
                i_input_supergroup_index <= 2'd3;
            end else if (dsc_group_valid_in == 1'b1) begin
                i_input_supergroup_index <= i_input_supergroup_index + 2'd1;
            end // if

            // ----- group queue ---- //
            if (i_stage_valid[3] == 1'b1) begin
                i_super_group_0 <= i_super_group_1;
                i_super_group_1 <= i_super_group_2;
                i_super_group_2 <= i_super_group_3;
                i_super_group_3 <= dsc_group_in;

                i_sg_0_check_diff <= i_sg_1_check_diff;
                i_sg_1_check_diff <= i_sg_2_check_diff;
                i_sg_2_check_diff <= i_sg_3_check_diff;
                i_sg_3_check_diff <= dsc_check_diff_in;
            end // if

            // ----- valid bits for data flow control ----- //
            if (dsc_start_of_slice == 1'b1) begin
                i_buffer_valid <= 4'b0000;
            end else if (i_stage_valid[3] == 1'b1) begin
                i_buffer_valid <= (i_flush_count == 3'd0 || i_flush_count == 3'd5) ? {1'b1, i_buffer_valid[3:1]} : {1'b0, i_buffer_valid[3:1]};
            end // if

        end // if
    end : GroupPipeline


    // -------------------------------------------------------
    //  PPS value local registers
    // -------------------------------------------------------
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : PictureParameters
        if (dsc_reset_n == 1'b0) begin
            i_bits_per_component <= 4'd0;
            i_dsc_version_2_active <= 1'b0;
            i_flatness_min_qp <= kDSC_QLEVEL_ZERO;
            i_flatness_max_qp <= kDSC_QLEVEL_ZERO;
            i_very_flat_thresh <= 16'h0000;

        end else begin

            if (dsc_pps_update == 1'b1)  begin
                i_bits_per_component <= cfg_pps.bits_per_component;
                i_dsc_version_2_active <= (cfg_pps.dsc_version_minor == 4'd2) ? 1'b1 : 1'b0;
                i_flatness_min_qp <= cfg_pps.flatness_min_qp;
                i_flatness_max_qp <= cfg_pps.flatness_max_qp;
            end // if

            case (i_bits_per_component)
                4'd0:     i_very_flat_thresh <= 16'h0200;
                4'd14:    i_very_flat_thresh <= 16'h0080;
                4'd12:    i_very_flat_thresh <= 16'h0020;
                4'd10:    i_very_flat_thresh <= 16'h0008;
                default:  i_very_flat_thresh <= 16'h0002;
            endcase

        end // if
    end : PictureParameters


endmodule : dsce_flat_flags
