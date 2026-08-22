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
//     DESCRIPTION : Flatness determination block.  The flatness determination changes
//                   both the QP value and the previous QP value to align with the way
//                   that the model operates.
//
//                   Rev 2.6 - refactored for better timing performance
// ------------------------------------------------------------------------------------------------

// ----------------------------------------------
//  includes
// ----------------------------------------------
import dsce_defs_pkg::*;


// ----------------------------------------------
//  entity declaration
// ----------------------------------------------
module dsce_flatness
(
    // clock and control interface
    input  logic            dsc_clk,                        // DSC processing clock
    input  logic            dsc_reset_n,                    // DSC domain reset
    input  logic            dsc_pps_update,                 // update pps parameters flag
    input  tDSC_PPS         cfg_pps,                        // parameter set output array
    input  logic [4:0]      cfg_rc_range_max_qp_14,         // rc range parameter for entry 14

    // quantization level
    input  tDSC_QLEVEL      dsc_primary_qp,                 // primary qp input

    // source pixel path
    input  logic            dsc_start_of_slice,             // start of slice flag
    input  logic            dsc_source_valid_in,            // valid data in
    input  logic            dsc_source_last_in,             // last group in a slice line
    input  tDSC_PIXEL       dsc_source_group_in [2:0],      // source group input

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

    logic                   i_group_valid_check;
    logic                   i_group_last_check;
    tDSC_PIXEL              i_group_check [2:0];
    tDSC_PIXEL              i_group_check_diff [2:1];
    logic                   i_group_valid_flags;
    logic                   i_group_last_flags;
    logic                   i_group_start_flags;
    logic                   i_input_start_pending;
    logic                   i_wait_previous_slice_last;
    logic                   i_seen_slice_start;
    tDSC_PIXEL              i_group_flags [2:0];
    tDSC_PIXEL              i_group_diff_flags [2:1];
    logic [3:0]             i_check_write_ptr;
    logic [3:0]             i_check_read_ptr;
    logic [4:0]             i_check_count;
    logic [1:0]             i_check_cooldown;
    logic                   i_check_last_fifo [15:0];
    logic                   i_check_start_fifo [15:0];
    tDSC_PIXEL              i_check_group_fifo [15:0][2:0];
    tDSC_PIXEL              i_check_diff_fifo [15:0][2:1];

    // flat_flags 内含依赖 RC QP 的 supergroup 判定。flat_check 在行尾可能连续
    // 产生 lookahead 结果，因此必须在判定前恢复每组四拍的反馈节奏。
    // 若在判定后节流，像素事务虽能对齐，判定采到的却仍是前一事务的 QP。
    always_ff @(posedge dsc_clk or negedge dsc_reset_n) begin : FlatCheckScheduler
        logic check_pop;

        if (!dsc_reset_n) begin
            i_group_valid_flags <= 1'b0;
            i_group_last_flags <= 1'b0;
            i_group_start_flags <= 1'b0;
            i_input_start_pending <= 1'b0;
            i_wait_previous_slice_last <= 1'b0;
            i_seen_slice_start <= 1'b0;
            i_group_flags <= '{default: kDSC_PIXEL_INIT};
            i_group_diff_flags <= '{default: kDSC_PIXEL_INIT};
            i_check_write_ptr <= 4'd0;
            i_check_read_ptr <= 4'd0;
            i_check_count <= 5'd0;
            i_check_cooldown <= 2'd0;
            i_check_last_fifo <= '{default: 1'b0};
            i_check_start_fifo <= '{default: 1'b0};
            i_check_group_fifo <= '{default: '{default: kDSC_PIXEL_INIT}};
            i_check_diff_fifo <= '{default: '{default: kDSC_PIXEL_INIT}};
        end else begin
            check_pop = (i_check_count != 0) && (i_check_cooldown == 0) &&
                (!i_check_start_fifo[i_check_read_ptr] || !i_wait_previous_slice_last);
            i_group_valid_flags <= 1'b0;
            i_group_last_flags <= 1'b0;
            i_group_start_flags <= 1'b0;

            if (dsc_start_of_slice) begin
                i_input_start_pending <= 1'b1;
                if (i_seen_slice_start)
                    i_wait_previous_slice_last <= 1'b1;
            end

            if (dsc_group_valid_out && dsc_group_last_out && i_wait_previous_slice_last)
                i_wait_previous_slice_last <= 1'b0;

            if (i_check_cooldown != 0)
                i_check_cooldown <= i_check_cooldown - 1'b1;

            if (i_group_valid_check) begin
                i_check_last_fifo[i_check_write_ptr] <= i_group_last_check;
                i_check_start_fifo[i_check_write_ptr] <= i_input_start_pending;
                i_check_group_fifo[i_check_write_ptr] <= i_group_check;
                i_check_diff_fifo[i_check_write_ptr] <= i_group_check_diff;
                i_check_write_ptr <= i_check_write_ptr + 1'b1;
                if (i_input_start_pending)
                    i_input_start_pending <= 1'b0;
            end

            if (check_pop) begin
                i_group_valid_flags <= 1'b1;
                i_group_last_flags <= i_check_last_fifo[i_check_read_ptr];
                i_group_start_flags <= i_check_start_fifo[i_check_read_ptr];
                i_group_flags <= i_check_group_fifo[i_check_read_ptr];
                i_group_diff_flags <= i_check_diff_fifo[i_check_read_ptr];
                i_check_read_ptr <= i_check_read_ptr + 1'b1;
                i_check_cooldown <= 2'd3;
                if (i_check_start_fifo[i_check_read_ptr])
                    i_seen_slice_start <= 1'b1;
            end

            case ({i_group_valid_check, check_pop})
                2'b10: i_check_count <= i_check_count + 1'b1;
                2'b01: i_check_count <= i_check_count - 1'b1;
                default: i_check_count <= i_check_count;
            endcase

            assert (!i_group_valid_check || i_check_count < 5'd16)
                else $error("Flatness check scheduler overflow");
        end
    end


    // ------------------------------------------------------------------------------------------------------------
    //                                            components
    // ------------------------------------------------------------------------------------------------------------

    // ----- flatness checks ----- //
    dsce_flat_check  dsce_flat_check_inst
    (
        // clock and control interface
        .dsc_clk                    (dsc_clk),
        .dsc_reset_n                (dsc_reset_n),
        // source pixel path
        .dsc_start_of_slice         (dsc_start_of_slice),
        .dsc_group_valid_in         (dsc_source_valid_in),
        .dsc_group_last_in          (dsc_source_last_in),
        .dsc_group_in               (dsc_source_group_in),
        // output data path
        .dsc_group_valid_out        (i_group_valid_check),
        .dsc_group_last_out         (i_group_last_check),
        .dsc_group_out              (i_group_check),
        .dsc_check_diff_out         (i_group_check_diff)
    );


    // ----- flatness flag generation ----- //
    dsce_flat_flags  dsce_flat_flags_inst
    (
        // clock and control interface
        .dsc_clk                    (dsc_clk),
        .dsc_reset_n                (dsc_reset_n),
        .dsc_pps_update             (dsc_pps_update),
        .cfg_pps                    (cfg_pps),
        .cfg_rc_range_max_qp_14     (cfg_rc_range_max_qp_14),
        // input data path from the flatness checks
        .dsc_start_of_slice         (i_group_start_flags),
        .dsc_group_valid_in         (i_group_valid_flags),
        .dsc_group_last_in          (i_group_last_flags),
        .dsc_group_in               (i_group_flags),
        .dsc_check_diff_in          (i_group_diff_flags),
        // quantization level
        .dsc_primary_qp             (dsc_primary_qp),
        // output data path
        .dsc_group_valid_out        (dsc_group_valid_out),
        .dsc_group_last_out         (dsc_group_last_out),
        .dsc_group_out              (dsc_group_out),
        .dsc_vlc_flat_flags_out     (dsc_vlc_flat_flags_out),
        .dsc_ich_next_is_very_flat  (dsc_ich_next_is_very_flat)
    );

endmodule : dsce_flatness
