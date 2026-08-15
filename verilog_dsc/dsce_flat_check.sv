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
//     DESCRIPTION : Refactored code to perform the flatness checks on each group.  Only
//                   the Max-Min difference is calculated during this stage.  Final flatness
//                   decisions are made in the flags block.
// ------------------------------------------------------------------------------------------------

// ----------------------------------------------
//  includes
// ----------------------------------------------
import dsce_defs_pkg::*;


// ----------------------------------------------
//  entity declaration
// ----------------------------------------------
module dsce_flat_check
(
    // clock and control interface
    input   logic           dsc_clk,                        // DSC processing clock
    input   logic           dsc_reset_n,                    // DSC domain reset

    // source pixel path
    input   logic           dsc_start_of_slice,             // first group in a slice
    input   logic           dsc_group_valid_in,             // valid data in
    input   logic           dsc_group_last_in,              // last group in
    input   tDSC_PIXEL      dsc_group_in [2:0],             // source group input

    // output data path
    output  logic           dsc_group_valid_out,            // valid group pixels out
    output  logic           dsc_group_last_out,             // last group out
    output  tDSC_PIXEL      dsc_group_out [2:0],            // group output
    output  tDSC_PIXEL      dsc_check_diff_out [2:1]        // differences over the check 1,2 pixels
);

    // ------------------------------------------------------------------------------------------------------------
    //                                          internal definitions
    // ------------------------------------------------------------------------------------------------------------

    // ----- pipeline control signals ----- //
    enum {
        eSTAGE_IDLE,
        eSTAGE_ACTIVE,
        eSTAGE_LAST,
        eSTAGE_FLUSH
    } i_stage_state [3:1];

    tDSC_PIXEL              i_group_in [2:0];
    logic   [1:0]           i_group_valid;
    logic                   i_flush_last_group;
    tDSC_PIXEL              i_left_pixel;
    tDSC_PIXEL              i_current_group [2:0];
    logic                   i_current_group_valid;

    // ----- flatness check signals ----- //
    tDSC_PIXEL              i_group_min;
    tDSC_PIXEL              i_group_max;
    tDSC_PIXEL              i_current_min;
    tDSC_PIXEL              i_current_max;
    tDSC_PIXEL              i_group_min_check_1;
    tDSC_PIXEL              i_group_max_check_1;
    tDSC_PIXEL              i_group_min_check_2;
    tDSC_PIXEL              i_group_max_check_2;


    // ------------------------------------------------------------------------------------------------------------
    //                                             processes
    // ------------------------------------------------------------------------------------------------------------

    // signal assignments
    always_comb begin : SignalMap
        // pad the group to the right of the active slice
        i_group_in = (i_flush_last_group == 1'b0) ? dsc_group_in : '{default: i_current_group[2]};
    end : SignalMap


    // -------------------------------------------------------
    //  Group data pipelining
    // -------------------------------------------------------
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : GroupPipe
        if (dsc_reset_n == 1'b0) begin
            i_group_valid <= 2'b00;

        end else begin

            // ----- reset flags at the start of the slice ----- //
            if (dsc_start_of_slice == 1'b1) begin
                i_group_valid <= 2'b00;
            end else if (dsc_group_valid_in == 1'b1) begin
                i_group_valid <= {i_group_valid[1:0], 1'b1};
            end // if

        end // if
    end : GroupPipe


    // -------------------------------------------------------
    //  Flatness min/max calculations for inbound group
    // -------------------------------------------------------
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : FlatMinMax
        if (dsc_reset_n == 1'b0) begin
            dsc_group_valid_out <= 1'b0;
            dsc_group_last_out <= 1'b0;
            dsc_group_out <= '{default: kDSC_PIXEL_INIT};
            dsc_check_diff_out <= '{default: kDSC_PIXEL_INIT};

            i_group_min <= kDSC_PIXEL_INIT;
            i_group_max <= kDSC_PIXEL_INIT;
            i_current_group_valid <= 1'b0;
            i_current_group <= '{default: kDSC_PIXEL_INIT};
            i_left_pixel <= kDSC_PIXEL_INIT;
            i_current_min  <= kDSC_PIXEL_INIT;
            i_current_max  <= kDSC_PIXEL_INIT;
            i_group_min_check_1 <= kDSC_PIXEL_INIT;
            i_group_max_check_1 <= kDSC_PIXEL_INIT;
            i_group_min_check_2 <= kDSC_PIXEL_INIT;
            i_group_max_check_2 <= kDSC_PIXEL_INIT;
            i_flush_last_group <= 1'b0;
            i_stage_state <= '{default: eSTAGE_IDLE};

        end else begin

            // ----- default signal values ----- //
            dsc_group_valid_out <= 1'b0;
            dsc_group_last_out <= 1'b0;
            i_flush_last_group <= 1'b0;
            i_stage_state <= '{default: eSTAGE_IDLE};

            // ----- stage 0, group valid ----- //
            if (dsc_group_valid_in == 1'b1 || i_flush_last_group == 1'b1) begin
                if (dsc_group_last_in == 1'b1) begin
                    i_stage_state[1] <= eSTAGE_LAST;
                end else if (i_flush_last_group == 1'b1) begin
                    i_stage_state[1] <= eSTAGE_FLUSH;
                end else begin
                    i_stage_state[1] <= eSTAGE_ACTIVE;
                end // if

                i_group_min.y  <= dsce_min_3(i_group_in[0].y,  i_group_in[1].y,  i_group_in[2].y);
                i_group_min.co <= dsce_min_3(i_group_in[0].co, i_group_in[1].co, i_group_in[2].co);
                i_group_min.cg <= dsce_min_3(i_group_in[0].cg, i_group_in[1].cg, i_group_in[2].cg);

                i_group_max.y  <= dsce_max_3(i_group_in[0].y,  i_group_in[1].y,  i_group_in[2].y);
                i_group_max.co <= dsce_max_3(i_group_in[0].co, i_group_in[1].co, i_group_in[2].co);
                i_group_max.cg <= dsce_max_3(i_group_in[0].cg, i_group_in[1].cg, i_group_in[2].cg);
            end // if

            // ----- stage 1 ----- //
            if (i_stage_state[1] != eSTAGE_IDLE) begin
                i_stage_state[2] <= i_stage_state[1];

                if (i_current_group_valid == 1'b1) begin
                    i_group_min_check_1.y  <= dsce_min_2(i_current_min.y,  i_left_pixel.y);
                    i_group_min_check_1.co <= dsce_min_2(i_current_min.co, i_left_pixel.co);
                    i_group_min_check_1.cg <= dsce_min_2(i_current_min.cg, i_left_pixel.cg);

                    i_group_max_check_1.y  <= dsce_max_2(i_current_max.y,  i_left_pixel.y);
                    i_group_max_check_1.co <= dsce_max_2(i_current_max.co, i_left_pixel.co);
                    i_group_max_check_1.cg <= dsce_max_2(i_current_max.cg, i_left_pixel.cg);

                    i_group_min_check_2.y  <= dsce_min_2(i_group_min.y,  i_current_min.y);
                    i_group_min_check_2.co <= dsce_min_2(i_group_min.co, i_current_min.co);
                    i_group_min_check_2.cg <= dsce_min_2(i_group_min.cg, i_current_min.cg);

                    i_group_max_check_2.y  <= dsce_max_2(i_group_max.y,  i_current_max.y);
                    i_group_max_check_2.co <= dsce_max_2(i_group_max.co, i_current_max.co);
                    i_group_max_check_2.cg <= dsce_max_2(i_group_max.cg, i_current_max.cg);
                end else begin
                    i_group_min_check_1 <= '{default: 16'h0000};
                    i_group_max_check_1 <= '{default: 16'hffff};
                    i_group_min_check_2 <= '{default: 16'h0000};
                    i_group_max_check_2 <= '{default: 16'hffff};
                end // if
            end // if

            // ----- stage 2 ----- //
            if (i_stage_state[2] != eSTAGE_IDLE) begin
                i_stage_state[3] <= i_stage_state[2];
            end // if

            // ----- stage 3 ----- //
            if (i_stage_state[3] != eSTAGE_IDLE) begin
                // move the input group to the saved group
                if (i_stage_state[3] == eSTAGE_FLUSH) begin
                    i_left_pixel <= kDSC_PIXEL_INIT;
                    i_current_group <= '{default: kDSC_PIXEL_INIT};
                    i_current_min <= kDSC_PIXEL_INIT;
                    i_current_max <= kDSC_PIXEL_INIT;
                    i_current_group_valid <= 1'b0;
                end else begin
                    i_left_pixel <= (i_current_group_valid == 1'b1) ? i_current_group[2] : i_group_in[0];
                    i_current_group <= i_group_in;
                    i_current_min <= i_group_min;
                    i_current_max <= i_group_max;
                    i_current_group_valid <= 1'b1;
                end // if

                // output the saved group
                if (i_current_group_valid == 1'b1) begin
                    dsc_group_valid_out <= 1'b1;
                    dsc_group_last_out <= (i_stage_state[3] == eSTAGE_FLUSH) ? 1'b1 : 1'b0;
                    dsc_group_out <= i_current_group;
                    dsc_check_diff_out[1] <= i_group_max_check_1 - i_group_min_check_1;
                    dsc_check_diff_out[2] <= i_group_max_check_2 - i_group_min_check_2;
                end // if

                // flush the last group from the internal buffer
                if (i_stage_state[3] == eSTAGE_LAST) begin
                    i_flush_last_group <= 1'b1;
                end // if
            end // if
        end // if
    end : FlatMinMax

endmodule : dsce_flat_check

