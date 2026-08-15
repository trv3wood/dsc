// ------------------------------------------------------------------------------------------------
//     COPYRIGHT © 2015-2021, TRILINEAR TECHNOLOGIES, INC.
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
//     DESCRIPTION : DSC encoder color space conversion block.  Also handles color truncation
//                   to the specified bits_per_component factor.
// ------------------------------------------------------------------------------------------------

// ----------------------------------------------
//  includes
// ----------------------------------------------
import dsce_defs_pkg::*;


// ----------------------------------------------
//  entity declaration
// ----------------------------------------------
module dsce_convert
(
    // clock and control interface
    input  logic                axi_clk,            // AXI input and output clock
    input  logic                axi_reset_n,        // AXI domain reset
    input  logic                axi_update_pps,     // okay to update pps parameters
    input  tDSC_PPS             cfg_pps,            // parameter set output array

    // data path
    input  logic                axi_valid_in,       // valid data in
    input  logic                axi_last_in,        // last sample in a slice line
    input  tSTD_PIXEL           axi_data_in [3:0],  // streaming input
    output logic                axi_valid_out,      // valid data out
    output logic                axi_last_out,       // last flag out
    output tDSC_PIXEL           axi_data_out [3:0]  // converted data out
);

    // ------------------------------------------------------------------------------------------------------------
    //                                          internal definitions
    // ------------------------------------------------------------------------------------------------------------

    logic [3:0]         i_bits_per_component;
    logic               i_convert_rgb;
    logic               i_simple_422;

    tSTD_PIXEL [3:0]    i_data_in;
    tSTD_PIXEL [3:0]    i_stage_data;
    logic               i_stage_valid, i_stage_last;
    tSTD_PIXEL [3:0]    i_upsample;
    logic               i_us_valid, i_us_last;


    // ------------------------------------------------------------------------------------------------------------
    //                                             support functions
    // ------------------------------------------------------------------------------------------------------------

    function automatic tSTD_PIXEL dsce_upsample (
        input tSTD_PIXEL p0,
        input tSTD_PIXEL p1
    );
        dsce_upsample.r = ({1'b0, p0.r} + {1'b0, p1.r}) >> 1;
        dsce_upsample.g = ({1'b0, p0.g} + {1'b0, p1.g}) >> 1;
        dsce_upsample.b = ({1'b0, p0.b} + {1'b0, p1.b}) >> 1;
    endfunction : dsce_upsample


    function automatic tDSC_PIXEL dsce_csc (
        input tSTD_PIXEL  p0,
        input logic [3:0] bpc
    );
        logic signed [16:0] csc_co, csc_cg;
        logic signed [16:0] t;

        // intermediate values
        csc_co = {1'b0, p0.r} - {1'b0, p0.b};
        t = $signed({1'b0, p0.b}) + ({csc_co[16], csc_co[16:1]});
        csc_cg = p0.g - t;

        // csc output
        dsce_csc.y = $unsigned(t + (csc_cg >> 1));
        if (bpc != 4'd0) begin
            dsce_csc.co = $unsigned(csc_co + (17'd1 << bpc));
            dsce_csc.cg = $unsigned(csc_cg + (17'd1 << bpc));
        end else begin
            dsce_csc.co = $unsigned(csc_co + 17'd1) - 16'd32768;
            dsce_csc.cg = $unsigned(csc_cg + 17'd1) - 16'd32768;
        end // if
    endfunction : dsce_csc


    function automatic tDSC_PIXEL dsce_cmap (
        input tSTD_PIXEL  p0
    );
        dsce_cmap.y = p0.g;
        dsce_cmap.co = p0.b;
        dsce_cmap.cg = p0.r;
    endfunction : dsce_cmap

    // ------------------------------------------------------------------------------------------------------------
    //                                             processes
    // ------------------------------------------------------------------------------------------------------------

    // signal assignments
    always_comb begin : SignalMap
        for (int gx = 0; gx < 4; gx++) begin : DataInMappingLoop
            case (i_bits_per_component)
                4'd0:  begin
                    i_data_in[gx].r = axi_data_in[gx].r;
                    i_data_in[gx].g = axi_data_in[gx].g;
                    i_data_in[gx].b = axi_data_in[gx].b;
                end // 16bpc
                4'd10:  begin
                    i_data_in[gx].r = {6'h00, axi_data_in[gx].r[15:6]};
                    i_data_in[gx].g = {6'h00, axi_data_in[gx].g[15:6]};
                    i_data_in[gx].b = {6'h00, axi_data_in[gx].b[15:6]};
                end // 10bpc
                4'd12:  begin
                    i_data_in[gx].r = {4'h0, axi_data_in[gx].r[15:4]};
                    i_data_in[gx].g = {4'h0, axi_data_in[gx].g[15:4]};
                    i_data_in[gx].b = {4'h0, axi_data_in[gx].b[15:4]};
                end // 12bpc
                4'd14:  begin
                    i_data_in[gx].r = {2'b00, axi_data_in[gx].r[15:2]};
                    i_data_in[gx].g = {2'b00, axi_data_in[gx].g[15:2]};
                    i_data_in[gx].b = {2'b00, axi_data_in[gx].b[15:2]};
                end // 14bpc
                default:  begin
                    i_data_in[gx].r = {8'h00, axi_data_in[gx].r[15:8]};
                    i_data_in[gx].g = {8'h00, axi_data_in[gx].g[15:8]};
                    i_data_in[gx].b = {8'h00, axi_data_in[gx].b[15:8]};
                end // 8bpc
            endcase
        end : DataInMappingLoop
    end : SignalMap


    // -----------------------------------------------------
    //  color management utility functions
    // -----------------------------------------------------
    always_ff@(posedge axi_clk or negedge axi_reset_n) begin : ColorUtil
        if (axi_reset_n == 1'b0) begin
            i_bits_per_component <= 4'h0;
            i_convert_rgb <= 1'b0;
            i_simple_422 <= 1'b0;

        end else begin

            // update internal parameters
            if (axi_update_pps == 1'b1) begin
                // local copies
                i_convert_rgb <= cfg_pps.convert_rgb;
                i_bits_per_component <= cfg_pps.bits_per_component;

                // dsc version specific parameters
                i_simple_422 <= (cfg_pps.dsc_version_minor != 4'd1 || cfg_pps.native_420 == 1'b1 || cfg_pps.native_422 == 1'b1) ? 1'b0 : cfg_pps.simple_422;
            end // if
        end // if
    end : ColorUtil


    // -----------------------------------------------------
    //  color space conversion
    // -----------------------------------------------------
    always_ff@(posedge axi_clk or negedge axi_reset_n) begin : CSC
        if (axi_reset_n == 1'b0) begin
            axi_data_out <= '{default: kDSC_PIXEL_INIT};
            axi_valid_out <= 1'b0;
            axi_last_out <= 1'b0;
            i_us_valid <= 1'b0;
            i_us_last <= 1'b0;
            i_upsample <= '{default: kDSC_PIXEL_INIT};
            i_stage_valid <= 1'b0;
            i_stage_last <= 1'b0;
            i_stage_data <= '{default: kSTD_PIXEL_INIT};

        end else begin

            // default states
            axi_valid_out <= 1'b0;
            i_us_valid <= 1'b0;
            i_us_last <= 1'b0;

            // staging
            if (axi_valid_in == 1'b1) begin
                i_stage_valid <= 1'b1;
                i_stage_last <= axi_last_in;
                i_stage_data <= i_data_in;
            end else begin
                i_stage_valid <= 1'b0;
                i_stage_last <= 1'b0;
            end // if

            // upsample stage
            if (i_simple_422 == 1'b0) begin
                i_us_valid <= i_stage_valid;
                i_us_last <= i_stage_last;
                i_upsample <= i_stage_data;
            end else if (i_stage_valid == 1'b1 && (axi_valid_in == 1'b1 || i_stage_last == 1'b1)) begin
                i_us_valid <= 1'b1;
                i_us_last <= i_stage_last;
                i_upsample[3] <= (i_stage_last == 1'b0) ? dsce_upsample(i_stage_data[2], axi_data_in[0]) : dsce_upsample(i_stage_data[2], i_stage_data[2]);
                i_upsample[2] <= i_stage_data[2];
                i_upsample[1] <= dsce_upsample(i_stage_data[0], i_stage_data[2]);
                i_upsample[0] <= i_stage_data[0];
            end // if

            // conversion stage
            axi_valid_out <= i_us_valid;
            axi_last_out <= i_us_last;
            if (i_convert_rgb == 1'b1) begin
                axi_data_out[0] <= dsce_csc(i_upsample[0], i_bits_per_component);
                axi_data_out[1] <= dsce_csc(i_upsample[1], i_bits_per_component);
                axi_data_out[2] <= dsce_csc(i_upsample[2], i_bits_per_component);
                axi_data_out[3] <= dsce_csc(i_upsample[3], i_bits_per_component);
            end else begin
                axi_data_out[0] <= dsce_cmap(i_upsample[3]);
                axi_data_out[1] <= dsce_cmap(i_upsample[3]);
                axi_data_out[2] <= dsce_cmap(i_upsample[3]);
                axi_data_out[3] <= dsce_cmap(i_upsample[3]);
            end // if

        end // if
    end : CSC

endmodule : dsce_convert

