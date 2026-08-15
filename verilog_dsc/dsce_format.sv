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
//     DESCRIPTION : Entropy encoder and data stream format block for each slice.
// ------------------------------------------------------------------------------------------------

// ----------------------------------------------
//  includes
// ----------------------------------------------
import dsce_defs_pkg::*;


// ----------------------------------------------
//  module declaration
// ----------------------------------------------
module dsce_format
#(
    parameter int pDEBUG_MESSAGES = 1                               // display debug messages
)
(
    // clock and control interface
    input  logic                     dsc_clk,                       // DSC processing clock
    input  logic                     dsc_reset_n,                   // DSC domain reset
    input  tDSCE_CONFIG              cfg_dsc_encoder,               // general encoder configuration
    input  logic                     dsc_pps_update,                // update pps parameters flag
    input  tDSC_PPS                  cfg_pps,                       // parameter set output array
    input  tDSC_RCPS                 cfg_rcps,                      // range control parameters

    // residual path
    input  logic                     dsc_start_of_slice,            // start of slice marker
    input  logic                     dsc_predict_valid_in,          // valid data in (predict and ICH)
    input  logic                     dsc_predict_last_in,           // last group in the slice
    input  tDSC_QLEVEL               dsc_primary_qp_in,             // primary QP value
    input  tDSC_QLEVEL               dsc_qlevel_y_in,               // luma quant level for the current group
    input  tDSC_QLEVEL               dsc_qlevel_c_in,               // chroma quant level for the current group
    input  tDSC_FLAT_FLAGS           dsc_flatness_in,               // flatness code input

    // residual path input
    input  logic                     dsc_ich_selected_in,           // ICH mode selected
    input  tDSC_ICH_INDEX            dsc_ich_index_in [2:0],        // ICH mode indices
    input  tDSC_RESIDUAL_PIXEL       dsc_residual_in [2:0],         // group residuals, 3 per pixel
    input  logic [4:0]               dsc_residual_size_in [2:0],    // component residual sizes
    input  logic [4:0]               dsc_vlc_size_in [2:0],         // vlc adjustment size

    // rate control outputs
    output logic [7:0]               dsc_coded_group_size,          // number of coded bits
    output logic [7:0]               dsc_rc_size_group,             // coded bits for rate control

    // output to the slice mux
    input  logic                     axi_clk,                       // AXI domain clock
    input  logic                     axi_reset_n,                   // AXI domain reset
    output logic                     axi_last_out,                  // last transfer flag
    output logic                     axi_tvalid_out,                // data ready flag output
    input  logic                     axi_tready_out,                // data accept from the slice mux
    output logic [63:0]              axi_muxword_out,               // mux word for inclusion in the slice stream

    // memory BIST interface
    input  logic [11:0]              bist_sram_in,                  // BIST input, 1 SRAM
    output logic [11:0]              bist_sram_out                  // BIST output, 1 SRAM
);

    // ------------------------------------------------------------------------------------------------------------
    //                                          internal connections
    // ------------------------------------------------------------------------------------------------------------

    logic [2:0]                     i_valid_vlc;
    logic [2:0]                     i_last_vlc;
    logic [15:0]                    i_data_vlc [2:0];
    logic [4:0]                     i_size_vlc [2:0];
    logic [2:0]                     i_valid_mw;
    logic [63:0]                    i_muxword [2:0];
    logic [2:0]                     i_unit_size_valid_vlc;
    logic [5:0]                     i_coded_unit_size_vlc [2:0];
    logic [5:0]                     i_rcsg_vlc [2:0];

    tDSC_RESIDUAL                   i_predict_residual [2:0] [2:0];

    logic                           i_muxword_valid_sb;
    logic                           i_muxword_last_sb;
    logic [63:0]                    i_muxword_sb;

    // ------------------------------------------------------------------------------------------------------------
    //                                             internal blocks
    // ------------------------------------------------------------------------------------------------------------

    // signal assignments
    always_comb begin : SignalMap
        i_predict_residual[0] = '{dsc_residual_in[2].res_y, dsc_residual_in[1].res_y, dsc_residual_in[0].res_y};
        i_predict_residual[1] = '{dsc_residual_in[2].res_co, dsc_residual_in[1].res_co, dsc_residual_in[0].res_co};
        i_predict_residual[2] = '{dsc_residual_in[2].res_cg, dsc_residual_in[1].res_cg, dsc_residual_in[0].res_cg};

        dsc_coded_group_size = ({2'b00, i_coded_unit_size_vlc[0]} + {2'b00, i_coded_unit_size_vlc[1]} + {2'b00, i_coded_unit_size_vlc[2]});
        dsc_rc_size_group = ({2'b00, i_rcsg_vlc[0]} + {2'b00, i_rcsg_vlc[1]} + {2'b00, i_rcsg_vlc[2]});
    end : SignalMap


    // ---------------------------------------------
    //  residual data path
    // ---------------------------------------------
    generate for (genvar mx = 0; mx < 3; mx++) begin : gen_vlc
        // ---------------------------------------------
        //  vlc mapping
        // ---------------------------------------------
        dsce_vlc
        #(
            .pCOLOR_SELECT    (mx)
        )  dsce_vlc_inst
        (
            // clock and control interface
            .dsc_clk                (dsc_clk),
            .dsc_reset_n            (dsc_reset_n),
            .dsc_pps_update         (dsc_pps_update),
            .cfg_pps                (cfg_pps),
            // input data group
            .dsc_start_of_slice     (dsc_start_of_slice),
            .dsc_predict_valid_in   (dsc_predict_valid_in),
            .dsc_predict_last_in    (dsc_predict_last_in),
            .dsc_residual_in        (i_predict_residual[mx]),
            .dsc_residual_size_in   (dsc_residual_size_in[mx]),
            .dsc_vlc_size_in        (dsc_vlc_size_in[mx]),
            .dsc_primary_qp_in       (dsc_primary_qp_in),
            .dsc_qlevel_y_in        (dsc_qlevel_y_in),
            .dsc_qlevel_c_in        (dsc_qlevel_c_in),
            .dsc_ich_selected_in    (dsc_ich_selected_in),
            .dsc_ich_index_in       (dsc_ich_index_in[mx]),
            .dsc_flatness_in        (dsc_flatness_in),
            // RC outputs
            .dsc_unit_size_valid    (i_unit_size_valid_vlc[mx]),
            .dsc_coded_unit_size    (i_coded_unit_size_vlc[mx]),
            .dsc_rc_size_unit       (i_rcsg_vlc[mx]),
            // vlc coded data out
            .dsc_vlc_valid_out      (i_valid_vlc[mx]),
            .dsc_vlc_last_out       (i_last_vlc[mx]),
            .dsc_vlc_size_out       (i_size_vlc[mx]),
            .dsc_vlc_data_out       (i_data_vlc[mx])
        );

        // ---------------------------------------------
        //  mux word packing
        // ---------------------------------------------
        dsce_muxword  dsce_muxword_inst
        (
            // clock and control interface
            .dsc_clk                (dsc_clk),
            .dsc_reset_n            (dsc_reset_n),
            .dsc_pps_update         (dsc_pps_update),
            .cfg_pps                (cfg_pps),
            .dsc_start_of_slice     (dsc_start_of_slice),
            // input stream from VLC
            .dsc_vlc_valid_in       (i_valid_vlc[mx]),
            .dsc_vlc_last_in        (i_last_vlc[mx]),
            .dsc_stream_data_in     (i_data_vlc[mx]),
            .dsc_stream_size_in     (i_size_vlc[mx]),
            // output mux word
            .dsc_muxword_valid_out  (i_valid_mw[mx]),
            .dsc_muxword_out        (i_muxword[mx])
        );
    end endgenerate


    // ---------------------------------------------
    //  stream assembly
    // ---------------------------------------------
    dsce_stream_builder  dsce_stream_builder_inst
    (
        // clock and control interface
        .dsc_clk                    (dsc_clk),
        .dsc_reset_n                (dsc_reset_n),
        .cfg_bits_per_component     (cfg_pps.bits_per_component),
        .cfg_convert_rgb            (cfg_pps.convert_rgb),
        // input path from muxword builder
        .dsc_start_of_slice         (dsc_start_of_slice),
        .dsc_muxword_valid_in       (i_valid_mw),
        .dsc_muxword_last_in        (3'b000),
        .dsc_muxword_in             (i_muxword),
        // syntax size input from VLC
        .dsc_unit_size_valid_in     (i_unit_size_valid_vlc),
        .dsc_unit_size_last_in      (3'b000),
        .dsc_coded_unit_size        (i_coded_unit_size_vlc),
        // output to the format buffer
        .dsc_muxword_valid_out      (i_muxword_valid_sb),
        .dsc_muxword_last_out       (i_muxword_last_sb),
        .dsc_muxword_out            (i_muxword_sb)
    );

    // ---------------------------------------------
    //  assembled word buffer
    // ---------------------------------------------
    dsce_format_buffer  dsce_format_buffer_inst
    (
        // clock and control interface
        .dsc_clk                    (dsc_clk),
        .dsc_reset_n                (dsc_reset_n),
        .dsc_pps_update             (dsc_pps_update),
        .cfg_pps                    (cfg_pps),
        .cfg_dsc_encoder            (cfg_dsc_encoder),
        // input path from muxword builder
        .dsc_start_of_frame         (1'b0),
        .dsc_start_of_slice         (dsc_start_of_slice),
        .dsc_muxword_valid_in       (i_muxword_valid_sb),
        .dsc_muxword_in             (i_muxword_sb),
        // output to the slice mux
        .axi_clk                    (axi_clk),
        .axi_reset_n                (axi_reset_n),
        .axi_last_out               (axi_last_out),
        .axi_tvalid_out             (axi_tvalid_out),
        .axi_tready_out             (axi_tready_out),
        .axi_muxword_out            (axi_muxword_out),
        // memory BIST interface
        .bist_sram_in               (bist_sram_in),
        .bist_sram_out              (bist_sram_out)

    );

endmodule : dsce_format
