// ------------------------------------------------------------------------------------------------
//     COPYRIGHT © 2016-2022, TRILINEAR TECHNOLOGIES, INC.
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
//     DESCRIPTION : Slice multiplexer for the output of the encoded data.  This block now
//                   supports multiple output modes.
// ------------------------------------------------------------------------------------------------

// ----------------------------------------------
//  includes
// ----------------------------------------------
import dsce_defs_pkg::*;


// ----------------------------------------------
//  entity declaration
// ----------------------------------------------
module dsce_slice_mux
#(
    parameter int pSPC = 4                                      // number of slice processors (max = 16)
)
(
    // clock and control interface
    input  logic                        axi_clk,                // AXI input and output clock
    input  logic                        axi_reset_n,            // AXI domain reset
    input  tDSCE_CONFIG                 cfg_dsc_encoder,        // general encoder configuration
    input  logic                        axi_encoder_enable,     // sync enable for AXI domain
    input  logic                        axi_pps_update,         // okay to update pps parameters
    input  logic                        axi_new_frame,          // new frame flag

    // slice processor data path
    input  logic  [pSPC-1:0]            axi_tvalid_in,          // data is ready from the slice processor
    output logic  [pSPC-1:0]            axi_tready_in,          // ready to accept SP data
    input  logic  [pSPC-1:0]            axi_tlast_in,           // last flag
    input  logic  [pSPC-1:0] [63:0]     axi_tdata_in,           // muxword input (1 from each slice processor)

    // streaming output data path
    output logic                        axi_tframe_out,         // frame flag
    output logic                        axi_tline_out,          // end of line flag
    output logic                        axi_tvalid_out,         // valid data
    input  logic                        axi_tready_out,         // ready from the output stages
    output logic [63:0]                 axi_tdata_out           // muxword input (1 from each slice processor)
);

    // ------------------------------------------------------------------------------------------------------------
    //                                          internal definitions
    // ------------------------------------------------------------------------------------------------------------

    enum {  kSST_IDLE,
            kSST_PRIME,
            kSST_NORMAL,
            kSST_STALLED,
            kSST_LAST,
            kSST_HBLANK,
            kSST_END_OF_LINE
    } i_slice_state;

    logic               i_valid_in;
    logic               i_ready_in;
    logic               i_last_in;
    logic [63:0]        i_data_in;

    logic [4:0]         i_slice_select, i_slice_select_p1;
    logic [2:0]         i_horizontal_blanking_timer;

    // ------------------------------------------------------------------------------------------------------------
    //                                             processes
    // ------------------------------------------------------------------------------------------------------------

    // signal mapping
    always_comb begin : SignalMap
        // signal selection
        if (axi_encoder_enable == 1'b1) begin
            i_valid_in = axi_tvalid_in[i_slice_select];
            i_last_in = axi_tlast_in[i_slice_select];
            i_ready_in = axi_tready_in[i_slice_select];
            i_data_in = axi_tdata_in[i_slice_select];
        end else begin
            i_valid_in = 1'b0;
            i_last_in  = 1'b0;
            i_ready_in = 1'b0;
            i_data_in = 64'd0;
        end // if

        // intermediate signals
        i_slice_select_p1 = i_slice_select + 6'd1;
    end : SignalMap


    // --------------------------------------------------------------------------
    //   buffered write process
    // --------------------------------------------------------------------------
    always_ff@(posedge axi_clk or negedge axi_reset_n) begin : SliceData
        if (axi_reset_n == 1'b0) begin
            axi_tvalid_out <= 1'b0;
            axi_tdata_out <= 64'd0;
            axi_tline_out <= 1'b0;
            axi_tready_in <= '{default: 1'b0};
            axi_tframe_out <= 1'b0;

            i_slice_state <= kSST_IDLE;
            i_horizontal_blanking_timer <= 3'h7;
            i_slice_select <= 5'd0;

        end else begin

            // slice selection
            if (axi_new_frame == 1'b1) begin
                i_slice_select <= 5'd0;
            end else if (i_valid_in == 1'b1 && i_ready_in == 1'b1 & i_last_in == 1'b1) begin
                if (i_slice_select_p1 == cfg_dsc_encoder.slices_per_line) begin
                    i_slice_select <= 5'd0;
                end else begin
                    i_slice_select <= i_slice_select_p1;
                end // if
            end // if

            // default states for all inactive slice processors
            axi_tready_in  <= '{default: 1'b0};
            axi_tvalid_out <= 1'b0;
            axi_tframe_out <= 1'b0;
            axi_tline_out  <= 1'b0;

            // state based pipeline management
            if (axi_new_frame == 1'b1) begin
                axi_tready_in <= '{default: 1'b0};
                axi_tframe_out <= 1'b1;
                axi_tline_out <= 1'b0;
                i_horizontal_blanking_timer <= 3'h7;
                i_slice_state <= kSST_IDLE;

            end else begin
                case (i_slice_state)
                    // check for the enable
                    kSST_IDLE:  begin
                        if (axi_encoder_enable == 1'b1) begin
                            axi_tready_in <= '{default: 1'b0};
                            i_slice_state <= kSST_PRIME;
                        end // if
                    end // kSST_IDLE

                    // prime tvalid out
                    kSST_PRIME:  begin
                        i_horizontal_blanking_timer <= 3'h7;
                        axi_tready_in[i_slice_select] <= 1'b1;

                        if (i_valid_in == 1'b1 && i_ready_in == 1'b1) begin
                            axi_tvalid_out <= 1'b1;
                            axi_tdata_out <= i_data_in;

                            if (i_last_in == 1'b1) begin
                                i_slice_state <= kSST_LAST;
                            end else if (axi_tready_out == 1'b1) begin
                                i_slice_state <= kSST_NORMAL;
                            end else begin
                                 i_slice_state <= kSST_STALLED;
                            end // if
                        end // if
                    end // kSST_PRIME

                    // normal operation
                    kSST_NORMAL:  begin
                        case ({axi_tvalid_in[i_slice_select], axi_tready_out})
                            2'b00, 2'b01:  begin
                                axi_tvalid_out <= 1'b0;
                                i_slice_state <= kSST_PRIME;
                                axi_tready_in[i_slice_select] <= 1'b1;
                            end // not valid

                            2'b10:  begin
                                axi_tvalid_out <= 1'b1;
                                axi_tdata_out <= axi_tdata_in[i_slice_select];
                                axi_tready_in[i_slice_select] <= 1'b0;
                                i_slice_state <= (i_last_in == 1'b1) ? kSST_LAST : kSST_STALLED;
                            end // valid, not ready

                            2'b11:  begin
                                axi_tvalid_out <= 1'b1;
                                axi_tdata_out <= i_data_in;

                                if (i_last_in == 1'b1)  begin
                                    i_slice_state <= kSST_LAST;
                                    axi_tready_in[i_slice_select] <= 1'b0;
                                end else begin
                                    axi_tready_in[i_slice_select] <= 1'b1;
                                end // if
                            end // valid and ready

                            default:  begin
                                axi_tvalid_out <= 1'b0;
                                i_slice_state <= kSST_PRIME;
                                axi_tready_in[i_slice_select] <= 1'b0;
                            end // default
                        endcase
                    end // kSST_NORMAL

                    // output stalled
                    kSST_STALLED:  begin
                        axi_tvalid_out <= 1'b1;
                        if (axi_tready_out == 1'b1) begin
                            i_slice_state <= kSST_PRIME;
                            axi_tready_in[i_slice_select] <= 1'b1;
                            axi_tvalid_out <= 1'b0;
                        end // if
                    end // kSST_STALLED

                    // transfer the last data in the slice
                    kSST_LAST:  begin
                        axi_tvalid_out <= 1'b1;
                        if (axi_tvalid_out == 1'b1 && axi_tready_out == 1'b1) begin
                            i_slice_state <= kSST_HBLANK;
                        end // if
                    end // kSST_LAST

                    // insert a small horizontal blanking time
                    kSST_HBLANK:  begin
                        if (i_horizontal_blanking_timer == 3'd1) begin
                            i_slice_state <= kSST_END_OF_LINE;
                        end // if
                        i_horizontal_blanking_timer <= i_horizontal_blanking_timer - 3'd1;
                    end // kSST_HBLANK

                    // assert the end of line signal and check the enable again
                    kSST_END_OF_LINE:  begin
                        axi_tline_out <= 1'b1;
                        i_slice_state <= kSST_IDLE;
                    end // kSST_END_OF_LINE

                    // default for synthesis
                    default:  begin
                        i_slice_state <= kSST_PRIME;
                        axi_tvalid_out <= 1'b0;
                        axi_tready_in <= '{default: 1'b0};
                    end // default
                endcase
            end // if
        end // if
    end : SliceData

endmodule : dsce_slice_mux

