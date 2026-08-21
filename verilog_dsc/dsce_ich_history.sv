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
module dsce_ich_history
(
    // clock and control interface
    input  logic                    dsc_clk,                        // DSC processing clock
    input  logic                    dsc_reset_n,                    // DSC domain reset

    // slice control signals
    input  logic                    dsc_start_of_slice,             // start of the current slice
    input  logic                    dsc_start_of_slice_line,        // start of slice line indicator

    // original pixel input path
    input  logic                    dsc_group_valid_in,             // valid original data in
    input  logic                    dsc_group_last_in,              // last group in the slice
    input  tDSC_PIXEL               dsc_group_in [2:0],             // current source group
    input  tDSC_PIXEL               dsc_line_prev_in [6:0],         // pixels from the previous line

    // reconstructed pixel input
    input  logic                    dsc_update_valid_in,            // reconstructed update valid in
    input  logic                    dsc_update_last_in,             // reconstructed update last group flag
    input  logic                    dsc_ich_selected_in,            // use ICH instead of predicted
    input  tDSC_ICH_INDEX           dsc_ich_index_in [2:0],         // ICH index values
    input  tDSC_PIXEL               dsc_recon_group_in [2:0],       // reconstructed group in

    // ich history output
    output logic [31:0]             dsc_ich_entry_valid_out,        // ICH entry valid flag
    output tDSC_PIXEL               dsc_ich_entry_out [31:0]        // ICH pixel values
);

    // ------------------------------------------------------------------------------------------------------------
    //                                          internal definitions
    // ------------------------------------------------------------------------------------------------------------

    logic                           i_first_line;
    tDSC_PIXEL                      i_ich_entry_buffer [31:0];
    logic   [31:0]                  i_ich_entry_valid;
    tDSC_PIXEL                      i_ich_mode_entry_next [31:0];
    logic   [31:0]                  i_ich_mode_valid_next;
    tDSC_PIXEL                      i_line_prev_in [6:0];
    logic                           i_update_valid_in;

    logic   [2:0]                   i_unique_ich_index;
    logic   [2:0]                   i_index_lt_flags_minus_3 [31:3];
    logic   [2:0]                   i_index_lt_flags_minus_2 [31:3];
    logic   [2:0]                   i_index_lt_flags_minus_1 [31:3];
    logic   [2:0]                   i_target_codes [31:3];

    tDSC_ICH_INDEX                  i_index_minus_3, i_index_minus_2, i_index_minus_1;

    int group_number;

    // ------------------------------------------------------------------------------------------------------------
    //                                             processes
    // ------------------------------------------------------------------------------------------------------------

    // -------------------------------------------------------
    //  ICH buffer output
    // -------------------------------------------------------
    always_comb  begin : OutputSelect
        dsc_ich_entry_out[24:0] = i_ich_entry_buffer[24:0];
        dsc_ich_entry_valid_out[24:0] = i_ich_entry_valid[24:0];

        if (i_first_line == 1'b0) begin
            dsc_ich_entry_out[31:25] = i_line_prev_in[6:0];
            dsc_ich_entry_valid_out[31:25] = '{default: 1'b1};
        end else begin
            dsc_ich_entry_out[31:25] = i_ich_entry_buffer[31:25];
            dsc_ich_entry_valid_out[31:25] = i_ich_entry_valid[31:25];
        end // if

        // do not update on the last group of the line
        i_update_valid_in = dsc_update_valid_in & ~dsc_update_last_in;
    end : OutputSelect


    // -------------------------------------------------------
    //  ICH mode update processing
    // -------------------------------------------------------
    always_comb  begin : ICHModeUpdateLogic
        i_unique_ich_index[2] = 1'b1;
        i_unique_ich_index[1] = (dsc_ich_index_in[1] == dsc_ich_index_in[2]) ? 1'b0 : 1'b1;
        i_unique_ich_index[0] = (dsc_ich_index_in[0] == dsc_ich_index_in[1] || dsc_ich_index_in[0] == dsc_ich_index_in[2]) ? 1'b0 : 1'b1;

        for (int ix = 3; ix < 32; ix++) begin : TargetCodeLoop
            i_index_minus_3 = ix - 3;   i_index_minus_2 = ix - 2;   i_index_minus_1 = ix - 1;

            i_index_lt_flags_minus_3[ix][2] = (i_index_minus_3 < dsc_ich_index_in[2]) ? 1'b1 : 1'b0;
            i_index_lt_flags_minus_3[ix][1] = (i_index_minus_3 < dsc_ich_index_in[1] && i_unique_ich_index[1] == 1'b1) ? 1'b1 : 1'b0;
            i_index_lt_flags_minus_3[ix][0] = (i_index_minus_3 < dsc_ich_index_in[0] && i_unique_ich_index[0] == 1'b1) ? 1'b1 : 1'b0;

            i_index_lt_flags_minus_2[ix][2] = (i_index_minus_2 < dsc_ich_index_in[2]) ? 1'b1 : 1'b0;
            i_index_lt_flags_minus_2[ix][1] = (i_index_minus_2 < dsc_ich_index_in[1] && i_unique_ich_index[1] == 1'b1) ? 1'b1 : 1'b0;
            i_index_lt_flags_minus_2[ix][0] = (i_index_minus_2 < dsc_ich_index_in[0] && i_unique_ich_index[0] == 1'b1) ? 1'b1 : 1'b0;

            i_index_lt_flags_minus_1[ix][2] = (i_index_minus_1 < dsc_ich_index_in[2]) ? 1'b1 : 1'b0;
            i_index_lt_flags_minus_1[ix][1] = (i_index_minus_1 < dsc_ich_index_in[1] && i_unique_ich_index[1] == 1'b1) ? 1'b1 : 1'b0;
            i_index_lt_flags_minus_1[ix][0] = (i_index_minus_1 < dsc_ich_index_in[0] && i_unique_ich_index[0] == 1'b1) ? 1'b1 : 1'b0;

            if (i_index_lt_flags_minus_3[ix] == 3'b111) begin
                i_target_codes[ix] = 3'b100;
            end else if (i_index_lt_flags_minus_2[ix] == 3'b011 || i_index_lt_flags_minus_2[ix] == 3'b110 || i_index_lt_flags_minus_2[ix] == 3'b101) begin
                i_target_codes[ix] = 3'b010;
            end else if (i_index_lt_flags_minus_1[ix] == 3'b100 || i_index_lt_flags_minus_1[ix] == 3'b010 || i_index_lt_flags_minus_1[ix] == 3'b001) begin
                i_target_codes[ix] = 3'b001;
            end else begin
                i_target_codes[ix] = 3'b000;
            end // if
        end : TargetCodeLoop
    end : ICHModeUpdateLogic

    // 官方模型对 ICH 组的三个重建像素按光栅顺序逐个执行 move-to-front。
    // 仅 0..24 属于可更新历史；25..31 是上一行的动态候选，不参与去重。
    always_comb begin : ICHMoveToFront
        i_ich_mode_entry_next = i_ich_entry_buffer;
        i_ich_mode_valid_next = i_ich_entry_valid;

        for (int px = 0; px < 3; px++) begin
            int move_loc;
            logic found_loc;

            move_loc = 24;
            found_loc = 1'b0;
            for (int hx = 0; hx < 25; hx++) begin
                if (!found_loc && !i_ich_mode_valid_next[hx]) begin
                    move_loc = hx;
                    found_loc = 1'b1;
                end else if (!found_loc && i_ich_mode_valid_next[hx] &&
                             i_ich_mode_entry_next[hx] == dsc_recon_group_in[px]) begin
                    move_loc = hx;
                    found_loc = 1'b1;
                end
            end

            for (int hx = 24; hx > 0; hx--) begin
                if (hx <= move_loc) begin
                    i_ich_mode_entry_next[hx] = i_ich_mode_entry_next[hx-1];
                    i_ich_mode_valid_next[hx] = i_ich_mode_valid_next[hx-1];
                end
            end
            i_ich_mode_entry_next[0] = dsc_recon_group_in[px];
            i_ich_mode_valid_next[0] = 1'b1;
        end
    end


    // -------------------------------------------------------
    //  Input source pixel staging for pipeline timing
    // -------------------------------------------------------
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : HistoryBuffer
        if (dsc_reset_n == 1'b0) begin
            i_first_line <= 1'b1;
            i_line_prev_in <= '{default: kDSC_PIXEL_INIT};
            i_ich_entry_buffer <= '{default: kDSC_PIXEL_INIT};
            i_ich_entry_valid <= '{default: 1'b0};

            group_number = 0;

        end else begin

            if (dsc_start_of_slice == 1'b1) begin
                group_number = 0;
            end else if (dsc_group_valid_in == 1'b1) begin
                group_number++;
            end // if

            // ----- detect the first line of processing ----- //
            if (dsc_start_of_slice == 1'b1) begin
                i_first_line <= 1'b1;
            end else if (dsc_group_valid_in == 1'b1 && dsc_group_last_in == 1'b1) begin
                i_first_line <= 1'b0;
            end // if

            // ----- local copy for routing ----- //
            i_line_prev_in <= dsc_line_prev_in;

            // ----- history update logic ----- //
            for (int hix=0; hix < 32; hix++) begin : ich_update_loop
                case ({dsc_start_of_slice, i_update_valid_in, dsc_ich_selected_in}) inside
                    [3'b100:3'b111] : begin
                        i_ich_entry_valid[hix] <= 1'b0;
                    end // SliceReset

                    3'b010 : begin : PredictModeUpdate
                        case (hix) inside
                            2:  begin
                                i_ich_entry_buffer[0] <= dsc_recon_group_in[2];
                                i_ich_entry_valid[0] <= 1'b1;
                            end // last group entry

                            1:  begin
                                i_ich_entry_buffer[1] <= dsc_recon_group_in[1];
                                i_ich_entry_valid[1] <= 1'b1;
                            end // middle group entry

                            0:  begin
                                i_ich_entry_buffer[2] <= dsc_recon_group_in[0];
                                i_ich_entry_valid[2] <= 1'b1;
                            end // first group entry

                            default:  begin
                                i_ich_entry_buffer[hix] <= i_ich_entry_buffer[hix-3];
                                i_ich_entry_valid[hix] <= i_ich_entry_valid[hix-3];
                            end // all other entries
                        endcase
                    end : PredictModeUpdate

                    3'b011 : begin : ICHModeUpdate
                        i_ich_entry_buffer[hix] <= i_ich_mode_entry_next[hix];
                        i_ich_entry_valid[hix] <= i_ich_mode_valid_next[hix];
                    end : ICHModeUpdate

                    default:  ;     // no update
                endcase
            end : ich_update_loop
        end // if
    end : HistoryBuffer


endmodule : dsce_ich_history
