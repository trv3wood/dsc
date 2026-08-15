// ------------------------------------------------------------------------------------------------
//     COPYRIGHT © 2015-2022, TRILINEAR TECHNOLOGIES, INC.
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
//     DESCRIPTION : DSC encoder word multiplexing logic
// ------------------------------------------------------------------------------------------------

// ----------------------------------------------
//  includes
// ----------------------------------------------
import dsce_defs_pkg::*;


// ----------------------------------------------
//  entity declaration
// ----------------------------------------------
module dsce_muxword
(
    // clock and control interface
    input  logic                    dsc_clk,                // DSC processing clock
    input  logic                    dsc_reset_n,            // DSC domain reset
    input  logic                    dsc_pps_update,         // update pps parameters flag
    input  tDSC_PPS                 cfg_pps,                // parameter set output array
    input  logic                    dsc_start_of_slice,     // start of slice flag

    // input stream from VLC
    input  logic                    dsc_vlc_valid_in,       // valid data in
    input  logic                    dsc_vlc_last_in,        // last group in
    input  logic [15:0]             dsc_stream_data_in,     // data input
    input  logic [4:0]              dsc_stream_size_in,     // size of the current data

    // output mux word
    output logic                    dsc_muxword_valid_out,  // valid predicted pixels out
    output logic [63:0]             dsc_muxword_out         // mux word out (48 or 64)
);

    // ------------------------------------------------------------------------------------------------------------
    //                                          internal definitions
    // ------------------------------------------------------------------------------------------------------------
    localparam int kUSE_FLUSH_LOGIC = 0;

    logic                           i_mux64_mode;
    logic [6:0]                     i_max_bits_per_word;
    logic [6:0]                     i_bits_in_word, i_bits_in_next_word;
    logic                           i_word_complete;
    logic [63:0]                    i_mux_buffer;

    logic [15:0]                    i_input_data;
    logic [63:0]                    i_input_word;
    logic [4:0]                     i_input_shift_amount;

    logic [63:0]                    i_remainder_word;
    logic [4:0]                     i_remainder_shift_amount;
    logic [63:0]                    i_output_word;

    logic                           i_muxword_staging_valid;
    logic [63:0]                    i_muxword_staging;
    logic                           i_muxword_flush;


    // ------------------------------------------------------------------------------------------------------------
    //                                             processes
    // ------------------------------------------------------------------------------------------------------------

    // ----------------------------------------------
    //  signal assignments
    // ----------------------------------------------
    always_comb begin : SignalMap
        // ----- tracking calculations ----- //
        i_mux64_mode = (cfg_pps.bits_per_component == 4'd8 || cfg_pps.bits_per_component == 4'd10) ? 1'b0 : 1'b1;
        i_bits_in_next_word = i_bits_in_word + {2'b00, dsc_stream_size_in};
        i_word_complete = (i_bits_in_next_word >= i_max_bits_per_word) ? 1'b1 : 1'b0;

        // ----- remainder path, end of complete word ----- //
        i_remainder_shift_amount = (i_word_complete == 1'b0) ? 5'd0 : (i_bits_in_next_word - i_max_bits_per_word);

        case (i_remainder_shift_amount)
            5'd1:       i_remainder_word = {63'd0, dsc_stream_data_in[0]};
            5'd2:       i_remainder_word = {62'd0, dsc_stream_data_in[1:0]};
            5'd3:       i_remainder_word = {61'd0, dsc_stream_data_in[2:0]};
            5'd4:       i_remainder_word = {60'd0, dsc_stream_data_in[3:0]};
            5'd5:       i_remainder_word = {59'd0, dsc_stream_data_in[4:0]};
            5'd6:       i_remainder_word = {58'd0, dsc_stream_data_in[5:0]};
            5'd7:       i_remainder_word = {57'd0, dsc_stream_data_in[6:0]};
            5'd8:       i_remainder_word = {56'd0, dsc_stream_data_in[7:0]};
            5'd9:       i_remainder_word = {55'd0, dsc_stream_data_in[8:0]};
            default:    i_remainder_word = 64'd0;
        endcase

        // ----- input data path ----- //
        i_input_data = dsc_stream_data_in >> i_remainder_shift_amount;
        i_input_shift_amount = (i_word_complete == 1'b0) ? dsc_stream_size_in : (i_max_bits_per_word - i_bits_in_word);

        case (i_input_shift_amount)
            5'd1:       i_input_word = {i_mux_buffer[62:0], i_input_data[0]};
            5'd2:       i_input_word = {i_mux_buffer[61:0], i_input_data[1:0]};
            5'd3:       i_input_word = {i_mux_buffer[60:0], i_input_data[2:0]};
            5'd4:       i_input_word = {i_mux_buffer[59:0], i_input_data[3:0]};
            5'd5:       i_input_word = {i_mux_buffer[58:0], i_input_data[4:0]};
            5'd6:       i_input_word = {i_mux_buffer[57:0], i_input_data[5:0]};
            5'd7:       i_input_word = {i_mux_buffer[56:0], i_input_data[6:0]};
            5'd8:       i_input_word = {i_mux_buffer[55:0], i_input_data[7:0]};
            5'd9:       i_input_word = {i_mux_buffer[54:0], i_input_data[8:0]};
            default:    i_input_word = i_mux_buffer;
        endcase

        // ----- output data path ----- //
        if (i_mux64_mode == 1'b0) begin
            i_output_word[63:48] = 16'h0000;
            i_output_word[47:0] = {i_input_word[7:0],   i_input_word[15:8], i_input_word[23:16], i_input_word[31:24],
                                   i_input_word[39:32], i_input_word[47:40]};
        end else begin
            i_output_word = {i_input_word[7:0],   i_input_word[15:8],  i_input_word[23:16], i_input_word[31:24],
                             i_input_word[39:32], i_input_word[47:40], i_input_word[55:48], i_input_word[63:56]};
        end // if
    end : SignalMap


    // ----------------------------------------------
    //  MuxWord packing registers
    // ----------------------------------------------
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : WordPacking
        if (dsc_reset_n == 1'b0) begin
            dsc_muxword_valid_out <= 1'b0;
            dsc_muxword_out <= 64'd0;

            i_mux_buffer <= 64'd0;
            i_max_bits_per_word <= 7'd0;
            i_bits_in_word <= 7'd0;

            i_muxword_staging_valid <= 1'b0;
            i_muxword_staging <= 64'd0;
            i_muxword_flush <= 1'b0;

        end else begin

            // --------------------------------------
            //  muxword size selection
            // --------------------------------------
            if (dsc_pps_update == 1'b1) begin
                i_max_bits_per_word <= (i_mux64_mode == 1'b1) ? 7'd64 : 7'd48;
            end // if

            // --------------------------------------
            //  packing and forwarding
            // --------------------------------------
            dsc_muxword_valid_out <= 1'b0;
            i_muxword_staging_valid <= 1'b0;

            if (dsc_pps_update == 1'b1) begin
                i_muxword_staging_valid <= 1'b0;
                i_bits_in_word <= 7'd0;
            end else if (dsc_vlc_valid_in == 1'b1) begin
                if (kUSE_FLUSH_LOGIC == 1) begin
                    if (i_word_complete == 1'b1 || dsc_vlc_last_in == 1'b1) begin
                        i_muxword_staging_valid <= 1'b1;
                        i_muxword_staging <= i_output_word;
                        i_mux_buffer <= i_remainder_word;
                        i_bits_in_word <= (dsc_vlc_last_in == 1'b1) ? 7'd0 : i_bits_in_next_word - i_max_bits_per_word;

                        if (i_word_complete == 1'b1 && dsc_vlc_last_in == 1'b1 && i_bits_in_next_word != i_max_bits_per_word) begin
                            i_muxword_flush <= 1'b1;
                        end // if
                    end else begin
                        i_muxword_staging_valid <= 1'b0;
                        i_mux_buffer <= i_input_word;
                        i_bits_in_word <= i_bits_in_next_word;
                    end // if
                end else begin
                    i_muxword_flush <= 1'b0;

                    if (i_word_complete == 1'b1) begin
                        i_muxword_staging_valid <= 1'b1;
                        i_muxword_staging <= i_output_word;
                        i_mux_buffer <= i_remainder_word;
                        i_bits_in_word <= i_bits_in_next_word - i_max_bits_per_word;
                    end else begin
                        i_muxword_staging_valid <= 1'b0;
                        i_mux_buffer <= i_input_word;
                        i_bits_in_word <= i_bits_in_next_word;
                    end // if
                end // if
            end else if (i_muxword_flush == 1'b1) begin
                i_muxword_flush <= 1'b0;
                i_muxword_staging_valid <= 1'b1;
                i_muxword_staging <= i_mux_buffer;
                i_bits_in_word <= 7'd0;
            end // if

            // --------------------------------------
            //  output muxwords on a group boundary
            // --------------------------------------

            // ----- staging output ----- //
            if (dsc_pps_update == 1'b1) begin
                dsc_muxword_valid_out <= 1'b0;
            end else begin
                if (i_muxword_staging_valid == 1'b1) begin
                    dsc_muxword_valid_out <= 1'b1;
                    dsc_muxword_out <= i_muxword_staging;
                end else begin
                    dsc_muxword_valid_out <= 1'b0;
                end // if
            end // if

        end // if
    end : WordPacking

endmodule : dsce_muxword

