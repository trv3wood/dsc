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
//     DESCRIPTION : Rate control function for the DSC encoder.  This block performs both
//                   long term rate control and short term rate control.
// ------------------------------------------------------------------------------------------------

// ----------------------------------------------
//  includes
// ----------------------------------------------
import dsce_defs_pkg::*;


// ----------------------------------------------
//  entity declaration
// ----------------------------------------------
module dsce_rate
(
    // clock and control interface
    input  logic            dsc_clk,                // DSC processing clock
    input  logic            dsc_reset_n,            // DSC domain reset
    input  tDSCE_CONFIG     cfg_dsc_encoder,        // general encoder configuration
    input  logic            dsc_pps_update,         // update pps parameters flag
    input  tDSC_PPS         cfg_pps,                // parameter set output array
    input  tDSC_RCPS        cfg_rcps,               // rate control parameters

    // input data path
    input  logic            dsc_start_of_slice,     // start of a new slice
    input  logic            dsc_group_valid_in,     // valid data in
    input  logic            dsc_last_in,            // last group in a line
    input  logic [7:0]      dsc_coded_group_size,   // number of bits in the group
    input  logic [7:0]      dsc_rc_size_group,      // size of the group from VLC
    input  tDSC_QLEVEL      dsc_flat_qp_in,         // revised qp from flatness check
    input  tDSC_QLEVEL      dsc_flat_prev_qp_in,    // revised previous qp (ver 2)
    input  logic [2:0]      dsc_use_mpp,            // mpp selected for the group
    input  logic            dsc_ich_selected,       // ich selected for the group
    input  logic [4:0]      dsc_vlc_size [2:0],     // predicted residual size
    input  logic            dsc_flatness_flag,      // flatness flag for the supergroup

    // primary quant level
    output logic            dsc_qp_valid_out,       // primary qp valid output
    output tDSC_QLEVEL      dsc_primary_qp,         // primary quant level
    output tDSC_QLEVEL      dsc_prev_qp,            // previous qp out,
    output logic            dsc_force_mpp           // force MPP mode
);

    // ------------------------------------------------------------------------------------------------------------
    //                                          internal definitions
    // ------------------------------------------------------------------------------------------------------------

    logic [9:0]             i_initial_xmit_delay;
    logic [9:0]             i_bits_per_pixel;
    logic [15:0]            i_scale_decrement_interval;
    logic [15:0]            i_scale_increment_interval;
    logic [15:0]            i_scale_group_count;
    logic                   i_set_scale_increment;
    logic signed [16:0]     i_set_scale_offset;
    logic [3:0]             i_bits_per_component;

    logic [5:0]             i_initial_scale_value;
    logic                   i_scale_increment_active;
    logic [4:0]             i_rc_quant_incr_limit1;
    logic [4:0]             i_rc_quant_incr_limit0;
    logic [3:0]             i_rc_edge_factor;
    logic [15:0]            i_slice_width;
    logic [4:0]             i_bpc_max_qp;
    logic [4:0]             i_adj_max_qp;
    logic [4:0]             i_adj_min_qp;

    logic                   i_first_group, i_last_group;
    logic [15:0]            i_line_pixels;
    logic [11:0]            i_tgt_bits_per_group;           // 8.4
    logic [11:0]            i_ixd_bits_per_group_gte;       // 8.4
    logic [11:0]            i_ixd_bits_per_group_lt;        // 8.4
    logic [11:0]            i_bits_per_pixel_x3;            // 8.4
    logic [4:0]             i_first_bpg_offset;             // 5.0
    logic [15:0]            i_slice_bpg_offset;             // 5.11
    logic [15:0]            i_nfl_bpg_offset;               // 5.11
    logic [15:0]            i_initial_offset;               // 16.0
    logic [15:0]            i_final_offset;                 // 16.0
    logic [15:0]            i_rc_model_size;                // 16.0
    logic signed [16:0]     i_final_offset_limit;           // s16.0
    logic [4:0]             i_second_bpg_offset;            // 5.0
    logic [15:0]            i_second_offset_adjust;         // 5.11
    logic [15:0]            i_nsl_bpg_offset;               // 5.11

    // buffer fullness
    logic [15:0]            i_buffer_fullness, i_buffer_fullness_reg;
    logic signed [15:0]     i_fullness_offset;
    logic [9:0]             i_ixd_pixel_count;
    logic [15:0]            i_ixd_remaining_count;
    logic [9:0]             i_pc_decrement;
    logic [9:0]             i_next_ixd_pixel_count;
    logic [7:0]             i_bits_per_group;
    logic [4:0]             i_bits_per_group_frac;
    logic [4:0]             i_bpgf_inc;
    logic [15:0]            i_num_bits_chunk, i_next_nbc;
    logic [11:0]            i_chunk_bpg_current, i_chunk_bpg_next;
    logic [15:0]            i_chunk_pixel_count, i_next_chunk_pixel_count;
    logic [1:0]             i_next_chunk_starting_count;
    logic                   i_end_of_chunk;
    logic [3:0]             i_adjustment_bits;
    logic                   i_ixd_active;
    logic                   i_ixd_end;

    // misc signals
    logic [15:0]            i_vpos;
    logic                   i_first_line;
    logic                   i_first_line_adjust;            // valid in different pipe stages
    logic                   i_second_line_adjust;

    // linear transform
    logic signed [17:0]     i_linear_transform_adjust;
    logic signed [20:0]     i_linear_transform_mult;
    logic signed [19:0]     i_offset_adjust;                // s9.11

    logic signed [27:0]     i_rc_xform_offset;              // s16.11
    logic signed [27:0]     i_rc_xform_offset_adjust;       // s16.11
    logic [5:0]             i_rc_xform_scale;               // 3.3
    logic                   i_offset_limit_active;

    // long term parameter selection
    logic [4:0]             i_min_qp;
    logic [4:0]             i_max_qp;
    logic signed [5:0]      i_bpg_offset;
    logic [15:0]            i_rc_range_parameters [14:0];
    logic signed [16:0]     i_rc_buf_thresh [13:0];
    logic [13:0]            i_rc_buf_thresh_hit;
    logic signed [16:0]     i_rc_model_fullness;
    logic [3:0]             i_rc_buf_index;

    // short term rate control
    logic signed [6:0]      i_rcx_bpg_offset;
    logic [7:0]             i_bits_per_group_cfg;            // 8.0
    logic signed [9:0]      i_rc_tgt_bits_line;
    logic signed [9:0]      i_rc_tgt_bits_calc;
    logic [7:0]             i_rc_tgt_bits_group;
    logic                   i_residual_zero;
    logic [11:0]            i_rc_size_group_edge;

    logic [4:0]             i_inc_select;
    tDSC_QLEVEL             i_inc_qp [1:0];
    logic [7:0]             i_increment_amount;
    logic [6:0]             i_current_plus_incr;
    tDSC_QLEVEL             i_inc_qp_value;
    tDSC_QLEVEL             i_current_qp;
    tDSC_QLEVEL             i_current_qp_minus_1;
    tDSC_QLEVEL             i_current_qp_st;

    logic                   i_dsc_version_2_active;
    tDSC_QLEVEL             i_prev_qp;
    tDSC_QLEVEL             i_prev_2_qp;
    logic [1:0]             i_bitsave_mode;
    logic [6:0]             i_pred_activity;
    logic [4:0]             i_bitsave_thresh;
    logic                   i_flatness;

    logic [6:0]             i_sterm_decisions;
    tDSC_QLEVEL             i_st_qp;
    logic [2:0]             i_mpp_sel;
    logic                   i_ich_sel;
    logic [4:0]             i_predicted_size [2:0];
    logic [1:0]             i_mpp_state;

    logic [7:0]             i_tgt_minus_offset;
    logic [7:0]             i_tgt_plus_offset;

    logic [2:0]             i_valid_pipe;
    logic [2:0]             i_adjust_pipe;

    // force MPP logic
    logic [19:0]            i_chunk_size_times_8;
    logic [19:0]            i_max_chunk_bits_next_group;


    // ------------------------------------------------------------------------------------------------------------
    //                                             functions
    // ------------------------------------------------------------------------------------------------------------

    // -------------------------------------------------------
    //  Determine which quantization level is larger.  This
    //  function is implemented for code clarity.
    // -------------------------------------------------------
    function automatic tDSC_QLEVEL dsce_max_qp (
        input tDSC_QLEVEL qp_a,
        input tDSC_QLEVEL qp_b
    );
        if (qp_a > qp_b) begin
            dsce_max_qp = qp_a;
        end else begin
            dsce_max_qp = qp_b;
        end // if
    endfunction : dsce_max_qp


    // -------------------------------------------------------
    //  Determine which quantization level is smaller.  This
    //  function is implemented for code clarity.
    // -------------------------------------------------------
    function automatic tDSC_QLEVEL dsce_min_qp (
        input tDSC_QLEVEL qp_a, qp_b
    );
        if (qp_a > qp_b) begin
            dsce_min_qp = qp_b;
        end else begin
            dsce_min_qp = qp_a;
        end // if
    endfunction : dsce_min_qp


    // -------------------------------------------------------
    //  Provides a clamping function for the quantization
    //  level between the provided minimum and maximum.
    // -------------------------------------------------------
    function automatic tDSC_QLEVEL dsce_clamp_qp (
        input tDSC_QLEVEL qp_val,
        input tDSC_QLEVEL qp_min,
        input tDSC_QLEVEL qp_max
    );
        if (qp_val > qp_max) begin
            dsce_clamp_qp = qp_max;
        end else if (qp_val < qp_min) begin
            dsce_clamp_qp = qp_min;
        end else begin
            dsce_clamp_qp = qp_val;
        end // if
    endfunction : dsce_clamp_qp


    // -------------------------------------------------------
    //  Return the larger value of the two predicted sizes.
    // -------------------------------------------------------
    function automatic logic [4:0] dsce_max_pred_size (
        input logic [4:0] pred_size_a,
        input logic [4:0] pred_size_b
    );
        if (pred_size_a > pred_size_b) begin
            dsce_max_pred_size = pred_size_a;
        end else begin
            dsce_max_pred_size = pred_size_b;
        end // if
    endfunction : dsce_max_pred_size

    // ------------------------------------------------------------------------------------------------------------
    //                                             processes
    // ------------------------------------------------------------------------------------------------------------

    // signal assignments
    always_comb begin : SignalMap
        dsc_prev_qp = i_prev_qp;
        i_pc_decrement = (i_line_pixels[15:2] == 14'd0) ? {8'h00, i_line_pixels[1:0]} : 10'd3;
        i_next_ixd_pixel_count = i_ixd_pixel_count - i_pc_decrement;
        i_next_chunk_pixel_count = i_chunk_pixel_count - i_pc_decrement;
        i_bits_per_pixel_x3 = 12'h000 + {i_bits_per_pixel, 1'b0} + i_bits_per_pixel;

        case (i_ixd_pixel_count[1:0])
            2'd1:       i_ixd_remaining_count = 16'd3;
            2'd2:       i_ixd_remaining_count = 16'd2;
            2'd3:       i_ixd_remaining_count = 16'd1;
            default:    i_ixd_remaining_count = 16'd3;
        endcase

        case (i_chunk_pixel_count[1:0])
            2'd1:       i_next_chunk_starting_count = 2'd2;
            2'd2:       i_next_chunk_starting_count = 2'd1;
            2'd3:       i_next_chunk_starting_count = 2'd0;
            default:    i_next_chunk_starting_count = 2'd3;
        endcase

        if (i_end_of_chunk == 1'b1) begin
            i_next_nbc = i_num_bits_chunk + {8'h00, i_chunk_bpg_current[11:4]};
        end else begin
            i_next_nbc = i_num_bits_chunk + {8'h00, i_bits_per_group};
        end // if

        i_bpgf_inc = i_bits_per_group_frac + {1'b0, i_tgt_bits_per_group[3:0]};
        i_fullness_offset = {8'h00, dsc_coded_group_size} - {8'h00, i_bits_per_group} - i_adjustment_bits;
        i_buffer_fullness = i_buffer_fullness_reg + i_fullness_offset;
        i_rc_model_fullness = {i_linear_transform_mult[20], i_linear_transform_mult[18:3]};

        i_first_line = (i_vpos == 16'd0) ? 1'b1 : 1'b0;
        i_first_line_adjust = (i_vpos == 16'd0 && i_last_group == 1'b0) ? 1'b1 : 1'b0;
        i_second_line_adjust = ((i_vpos == 16'd1 && i_last_group == 1'b0) || (i_vpos == 16'd0 && i_last_group == 1'b1)) ? 1'b1 : 1'b0;

        i_set_scale_offset = i_rc_xform_offset[27:11] + $signed({1'b0, i_rc_model_size});
        i_linear_transform_adjust = $signed({2'b00, i_buffer_fullness}) + $signed({i_rc_xform_offset[27], i_rc_xform_offset[27:11]});
        i_rc_xform_offset_adjust = i_rc_xform_offset + i_offset_adjust;

        i_rc_tgt_bits_calc = i_rc_tgt_bits_line + i_bpg_offset;
        i_rc_tgt_bits_group = (i_rc_tgt_bits_calc[9] == 1'b1) ? 8'd0 : i_rc_tgt_bits_calc[7:0];
        i_tgt_minus_offset = (i_rc_tgt_bits_group > {4'h0, cfg_rcps.rc_tgt_offset_lo}) ? i_rc_tgt_bits_group - {4'b0000, cfg_rcps.rc_tgt_offset_lo} : 8'd0;
        i_tgt_plus_offset = i_rc_tgt_bits_group + {4'h0, cfg_rcps.rc_tgt_offset_hi};

        // increment logic
        i_inc_select[0] = (i_current_qp_st == i_prev_2_qp) ? 1'b1 : 1'b0;
        i_inc_select[1] = (i_current_qp_st > i_prev_2_qp) ? 1'b1 : 1'b0;
        i_inc_select[2] = (i_current_qp_st < i_rc_quant_incr_limit1) ? 1'b1 : 1'b0;
        i_inc_select[3] = ({3'b000, dsc_rc_size_group, 1'b0} < i_rc_size_group_edge) ? 1'b1 : 1'b0;
        i_inc_select[4] = ({3'b000, dsc_rc_size_group, 1'b0} < i_rc_size_group_edge) && (i_current_qp_st < i_rc_quant_incr_limit0) ? 1'b1 : 1'b0;

        // decision 1 table
        i_sterm_decisions[0] = ($signed({1'b0, i_buffer_fullness_reg}) > (-16'sd172 - $signed(i_rc_xform_offset[27:11]))) ? 1'b1 : 1'b0;
        i_sterm_decisions[1] = (i_dsc_version_2_active == 1'b1 && i_buffer_fullness_reg < 16'd192) ? 1'b1 : 1'b0;
        i_sterm_decisions[2] = (i_dsc_version_2_active == 1'b1 && i_bitsave_mode == 2'd2) ? 1'b1 : 1'b0;
        i_sterm_decisions[3] = (i_dsc_version_2_active == 1'b1 && i_bitsave_mode == 2'd1) ? 1'b1 : 1'b0;
        i_sterm_decisions[4] = (i_residual_zero == 1'b1) ? 1'b1 : 1'b0;
        i_sterm_decisions[5] = ((dsc_rc_size_group < i_tgt_minus_offset) && (i_dsc_version_2_active == 1'b1 || dsc_coded_group_size < i_tgt_minus_offset)) ? 1'b1 : 1'b0;
        i_sterm_decisions[6] = (dsc_coded_group_size > i_tgt_plus_offset && i_buffer_fullness_reg >= 16'd64) ? 1'b1 : 1'b0;

        // additional qp adjustments
        i_adj_max_qp = (i_max_qp == i_bpc_max_qp) ? i_max_qp : i_max_qp + 5'd1;
        i_adj_min_qp = (i_min_qp[4:2] == 3'd0) ? 5'd0 : i_min_qp - 5'd4;
        i_current_qp_minus_1 = (i_current_qp == 5'd0) ? 5'd0 : i_current_qp - 5'd1;
        i_increment_amount = dsc_coded_group_size - i_rc_tgt_bits_group;
        i_current_plus_incr = {1'b0, i_current_qp_st} + i_increment_amount[7:1];
        i_inc_qp[0] = i_current_qp_st;
        i_inc_qp[1] = (i_current_plus_incr > 7'd16) ? i_max_qp : dsce_min_qp(i_max_qp, i_current_plus_incr[4:0]);

        // short term qp
        case (i_sterm_decisions) inside
            7'b??????1: i_st_qp = i_rc_range_parameters[14][10:6];
            7'b?????10: i_st_qp = i_min_qp;
            7'b????100: i_st_qp = dsce_min_qp(i_current_qp + 5'd2, i_adj_max_qp);
            7'b???1000: i_st_qp = dsce_clamp_qp(i_current_qp, i_min_qp, i_adj_max_qp);
            7'b??10000: i_st_qp = (i_dsc_version_2_active == 1'b1) ? dsce_max_qp(i_current_qp_minus_1, i_adj_min_qp) : dsce_max_qp(i_current_qp_minus_1, i_min_qp);
            7'b?100000: i_st_qp = dsce_clamp_qp(i_current_qp_minus_1, i_min_qp, i_max_qp);
            7'b1000000: i_st_qp = (i_dsc_version_2_active == 1'b1) ? dsce_clamp_qp(i_inc_qp_value, i_min_qp, i_max_qp) : i_inc_qp_value;
            default:    i_st_qp = (i_dsc_version_2_active == 1'b1) ? dsce_clamp_qp(i_current_qp, i_min_qp, i_max_qp) : i_current_qp;
        endcase

        // force mpp signals
        i_max_chunk_bits_next_group = {4'h0, i_num_bits_chunk} + {12'h000, cfg_dsc_encoder.max_bits_per_group} + 20'd8;
    end : SignalMap


    // -------------------------------------------------------
    //  buffer fullness management
    // -------------------------------------------------------
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : BufferFullness
        if (dsc_reset_n == 1'b0) begin
            i_buffer_fullness_reg <= 16'd0;
            i_ixd_pixel_count <= 10'd0;
            i_bits_per_group <= 8'd0;
            i_bits_per_group_frac <= 5'd0;
            i_ixd_active <= 1'b0;
            i_ixd_end <= 1'b0;
            i_ixd_bits_per_group_gte <= 12'h000;
            i_ixd_bits_per_group_lt <= 12'h000;
            i_num_bits_chunk <= 16'd0;
            i_chunk_bpg_current <= 12'd0;
            i_chunk_bpg_next <= 12'd0;
            i_chunk_pixel_count <= 16'd0;
            i_end_of_chunk <= 1'b0;
            i_adjustment_bits <= 4'd0;

        end else begin

            // pixel counter for initial transmit delay (referenced to a terminal value of 1)
            if (dsc_start_of_slice == 1'b1) begin
                i_ixd_pixel_count <= i_initial_xmit_delay;
                i_ixd_active <= 1'b1;
            end else if (dsc_group_valid_in == 1'b1) begin
                i_ixd_end <= (i_ixd_active == 1'b1 && i_next_ixd_pixel_count[9:2] == 8'd0) ? 1'b1 : 1'b0;

                if (i_ixd_end == 1'b1) begin
                    i_ixd_active <= 1'b0;
                end // if

                if (i_ixd_active == 1'b1) begin
                    i_ixd_pixel_count <= i_next_ixd_pixel_count;
                end // if

                case (i_next_ixd_pixel_count[1:0])
                    2'd3:     i_ixd_bits_per_group_lt <= i_bits_per_pixel_x3;
                    2'd2:     i_ixd_bits_per_group_lt <= {1'b0, i_bits_per_pixel, 1'b0};
                    2'd1:     i_ixd_bits_per_group_lt <= {2'b00, i_bits_per_pixel};
                    default:  i_ixd_bits_per_group_lt <= 12'd0;
                endcase // pixel count

                case (i_next_ixd_pixel_count[1:0])
                    2'd3:     i_ixd_bits_per_group_gte <= {2'b00, i_bits_per_pixel};
                    2'd2:     i_ixd_bits_per_group_gte <= {1'b0, i_bits_per_pixel, 1'b0};
                    2'd1:     i_ixd_bits_per_group_gte <= i_bits_per_pixel_x3;
                    default:  i_ixd_bits_per_group_gte <= i_bits_per_pixel_x3;
                endcase // pixel count

            end // if

            // buffer fullness
            if (dsc_start_of_slice == 1'b1) begin
                i_buffer_fullness_reg <= 16'd0;
            end else if (i_valid_pipe[1] == 1'b1) begin
                i_buffer_fullness_reg <= i_buffer_fullness;
            end // if

            // buffer fullness adjustment at the end of the chunk
            if (i_valid_pipe[0] == 1'b1 && i_end_of_chunk == 1'b1 && i_next_nbc[2:0] != 3'd0) begin
                i_adjustment_bits <= 4'd8 - {1'b0, i_next_nbc[2:0]};
            end else begin
                i_adjustment_bits <= 4'd0;
            end // if

            // fractional bit counter
            if (dsc_start_of_slice == 1'b1) begin
                i_bits_per_group_frac <= 5'd0;
                i_bits_per_group <= 8'd0;
            end else if (dsc_group_valid_in == 1'b1) begin
                case ({i_ixd_active, i_ixd_end})
                    2'b00:  begin
                        i_bits_per_group_frac <= {1'b0, i_bpgf_inc[3:0]};
                        i_bits_per_group <= i_tgt_bits_per_group[11:4] + i_bpgf_inc[4];
                    end // ixd not active
                    2'b11:  begin
                        i_bits_per_group <= i_ixd_bits_per_group_gte[11:4];
                        i_bits_per_group_frac <= {1'b0, i_ixd_bits_per_group_gte[3:0]};
                    end // partial group
                    default:  begin
                        i_bits_per_group_frac <= 5'd0;
                        i_bits_per_group <= 8'd0;
                    end // default
                endcase
            end // if

            // end of chunk bits per group counts
            if (dsc_group_valid_in == 1'b1) begin
                case (i_chunk_pixel_count[1:0])
                    2'd3:     begin i_chunk_bpg_current <= i_bits_per_pixel_x3;              i_chunk_bpg_next <= 12'd0;                          end
                    2'd2:     begin i_chunk_bpg_current <= {1'b0, i_bits_per_pixel, 1'b0};   i_chunk_bpg_next <= {2'b00, i_bits_per_pixel};      end
                    2'd1:     begin i_chunk_bpg_current <= {2'b00, i_bits_per_pixel};        i_chunk_bpg_next <= {1'b0, i_bits_per_pixel, 1'b0}; end
                    default:  begin i_chunk_bpg_current <= 12'd0;                            i_chunk_bpg_next <= i_bits_per_pixel_x3;            end
                endcase // chunk_pixels
            end // if

            // track the number of bits in a chunk
            if (dsc_start_of_slice == 1'b1) begin
                i_num_bits_chunk <= 16'd0;
                i_chunk_pixel_count <= i_slice_width;
                i_end_of_chunk <= 1'b0;
            end else begin
                if (dsc_group_valid_in == 1'b1) begin
                    if (i_chunk_pixel_count[15:2] == 14'd0 && i_end_of_chunk == 1'b0) begin
                        i_end_of_chunk <= 1'b1;
                    end else begin
                        i_end_of_chunk <= 1'b0;
                    end // if
                end // if

                if (dsc_group_valid_in == 1'b1) begin
                    if (i_ixd_active == 1'b1 && i_ixd_end == 1'b1) begin
                        i_chunk_pixel_count <= i_slice_width - i_ixd_remaining_count;
                    end else if (i_chunk_pixel_count[15:2] == 14'd0) begin
                        i_chunk_pixel_count <= i_slice_width - {14'd0, i_next_chunk_starting_count};
                    end else if (i_ixd_active == 1'b0) begin
                        i_chunk_pixel_count <= i_next_chunk_pixel_count;
                    end // if
                end // if

                if (i_valid_pipe[0] == 1'b1) begin
                    i_num_bits_chunk <= (i_end_of_chunk == 1'b1) ? {8'h00, i_chunk_bpg_next[11:4]} : i_next_nbc;
                end // if

            end // if

        end // if
    end : BufferFullness


    // -------------------------------------------------------
    //  linear transform stage
    // -------------------------------------------------------
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : LinearTransform
        if (dsc_reset_n == 1'b0) begin
            i_scale_group_count <= 16'd0;
            i_rc_xform_scale <= 6'd0;
            i_vpos <= 16'h0000;
            i_scale_increment_active <= 1'b0;
            i_set_scale_increment <= 1'b0;

            i_rc_xform_offset <= 28'sd0;
            i_offset_limit_active <= 1'b0;
            i_line_pixels <= 16'd0;
            i_first_group <= 1'b0;
            i_last_group <= 1'b0;
            i_tgt_bits_per_group <= 12'h000;
            i_bits_per_group_cfg <= 8'd0;

            i_final_offset_limit <= 17'sd0;
            i_offset_adjust <= 20'sd0;

            i_linear_transform_mult <= 21'h000000;

        end else begin

            // pixels per line/group tracker
            if (dsc_start_of_slice == 1'b1 || (dsc_group_valid_in == 1'b1 && dsc_last_in == 1'b1)) begin
                i_line_pixels <= i_slice_width;
            end else if (dsc_group_valid_in == 1'b1) begin
                i_line_pixels <= i_line_pixels - 16'd3;
            end // if

            if (dsc_start_of_slice == 1'b1) begin
                i_final_offset_limit <= $signed({1'b0, i_final_offset}) - $signed({1'b0, i_rc_model_size});
            end // if

            // set during the last group
            if (i_adjust_pipe[2] == 1'b1) begin
                i_last_group <= 1'b0;
            end else if (dsc_group_valid_in == 1'b1 && dsc_last_in == 1'b1) begin
                i_last_group <= 1'b1;
            end // if

            // set for the first group
            if (dsc_start_of_slice == 1'b1) begin
                i_first_group <= 1'b1;
            end else if (dsc_group_valid_in == 1'b1) begin
                i_first_group <= 1'b0;
            end // if

            // number of pixel bits per group
            if (dsc_start_of_slice == 1'b1) begin
                i_tgt_bits_per_group <= i_bits_per_pixel_x3;
                i_bits_per_group_cfg <= i_bits_per_pixel_x3[11:4] + i_bits_per_pixel_x3[3];
            end else if (i_valid_pipe[2] == 1'b1) begin
                if (i_line_pixels[15:2] == 14'h0000) begin
                    //assert (i_line_pixels[1:0] != 2'b00) else $error("Maximum number of groups per line exceeded for rate control");

                    case (i_line_pixels[1:0])
                        2'b01: begin
                            i_tgt_bits_per_group <= {2'b00, i_bits_per_pixel};
                            i_bits_per_group_cfg <= {2'b00, i_bits_per_pixel[9:4]} + i_bits_per_pixel[3];
                        end // 1 remaining
                        2'b10: begin
                            i_tgt_bits_per_group <= {1'b0, i_bits_per_pixel, 1'b0};
                            i_bits_per_group_cfg <= {1'b0, i_bits_per_pixel[9:4], 1'b0} + i_bits_per_pixel[3];
                        end // 2 remaining
                        default:  begin
                            i_tgt_bits_per_group <= i_bits_per_pixel_x3;
                            i_bits_per_group_cfg <= i_bits_per_pixel_x3[11:4] + i_bits_per_pixel_x3[3];
                        end // 3 remaining
                    endcase
                end else begin
                    i_tgt_bits_per_group <= i_bits_per_pixel_x3;
                    i_bits_per_group_cfg <= i_bits_per_pixel_x3[11:4] + i_bits_per_pixel_x3[3];
                end // if
            end // if

            // slice tracking counters
            if (dsc_start_of_slice == 1'b1) begin
                i_vpos <= 16'd0;
            end else if (i_valid_pipe[2] == 1'b1 && i_last_group == 1'b1) begin
                i_vpos <= i_vpos + 16'd1;
            end // if

            // -------------------------------------------------------
            //  rc scale factor management
            // -------------------------------------------------------
            if (dsc_start_of_slice == 1'b1) begin
                i_set_scale_increment <= 1'b0;
            end else begin
                if (i_scale_increment_active == 1'b0 && (i_vpos != 16'd0 && i_ixd_active == 1'b0) &&
                    (i_scale_increment_interval != 16'd0 && i_set_scale_offset > 17'sd0)) begin
                    i_set_scale_increment <= 1'b1;
                end else begin
                    i_set_scale_increment <= 1'b0;
                end // if
            end // if

            if (dsc_start_of_slice == 1'b1) begin
                i_scale_group_count <= i_scale_decrement_interval;
                i_scale_increment_active <= 1'b0;
            end else if (dsc_group_valid_in == 1'b1) begin

                if (i_set_scale_increment == 1'b1)  i_scale_increment_active <= 1'b1;

                if (i_set_scale_increment == 1'b1) begin
                    i_scale_group_count <= i_scale_increment_interval;
                end else if (i_first_line == 1'b1 && i_rc_xform_scale != 6'd8) begin
                    if (i_scale_group_count == 16'd1) begin
                        i_scale_group_count <= i_scale_decrement_interval;
                    end else begin
                        i_scale_group_count <= i_scale_group_count - 16'd1;
                    end // if
                end else if (i_scale_increment_active == 1'b1) begin
                    if (i_scale_group_count == 16'd1) begin
                        i_scale_group_count <= i_scale_increment_interval;
                    end else begin
                        i_scale_group_count <= i_scale_group_count - 16'd1;
                    end // if
                end // if
            end // if

            // rc scale factor management
            if (dsc_group_valid_in == 1'b1) begin
                if (i_first_group == 1'b1) begin
                    i_rc_xform_scale <= i_initial_scale_value;
                end else if (i_set_scale_increment == 1'b1)  begin
                    i_rc_xform_scale <= 6'd9;
                end else if (i_scale_group_count == 16'd1) begin
                    if (i_scale_increment_active == 1'b0) begin
                        if (i_rc_xform_scale != 6'd8) i_rc_xform_scale <= i_rc_xform_scale - 6'd1;
                    end else begin
                        i_rc_xform_scale <= i_rc_xform_scale + 6'd1;
                    end // if
                end // if
            end // if

            // -------------------------------------------------------
            //  xform offset
            // -------------------------------------------------------
            if (dsc_start_of_slice == 1'b1) begin
                i_rc_xform_offset[27:11] <= $signed({1'b0, i_initial_offset}) - $signed({1'b0, i_rc_model_size});
                i_rc_xform_offset[10:0] <= 11'd0;
                i_offset_adjust <= 20'sd0;
                i_offset_limit_active <= 1'b0;
            end else begin
                case ({i_adjust_pipe, dsc_group_valid_in})
                    {3'b000, 1'b1}:  begin
                        if (i_offset_limit_active == 1'b1 && $signed(i_rc_xform_offset_adjust[27:11]) > i_final_offset_limit) begin
                            i_rc_xform_offset[27:11] <= i_final_offset_limit;
                            i_rc_xform_offset[10:0] <= i_rc_xform_offset_adjust[10:0];
                        end else begin
                            if ($signed(i_rc_xform_offset_adjust[27:11]) < i_final_offset_limit)  begin
                                i_offset_limit_active <= 1'b1;
                            end // if
                            i_rc_xform_offset <= i_rc_xform_offset_adjust;
                        end // if
                    end // s0

                    {3'b001, 1'b0}:  begin
                        case ({i_second_line_adjust, i_first_line_adjust})
                            2'b01:   i_offset_adjust <= {4'h0, i_nsl_bpg_offset} - {4'h0, i_first_bpg_offset, 11'h000};
                            2'b10:   i_offset_adjust <= {4'h0, i_nfl_bpg_offset} - {4'h0, i_second_bpg_offset, 11'h000};
                            default: i_offset_adjust <= {4'h0, i_nfl_bpg_offset} + {4'h0, i_nsl_bpg_offset};
                        endcase
                    end // s1

                    {3'b010, 1'b0}:  begin
                        case ({i_ixd_active, i_ixd_end})
                            2'b10:   i_offset_adjust <= i_offset_adjust - {1'b0, i_tgt_bits_per_group, 7'h00};
                            2'b11:   i_offset_adjust <= i_offset_adjust - {1'b0, i_ixd_bits_per_group_lt, 7'h00};
                            default: ;      // no change
                        endcase
                    end // s2

                    {3'b100, 1'b0}:  begin
                        i_offset_adjust <= i_offset_adjust + i_slice_bpg_offset;
                    end // s3

                    default:  ;
                endcase
            end // if

            // scale multiplier
            if (i_valid_pipe[0] == 1'b1) begin
                i_linear_transform_mult <= $signed({1'b0, i_rc_xform_scale}) * i_linear_transform_adjust;
            end // if
        end // if
    end : LinearTransform


    // -------------------------------------------------------
    //  long term rate control
    // -------------------------------------------------------
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : LongTermRC
        if (dsc_reset_n == 1'b0) begin
            i_rc_buf_index <= 4'hf;
            i_rc_buf_thresh <= '{default:8'h00};
            i_rc_buf_thresh_hit <= 14'h0000;
            i_rc_range_parameters <= '{default:16'h0000};
            i_min_qp <= 5'd0;
            i_max_qp <= 5'd31;
            i_bpg_offset <= 6'sd0;

        end else begin

            // make parameters local at the update and adjust for the model size
            if (dsc_start_of_slice == 1'b1) begin
                i_rc_buf_index <= 4'hf;
            end else if (dsc_pps_update == 1'b1) begin
                i_rc_buf_index <= 4'h0;
            end else if (i_rc_buf_index[3:1] != 3'b111) begin
                i_rc_buf_index <= i_rc_buf_index + 4'd1;
            end // if

            // computed at the time of the pps update (semi-static)
            if (i_rc_buf_index[3:1] != 3'b111) begin
                i_rc_buf_thresh[i_rc_buf_index] <= $signed({3'b000, cfg_rcps.rc_buf_thresh[i_rc_buf_index], 6'h00}) - $signed({1'b0, i_rc_model_size});
            end // if

            if (dsc_pps_update == 1'b1) begin
                for (int px = 0; px < 15; px++) i_rc_range_parameters[px] <= cfg_rcps.rc_range_parameters[px];
            end // if

            // look up one group later
            if (dsc_start_of_slice == 1'b1) begin
                i_rc_buf_thresh_hit <= 14'h3fff;
            end else if (i_valid_pipe[2] == 1'b1) begin
                for (int tx = 0; tx < 14; tx++) begin : RCThresholdHitLoop
                    i_rc_buf_thresh_hit[tx] <= (i_rc_model_fullness <= i_rc_buf_thresh[tx]) ? 1'b1 : 1'b0;
                end : RCThresholdHitLoop
            end // if

            // parameter selection lookup
            case (i_rc_buf_thresh_hit)
                14'h3fff: begin  i_min_qp <= i_rc_range_parameters[0] [15:11];  i_max_qp <= i_rc_range_parameters[0] [10:6];  i_bpg_offset <= $signed(i_rc_range_parameters[0] [5:0]);  end
                14'h3ffe: begin  i_min_qp <= i_rc_range_parameters[1] [15:11];  i_max_qp <= i_rc_range_parameters[1] [10:6];  i_bpg_offset <= $signed(i_rc_range_parameters[1] [5:0]);  end
                14'h3ffc: begin  i_min_qp <= i_rc_range_parameters[2] [15:11];  i_max_qp <= i_rc_range_parameters[2] [10:6];  i_bpg_offset <= $signed(i_rc_range_parameters[2] [5:0]);  end
                14'h3ff8: begin  i_min_qp <= i_rc_range_parameters[3] [15:11];  i_max_qp <= i_rc_range_parameters[3] [10:6];  i_bpg_offset <= $signed(i_rc_range_parameters[3] [5:0]);  end
                14'h3ff0: begin  i_min_qp <= i_rc_range_parameters[4] [15:11];  i_max_qp <= i_rc_range_parameters[4] [10:6];  i_bpg_offset <= $signed(i_rc_range_parameters[4] [5:0]);  end
                14'h3fe0: begin  i_min_qp <= i_rc_range_parameters[5] [15:11];  i_max_qp <= i_rc_range_parameters[5] [10:6];  i_bpg_offset <= $signed(i_rc_range_parameters[5] [5:0]);  end
                14'h3fc0: begin  i_min_qp <= i_rc_range_parameters[6] [15:11];  i_max_qp <= i_rc_range_parameters[6] [10:6];  i_bpg_offset <= $signed(i_rc_range_parameters[6] [5:0]);  end
                14'h3f80: begin  i_min_qp <= i_rc_range_parameters[7] [15:11];  i_max_qp <= i_rc_range_parameters[7] [10:6];  i_bpg_offset <= $signed(i_rc_range_parameters[7] [5:0]);  end
                14'h3f00: begin  i_min_qp <= i_rc_range_parameters[8] [15:11];  i_max_qp <= i_rc_range_parameters[8] [10:6];  i_bpg_offset <= $signed(i_rc_range_parameters[8] [5:0]);  end
                14'h3e00: begin  i_min_qp <= i_rc_range_parameters[9] [15:11];  i_max_qp <= i_rc_range_parameters[9] [10:6];  i_bpg_offset <= $signed(i_rc_range_parameters[9] [5:0]);  end
                14'h3c00: begin  i_min_qp <= i_rc_range_parameters[10][15:11];  i_max_qp <= i_rc_range_parameters[10][10:6];  i_bpg_offset <= $signed(i_rc_range_parameters[10][5:0]);  end
                14'h3800: begin  i_min_qp <= i_rc_range_parameters[11][15:11];  i_max_qp <= i_rc_range_parameters[11][10:6];  i_bpg_offset <= $signed(i_rc_range_parameters[11][5:0]);  end
                14'h3000: begin  i_min_qp <= i_rc_range_parameters[12][15:11];  i_max_qp <= i_rc_range_parameters[12][10:6];  i_bpg_offset <= $signed(i_rc_range_parameters[12][5:0]);  end
                14'h2000: begin  i_min_qp <= i_rc_range_parameters[13][15:11];  i_max_qp <= i_rc_range_parameters[13][10:6];  i_bpg_offset <= $signed(i_rc_range_parameters[13][5:0]);  end
                14'h0000: begin  i_min_qp <= i_rc_range_parameters[14][15:11];  i_max_qp <= i_rc_range_parameters[14][10:6];  i_bpg_offset <= $signed(i_rc_range_parameters[14][5:0]);  end
                default:  begin
                    i_min_qp <= 5'd0;  i_max_qp <= 5'd0;  i_bpg_offset <= 6'sd0;
                    //assert (1 == 0) else $error("LT rate control threshold detection error.  Multiple thresholds selected 0x%04x", i_rc_buf_thresh_hit);
                end
            endcase

        end // if
    end : LongTermRC


    // -------------------------------------------------------
    //  short term rate control logic
    // -------------------------------------------------------
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : ShortTermRC
        if (dsc_reset_n == 1'b0) begin
            dsc_primary_qp <= kDSC_QLEVEL_ZERO;
            dsc_qp_valid_out <= 1'b0;

            i_prev_qp <= kDSC_QLEVEL_ZERO;
            i_prev_2_qp <= kDSC_QLEVEL_ZERO;
            i_valid_pipe <= 3'b000;
            i_adjust_pipe <= 3'b000;

            i_rcx_bpg_offset <= 7'sd0;
            i_rc_tgt_bits_line <= 10'sd0;
            i_residual_zero <= 1'b0;
            i_rc_size_group_edge <= 12'd0;
            i_inc_qp_value <= 5'd0;
            i_current_qp <= 5'd0;
            i_current_qp_st <= 5'd0;

            i_bitsave_mode <= 2'd0;
            i_bitsave_thresh <= 5'd0;
            i_pred_activity <= 7'h00;
            i_mpp_sel <= 3'b000;
            i_ich_sel <= 1'b0;
            i_predicted_size <= '{default: 5'd0};
            i_mpp_state <= 2'd0;
            i_flatness <= 1'b0;

        end else begin

            // determine the bitsave mode value
            if (i_bits_per_component == 4'd0 || cfg_pps.convert_rgb == 1'b0) begin
                i_bitsave_thresh <= {i_bits_per_component, 1'b0} - 5'd2;
            end else begin
                i_bitsave_thresh <= {i_bits_per_component, 1'b0} - 5'd1;
            end // if

            if (dsc_group_valid_in == 1'b1) begin
                i_mpp_sel <= dsc_use_mpp;
                i_ich_sel <= dsc_ich_selected;
                i_predicted_size <= dsc_vlc_size;
                i_flatness <= dsc_flatness_flag;
            end // if

            i_pred_activity <= {2'b00, i_prev_2_qp} + {2'b00, i_predicted_size[0]} + {2'b00, dsce_max_pred_size(i_predicted_size[1], i_predicted_size[2])};

            if (dsc_start_of_slice == 1'b1) begin
                i_mpp_state <= 2'd0;
                i_bitsave_mode <= 2'd0;
            end else if ((i_valid_pipe[1] == 1'b1 && i_dsc_version_2_active == 1'b1) && (i_first_line == 1'b0 && i_flatness == 1'b0)) begin
                if (i_ich_sel == 1'b0 && i_mpp_sel == 3'h7) begin
                    if (i_mpp_state == 2'd0) begin
                        i_mpp_state <= 2'd1;
                    end else begin
                        i_mpp_state <= 2'd2;
                        i_bitsave_mode <= 2'd2;
                    end // if
                end else if (i_ich_sel == 1'b1) begin
                    i_bitsave_mode <= (i_bitsave_mode == 2'd0) ? 2'd1 : i_bitsave_mode;
                end else if (i_ich_sel == 1'b1 || i_pred_activity < {2'b00, i_bitsave_thresh}) begin
                    i_bitsave_mode <= 2'd0;
                    i_mpp_state <= 2'd0;
                end // if
            end else if (i_valid_pipe[1] == 1'b1) begin
                i_mpp_state <= 2'd0;
                i_bitsave_mode <= 2'd0;
            end // if

            // calculate the target bit offset based on the line
            if (dsc_start_of_slice == 1'b1) begin
                i_rcx_bpg_offset <= $signed({2'b00, i_first_bpg_offset}) - $signed({2'b00, i_nsl_bpg_offset[15:11]});
            end else if (i_valid_pipe[2] == 1'b1 && i_last_group == 1'b1) begin
                if (i_vpos == 16'd0) begin
                    i_rcx_bpg_offset <= $signed({2'b00, i_second_bpg_offset}) - $signed({2'b00, i_nfl_bpg_offset[15:11]});
                end else begin
                    i_rcx_bpg_offset <= 7'sd0 - $signed({2'b00, i_nsl_bpg_offset[15:11]}) - $signed({2'b00, i_nfl_bpg_offset[15:11]});
                end // if
            end // if

            // target bit count
            i_rc_tgt_bits_line <= $signed({2'b00, i_bits_per_group_cfg}) + i_rcx_bpg_offset - i_slice_bpg_offset[15:11];

            // hold the previous qp values and buffer fullness
            if (dsc_group_valid_in == 1'b1) begin
                i_prev_qp <= dsc_flat_qp_in;
                i_prev_2_qp <= dsc_flat_prev_qp_in;
            end // if

            if (i_valid_pipe[0] == 1'b1) begin
                i_current_qp_st <= dsce_max_qp(dsc_flat_qp_in, i_min_qp);
                i_current_qp <= dsc_flat_qp_in;
            end // if

            // register some inputs
            if (i_valid_pipe[1] == 1'b1) begin
                i_residual_zero <= (dsc_rc_size_group == 8'd3) ? 1'b1 : 1'b0;
            end // if

            if (dsc_group_valid_in == 1'b1) begin
                i_rc_size_group_edge <= dsc_rc_size_group * i_rc_edge_factor;
            end // if

            // increment value
            case (i_inc_select[1:0])
                  2'b00:    i_inc_qp_value <= (i_inc_select[2] == 1'b0) ? i_inc_qp[0] : i_inc_qp[1];
                  2'b01:    i_inc_qp_value <= (i_inc_select[3] == 1'b0) ? i_inc_qp[0] : i_inc_qp[1];
                  2'b10:    i_inc_qp_value <= (i_inc_select[4] == 1'b0) ? i_inc_qp[0] : i_inc_qp[1];
                  default:  i_inc_qp_value <= i_inc_qp[1];
            endcase

            // pipeline the valid signal (4 stages - one shorter to allow for the adjusted qp)
            i_valid_pipe <= {i_valid_pipe[1:0], dsc_group_valid_in};
            i_adjust_pipe <= {i_adjust_pipe[1:0], dsc_group_valid_in | dsc_start_of_slice};

            // determine the short term qp value
            dsc_qp_valid_out <= 1'b0;

            if (dsc_start_of_slice == 1'b1) begin
                dsc_primary_qp <= 5'd0;
            end else if (i_valid_pipe[2] == 1'b1) begin
                dsc_qp_valid_out <= 1'b1;
                dsc_primary_qp <= i_st_qp;
            end // if

        end // if
    end : ShortTermRC


    // -------------------------------------------------------
    //  logic to force MPP mode
    // -------------------------------------------------------
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : ForceMPP
        if (dsc_reset_n == 1'b0) begin
            dsc_force_mpp <= 1'b0;

        end else begin

            // ----- determine when to enable forceMpp mode ----- //
            if (i_valid_pipe[2] == 1'b1 && i_ixd_active == 1'b0) begin
                dsc_force_mpp <= 1'b0;

                if ((cfg_dsc_encoder.chunk_trailing_bits_flag == 1'b1 && i_max_chunk_bits_next_group == i_chunk_size_times_8) ||
                    (i_max_chunk_bits_next_group > i_chunk_size_times_8))  begin
                    if (i_buffer_fullness_reg < ({8'h00, cfg_dsc_encoder.max_bits_per_group} + 16'd5)) begin
                        dsc_force_mpp <= 1'b1;
                    end // if
                end else if (cfg_pps.vbr_enable == 1'b0 && i_ixd_active == 1'b0) begin
                    if (i_buffer_fullness_reg < ({8'h00, cfg_dsc_encoder.max_bits_per_group} - 16'd3)) begin
                        dsc_force_mpp <= 1'b1;
                    end // if
                end // if
            end // if

        end // if
    end : ForceMPP


    // -------------------------------------------------------
    //  locally buffer some of the PPS values
    // -------------------------------------------------------
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : ParameterBuffer
        if (dsc_reset_n == 1'b0) begin
            i_initial_scale_value <= 6'd0;
            i_initial_xmit_delay <= 10'd0;
            i_scale_decrement_interval <= 16'h0000;
            i_scale_increment_interval <= 16'h0000;
            i_slice_bpg_offset <= 16'd0;
            i_first_bpg_offset <= 5'h00;
            i_nfl_bpg_offset <= 16'h0000;
            i_second_bpg_offset <= 5'd0;
            i_second_offset_adjust <= 16'h0000;
            i_nsl_bpg_offset <= 16'h0000;
            i_initial_offset <= 16'h0000;
            i_final_offset <= 16'h0000;
            i_rc_model_size <= 16'h0000;
            i_rc_quant_incr_limit1 <= 5'd0;
            i_rc_quant_incr_limit0 <= 5'd0;
            i_rc_edge_factor <= 4'd0;
            i_slice_width <= 16'h0000;
            i_bits_per_pixel <= 10'd0;
            i_bpc_max_qp <= 5'd0;
            i_bits_per_component <= 4'd0;
            i_dsc_version_2_active <= 1'b0;
            i_chunk_size_times_8 <= 20'd0;

        end else begin

            // store PPS paramters when there is an update, local copies for timing closure
            if (dsc_pps_update == 1'b1) begin
                i_initial_scale_value <= cfg_pps.initial_scale_value;
                i_initial_xmit_delay <= cfg_pps.initial_xmit_delay;
                i_scale_decrement_interval <= {4'h0, cfg_pps.scale_decrement_interval};
                i_scale_increment_interval <= cfg_pps.scale_increment_interval;
                i_slice_bpg_offset <= cfg_pps.slice_bpg_offset;
                i_first_bpg_offset <= cfg_pps.first_line_bpg_offset;
                i_nfl_bpg_offset <= cfg_pps.nfl_bpg_offset;
                i_second_bpg_offset <= cfg_pps.second_line_bpg_offset;
                i_second_offset_adjust <= cfg_pps.second_line_offset_adj;
                i_nsl_bpg_offset <= cfg_pps.nsl_bpg_offset;
                i_initial_offset <= cfg_pps.initial_offset;
                i_final_offset <= cfg_pps.final_offset;
                i_rc_model_size <= cfg_rcps.rc_model_size;
                i_rc_quant_incr_limit1 <= cfg_rcps.rc_quant_incr_limit1;
                i_rc_quant_incr_limit0 <= cfg_rcps.rc_quant_incr_limit0;
                i_rc_edge_factor <= cfg_rcps.rc_edge_factor;
                i_slice_width <= cfg_pps.slice_width;
                i_bits_per_pixel <= cfg_pps.bits_per_pixel;
                i_bpc_max_qp <= (cfg_pps.bits_per_component == 4'h0) ? 5'd31 : {cfg_pps.bits_per_component, 1'b0} - 5'd1;
                i_bits_per_component <= cfg_pps.bits_per_component;
                i_dsc_version_2_active <= (cfg_pps.dsc_version_minor == 4'd2) ? 1'b1: 1'b0;
                i_chunk_size_times_8 <= {5'b00000, cfg_pps.chunk_size, 3'b000};
            end // if

        end // if
    end : ParameterBuffer

endmodule : dsce_rate

