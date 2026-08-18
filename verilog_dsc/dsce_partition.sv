// ------------------------------------------------------------------------------------------------
//     COPYRIGHT © 2016-2023, TRILINEAR TECHNOLOGIES, INC.
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
//     DESCRIPTION : Partitioning logic for the allocation of pixels to each slice processor.
//                   The partition logic works on groups of 4 pixels from the input interface.
// ------------------------------------------------------------------------------------------------

// ----------------------------------------------
//  includes
// ----------------------------------------------
import dsce_defs_pkg::*;


// ----------------------------------------------
//  entity declaration
// ----------------------------------------------
module dsce_partition
#(
    parameter int pSPC = 4                             // number of slice processors
)
(
    // clock and control interface
    input  logic            axi_clk,                   // AXI input and output clock
    input  logic            axi_reset_n,               // AXI domain reset
    input  logic            axi_pps_update,            // okay to update pps parameters
    input  tDSC_PPS         cfg_pps,                   // parameter set output array
    input  tDSCE_CONFIG     cfg_dsc_encoder,           // general encoder configuration

    // streaming input data path
    input  logic            axi_valid_in,              // valid data in
    output logic            axi_ready_in,              // ready/accept in
    input  logic            axi_line_in,               // line reset input
    input  tSTD_PIXEL       axi_data_in [3:0],         // packed input, 4 pixels wide

    // slice processor data path
    output logic [pSPC-1:0] axi_last_out,              // last flag out
    output logic [pSPC-1:0] axi_valid_out,             // valid data out
    input  logic [pSPC-1:0] axi_ready_out,             // ready/accept data out
    output tSTD_PIXEL       axi_data_out [pSPC*4-1:0]  // slice data out
);

    // ------------------------------------------------------------------------------------------------------------
    //                                          internal definitions
    // ------------------------------------------------------------------------------------------------------------

    logic [15:0]        i_slice_width;
    logic [15:0]        i_slice_count, i_next_slice_count;
    logic               i_slice_last;
    logic [15:0]        i_slice_select;         // up to 16
    logic [3:0]         i_max_proc_num;         // local buffer


    // ------------------------------------------------------------------------------------------------------------
    //                                             processes
    // ------------------------------------------------------------------------------------------------------------

    // signal mapping
    always_comb begin : SignalMap
        i_next_slice_count = i_slice_count + 16'd4;
        i_slice_last = (i_next_slice_count >= i_slice_width) ? 1'b1 : 1'b0;
    end : SignalMap


    // --------------------------------------------------------------------------
    //   buffered write process
    // --------------------------------------------------------------------------
    always_ff@(posedge axi_clk or negedge axi_reset_n) begin : SliceSteering
        if (axi_reset_n == 1'b0) begin
            axi_valid_out <= '{default: 1'b0};
            axi_ready_in <= 1'b0;
            axi_data_out <= '{default: kDSC_PIXEL_INIT};
            axi_last_out <= '{default: 1'b0};

            i_slice_select <= 16'h0001;
            i_slice_count <= 16'd0;
            i_slice_width <= 16'h0000;
            i_max_proc_num <= 4'h0;

        end else begin

            // ready processing is line based
            axi_ready_in <= (axi_ready_out == {pSPC{1'b1}}) ? 1'b1 : 1'b0;

            // record the parameters at an update interval
            if (axi_pps_update == 1'b1)  begin
                i_slice_width <= cfg_pps.slice_width;
                i_max_proc_num <= cfg_dsc_encoder.slice_processor_count - 4'd1;
            end // if

            // route to the proper slice processor
            if (axi_valid_in == 1'b1) begin
                if (i_slice_last == 1'b1) begin
                    i_slice_count <= 16'd0;
                    if (i_slice_select[i_max_proc_num] == 1'b1) begin
                        i_slice_select <= 16'h0001;
                    end else begin
                        i_slice_select <= {i_slice_select[14:0], 1'b0};
                    end // if
                end else begin
                    i_slice_count <= i_next_slice_count;
                end // if
            end else begin
                if (axi_line_in == 1'b1)  i_slice_count <= 16'd0;
                if (axi_pps_update == 1'b1)  i_slice_select <= 16'h0001;
            end // if

            // slice partitioning
            for (int sx = 0; sx < pSPC; sx++) begin
                if (axi_valid_in == 1'b1 && axi_ready_in == 1'b1 && i_slice_select[sx] == 1'b1) begin
                    axi_valid_out[sx] <= 1'b1;
                    axi_last_out[sx] <= i_slice_last;
                    axi_data_out[sx*4+3] <= axi_data_in[3];
                    axi_data_out[sx*4+2] <= axi_data_in[2];
                    axi_data_out[sx*4+1] <= axi_data_in[1];
                    axi_data_out[sx*4]   <= axi_data_in[0];
                end else begin
                    axi_valid_out[sx] <= 1'b0;
                    axi_last_out[sx] <= 1'b0;
                end // if
            end // if

        end // if
    end : SliceSteering

// 运行时不变式：slice 选择位必须单热(轮转映射不产生多路同时有效)。
    assert property (@(posedge axi_clk) disable iff (!axi_reset_n || !axi_pps_update)
                     $onehot(i_slice_select))
        else $error("Partition slice_select not one-hot");
    assert property (@(posedge axi_clk) disable iff (!axi_reset_n)
                     !(axi_valid_in && axi_pps_update) || $onehot(i_slice_select))
        else $error("Partition slice_select not one-hot at pps update");

endmodule : dsce_partition

