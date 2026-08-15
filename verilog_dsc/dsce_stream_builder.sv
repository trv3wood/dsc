// ------------------------------------------------------------------------------------------------
//     COPYRIGHT © 2022-2023, TRILINEAR TECHNOLOGIES, INC.
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
//     DESCRIPTION : DSC encoder output format buffer and flow control.
// ------------------------------------------------------------------------------------------------

// ----------------------------------------------
//  includes
// ----------------------------------------------
import dsce_defs_pkg::*;


// ----------------------------------------------
//  entity declaration
// ----------------------------------------------
module dsce_stream_builder
(
    // clock and control interface
    input  logic                    dsc_clk,                        // DSC processing clock
    input  logic                    dsc_reset_n,                    // DSC domain reset
    input  logic [3:0]              cfg_bits_per_component,         // stream bpc
    input  logic                    cfg_convert_rgb,                // color conversion setting

    // input path from muxword builder
    input  logic                    dsc_start_of_slice,             // start of slice flag
    input  logic [2:0]              dsc_muxword_valid_in,           // MUX word valid input
    input  logic [2:0]              dsc_muxword_last_in,            // MUX word last flag input
    input  logic [63:0]             dsc_muxword_in [2:0],           // MUX word

    // syntax size input from VLC
    input  logic [2:0]              dsc_unit_size_valid_in,         // valid unit size in
    input  logic [2:0]              dsc_unit_size_last_in,          // last group in
    input  logic [5:0]              dsc_coded_unit_size [2:0],      // size of the current unit within a group

    // output to the format buffer
    output logic                    dsc_muxword_valid_out,          // output muxword is valid
    output logic                    dsc_muxword_last_out,           // last muxword in a chunk
    output logic [63:0]             dsc_muxword_out                 // muxword output
);

    // ------------------------------------------------------------------------------------------------------------
    //                                          internal definitions
    // ------------------------------------------------------------------------------------------------------------

    // ----- buffer connections ----- //
    logic [2:0]                     i_syntax_valid;
    logic                           i_syntax_ready;
    logic [2:0]                     i_syntax_last;
    logic [5:0]                     i_syntax_size [2:0];

    logic [2:0]                     i_muxword_valid;
    logic [2:0]                     i_muxword_ready;
    logic [2:0]                     i_muxword_last;
    logic [63:0]                    i_muxword [2:0];

    // ----- transfer tracking ----- //
    logic [6:0]                     i_fullness [2:0];

    // ----- transfer state machine ----- //
    enum {
        eBS_INIT,
        eBS_CHECK_COUNTERS,
        eBS_UPDATE_COUNTERS,
        eBS_WAIT_MUXWORD_AVAIL,
        eBS_TRANSFER_MUXWORD
    } i_builder_state;

    logic [1:0]                     i_muxword_tx_select;
    logic [2:0]                     i_send_muxword;
    logic [6:0]                     i_muxword_size;
    logic [6:0]                     i_max_syntax_size [1:0];


    // ------------------------------------------------------------------------------------------------------------
    //                                             processes
    // ------------------------------------------------------------------------------------------------------------

    // signal assignments
    always_comb begin : SignalMap
        case (cfg_bits_per_component)
            4'd0:  begin
                i_max_syntax_size[0] = 7'd64;
                i_max_syntax_size[1] = 7'd64;
                i_muxword_size = 7'd64;
            end // 16bpc

            4'd14:  begin
                i_max_syntax_size[0] = 7'd60;
                i_max_syntax_size[1] = (cfg_convert_rgb == 1'b1) ? 7'd60 : 7'd56;
                i_muxword_size = 7'd64;
            end // 14 bpc

            4'd12:  begin
                i_max_syntax_size[0] = 7'd52;
                i_max_syntax_size[1] = (cfg_convert_rgb == 1'b1) ? 7'd52 : 7'd48;
                i_muxword_size = 7'd64;
            end // 12 bpc

            4'd10:  begin
                i_max_syntax_size[0] = 7'd44;
                i_max_syntax_size[1] = (cfg_convert_rgb == 1'b1) ? 7'd44 : 7'd40;
                i_muxword_size = 7'd48;
            end // 10 bpc

            default:  begin
                i_max_syntax_size[0] = 7'd36;
                i_max_syntax_size[1] = (cfg_convert_rgb == 1'b1) ? 7'd36 : 7'd32;
                i_muxword_size = 7'd48;
            end // default is 8
        endcase

        i_send_muxword[0] = (i_fullness[0] < i_max_syntax_size[0]) ? 1'b1 : 1'b0;
        i_send_muxword[1] = (i_fullness[1] < i_max_syntax_size[1]) ? 1'b1 : 1'b0;
        i_send_muxword[2] = (i_fullness[2] < i_max_syntax_size[1]) ? 1'b1 : 1'b0;
    end : SignalMap


    // ------------------------------------------------------
    //   output tracking counters and state machine
    // ------------------------------------------------------
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : OutputOrdering
        if (dsc_reset_n == 1'b0) begin
            dsc_muxword_valid_out <= 1'b0;
            dsc_muxword_last_out <= 1'b0;
            dsc_muxword_out <= 64'd0;

            i_builder_state <= eBS_INIT;
            i_muxword_ready <= 3'b000;
            i_syntax_ready <= 1'b0;
            i_fullness <= '{default: 7'd0};
            i_muxword_tx_select <= 2'd0;

        end else begin

            dsc_muxword_valid_out <= 1'b0;
            i_muxword_ready <= 3'b000;
            i_syntax_ready <= 1'b0;

            if (dsc_start_of_slice == 1'b1) begin
                i_builder_state <= eBS_INIT;
                i_muxword_tx_select <= 2'd0;
            end else begin

                case (i_builder_state)
                    eBS_INIT:  begin
                        i_fullness <= '{default: 7'd0};
                        i_builder_state <= eBS_CHECK_COUNTERS;
                    end // eBS_INIT

                    eBS_CHECK_COUNTERS:  begin
                        case (i_send_muxword)
                            3'b001, 3'b011, 3'b111, 3'b101:  begin
                                i_builder_state <= eBS_WAIT_MUXWORD_AVAIL;
                                i_muxword_tx_select <= 2'd0;
                            end // y ready

                            3'b010, 3'b110:  begin
                                i_builder_state <= eBS_WAIT_MUXWORD_AVAIL;
                                i_muxword_tx_select <= 2'd1;
                            end // co ready

                            3'b100:  begin
                                i_builder_state <= eBS_WAIT_MUXWORD_AVAIL;
                                i_muxword_tx_select <= 2'd2;
                            end // cg ready

                            default:  begin
                                if (i_syntax_valid == 3'b111) begin
                                    i_syntax_ready <= 1'b1;
                                    i_builder_state <= eBS_UPDATE_COUNTERS;
                                end // if
                            end // no muxword ready
                        endcase
                    end // eBS_CHECK_COUNTERS

                    eBS_UPDATE_COUNTERS:  begin
                        i_fullness[0] <= i_fullness[0] - i_syntax_size[0];
                        i_fullness[1] <= i_fullness[1] - i_syntax_size[1];
                        i_fullness[2] <= i_fullness[2] - i_syntax_size[2];
                        i_builder_state <= eBS_CHECK_COUNTERS;
                    end // eBS_UPDATE_COUNTERS

                    eBS_WAIT_MUXWORD_AVAIL:  begin
                        if (i_muxword_valid[i_muxword_tx_select] == 1'b1) begin
                            i_builder_state <= eBS_TRANSFER_MUXWORD;
                            i_muxword_ready[i_muxword_tx_select] <= 1'b1;
                        end // if
                    end // eBS_WAIT_MUXWORD_AVAIL

                    eBS_TRANSFER_MUXWORD:  begin
                        dsc_muxword_valid_out <= 1'b1;
                        i_builder_state <= eBS_CHECK_COUNTERS;

                        case (i_muxword_tx_select)
                            2'd2:  begin
                                dsc_muxword_out <= i_muxword[2];
                                i_fullness[2] <= i_fullness[2] + i_muxword_size;
                            end // cg
                            2'd1:  begin
                                dsc_muxword_out <= i_muxword[1];
                                i_fullness[1] <= i_fullness[1] + i_muxword_size;
                            end // co
                            default:  begin
                                dsc_muxword_out <= i_muxword[0];
                                i_fullness[0] <= i_fullness[0] + i_muxword_size;
                            end // co
                        endcase
                    end // eBS_TRANSFER_MUXWORD

                    // default for synthesis only
                    default:  begin
                        i_builder_state <= eBS_INIT;
                        i_muxword_tx_select <= 2'd0;
                    end // default

                endcase

            end // if

        end // if
    end : OutputOrdering


    // ------------------------------------------------------
    //   syntax and muxword buffers
    // ------------------------------------------------------
    generate for (genvar gx = 0; gx < 3; gx++) begin : gen_buffers
        dsce_stream_fifo  dsce_stream_fifo_inst
        (
            // clock and control interface
            .dsc_clk                    (dsc_clk),
            .dsc_reset_n                (dsc_reset_n),
            // input path from muxword builder
            .dsc_start_of_slice         (dsc_start_of_slice),
            .dsc_muxword_valid_in       (dsc_muxword_valid_in[gx]),
            .dsc_muxword_last_in        (dsc_muxword_last_in[gx]),
            .dsc_muxword_in             (dsc_muxword_in[gx]),
            // syntax size input from VLC
            .dsc_unit_size_valid_in     (dsc_unit_size_valid_in[gx]),
            .dsc_unit_size_last_in      (dsc_unit_size_last_in[gx]),
            .dsc_coded_unit_size_in     (dsc_coded_unit_size[gx]),
            // output to the stream builder
            .dsc_coded_size_valid_out   (i_syntax_valid[gx]),
            .dsc_coded_size_ready_out   (i_syntax_ready),
            .dsc_coded_size_last_out    (i_syntax_last[gx]),
            .dsc_coded_size_out         (i_syntax_size[gx]),
            .dsc_muxword_valid_out      (i_muxword_valid[gx]),
            .dsc_muxword_ready_out      (i_muxword_ready[gx]),
            .dsc_muxword_last_out       (i_muxword_last[gx]),
            .dsc_muxword_out            (i_muxword[gx])
        );
    end endgenerate

endmodule : dsce_stream_builder

