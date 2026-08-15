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
//     DESCRIPTION : Packing logic for the DSC encoder core.  Accepts 1, 2 or 4 pixels
//                   per cycle and converts to the 4 pixels per cycle used by the input
//                   data path logic.
// ------------------------------------------------------------------------------------------------

// ----------------------------------------------
//  includes
// ----------------------------------------------
import dsce_defs_pkg::*;


// ----------------------------------------------
//  entity declaration
// ----------------------------------------------
module dsce_pack
(
    // clock and control interface
    input  logic            axi_clk,                // AXI input and output clock
    input  logic            axi_reset_n,            // AXI domain reset
    input  tDSCE_CONFIG     cfg_dsc_encoder,        // general encoder configuration
    input  logic [15:0]     cfg_pic_width,          // picture width
    input  logic            axi_encoder_enable,     // encoder enable flag

    // AXI input path
    input  logic            axi_tline_in,           // line reset
    input  logic            axi_tvalid_in,          // valid data in
    output logic            axi_tready_in,          // ready from the buffer
    input  tDSC_PIXEL       axi_tdata_in [3:0],     // streaming input

    // output path (not AXI4-S compliant)
    output logic            axi_tline_out,          // line reset out
    output logic            axi_tvalid_out,         // valid data out
    input  logic            axi_tready_out,         // ready to accept
    output tDSC_PIXEL       axi_tdata_out [3:0]     // converted data out
);

    // ------------------------------------------------------------------------------------------------------------
    //                                          internal definitions
    // ------------------------------------------------------------------------------------------------------------

    logic [15:0]        i_pixel_count, i_next_pixel_count;
    logic               i_last_input_cycle;
    logic [1:0]         i_pack_index;


    // ------------------------------------------------------------------------------------------------------------
    //                                             processes
    // ------------------------------------------------------------------------------------------------------------

    // -----------------------------------------------
    //  combinatorial logic
    // -----------------------------------------------
    always_comb begin : CombLogic
        i_next_pixel_count = i_pixel_count + cfg_dsc_encoder.pixels_per_cycle;

        i_last_input_cycle = (i_next_pixel_count >= cfg_pic_width) ? 1'b1 : 1'b0;
    end : CombLogic


    // -----------------------------------------------
    //  data path width conversion
    // -----------------------------------------------
    always_ff@(posedge axi_clk or negedge axi_reset_n) begin : PathPacking
        if (axi_reset_n == 1'b0) begin
            axi_tready_in <= 1'b0;
            axi_tvalid_out <= 1'b0;
            axi_tline_out <= 1'b0;
            axi_tdata_out <= '{default: 48'd0};

        end else begin

            // defaults
            axi_tvalid_out <= 1'b0;
            axi_tline_out <= axi_tline_in;
            axi_tready_in <= axi_encoder_enable & axi_tready_out;

            // convert to 4 pixels per cycle
            if (axi_encoder_enable == 1'b0 || axi_tline_in == 1'b1) begin
                axi_tvalid_out <= 1'b0;
                axi_tdata_out <= '{default:48'd0};
            end else begin
                if (axi_tvalid_in == 1'b1 && axi_tready_in == 1'b1) begin
                    case (cfg_dsc_encoder.pixels_per_cycle)
                        3'd1:  begin
                            if (i_pack_index == 2'd3 || i_last_input_cycle == 1'b1) begin
                                axi_tvalid_out <= 1'b1;
                            end // if

                            case (i_pack_index)
                                2'd0:       axi_tdata_out[0] <= axi_tdata_in[0];
                                2'd1:       axi_tdata_out[1] <= axi_tdata_in[0];
                                2'd2:       axi_tdata_out[2] <= axi_tdata_in[0];
                                default:    axi_tdata_out[3] <= axi_tdata_in[0];
                            endcase
                        end // 1 ppc

                        3'd2:  begin
                            axi_tvalid_out <= i_last_input_cycle | i_pack_index[0];
                            if (i_pack_index[0] == 1'b0) begin
                                axi_tdata_out[1:0] <= axi_tdata_in[1:0];
                            end else begin
                                axi_tdata_out[3:2] <= axi_tdata_in[1:0];
                            end // if
                        end // 2 ppc

                        default:  begin
                            axi_tvalid_out <= 1'b1;
                            axi_tdata_out <= axi_tdata_in;
                        end // 4 ppc
                    endcase
                end else begin
                    axi_tvalid_out <= 1'b0;
                end // if
            end // if

        end // if
    end : PathPacking


    // -----------------------------------------------
    //  input pixel tracking
    // -----------------------------------------------
    always_ff@(posedge axi_clk or negedge axi_reset_n) begin : PixelTrack
        if (axi_reset_n == 1'b0) begin
            i_pixel_count <= 16'd0;
            i_pack_index <= 2'd0;

        end else begin

            // pixel count
            if (axi_encoder_enable == 1'b0 || axi_tline_in == 1'b1) begin
                i_pixel_count <= 16'd0;
            end else if (axi_tvalid_in == 1'b1 && axi_tready_in == 1'b1) begin
                i_pixel_count <= i_next_pixel_count;
            end // if

            // line tracking
            if (axi_tline_in == 1'b1)  begin
                i_pack_index <= 2'd0;
            end else if (axi_tvalid_in == 1'b1 && axi_tready_in == 1'b1)  begin
                i_pack_index <= i_pack_index + 2'd1;
            end // if

        end // if
    end : PixelTrack

endmodule : dsce_pack

