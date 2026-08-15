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
//     DESCRIPTION : DSC encoder core engine.  Includes the main processing elements for the
//                   real time encode of the input frames.  Bypass mode is supported directly
//                   with a special buffer.
// ------------------------------------------------------------------------------------------------

// ----------------------------------------------
//  includes
// ----------------------------------------------
import dsce_defs_pkg::*;


// ----------------------------------------------
//  entity declaration
// ----------------------------------------------
module dsce_engine
#(
    parameter int pSPC                      = 4,                     // slice processor count
    parameter int pMAX_SLICE_LINE_SIZE      = 4096,                  // maximum reference line size
    parameter int pINCLUDE_BLOCK_PREDICTION = 1,                     // includes support for block prediction
    parameter int pDEBUG_MESSAGES           = 1                      // display debug messages
)
(
    // control interface
    input  logic                    dsc_clk,                         // encoder domain
    input  logic                    dsc_reset_n,                     // encoder reset
    input  logic                    dsc_encoder_enable,              // encoder enable
    input  logic                    cfg_bypass_enable,               // enable bypass mode
    output tDSCE_SLICE_STATUS       cfg_dsc_slice_status [pSPC-1:0], // slice operating status

    // host interface
    input  logic                    apb_clk,                         // APB host domain
    input  logic                    apb_reset_n,                     // APB domain reset
    input  tDSCE_CONFIG             cfg_dsc_encoder,                 // general encoder configuration

    input  logic                    axi_encoder_enable,              // encoder enable
    input  logic                    axi_pps_update,                  // update toggle flag, axi domain
    input  logic                    dsc_pps_update,                  // update toggle flag, dsc domain
    input  logic                    axi_new_frame,                   // new frame flag, axi
    input  logic                    dsc_new_frame,                   // new frame flag, dsc
    input  tDSC_PPS                 cfg_pps,                         // parameter set output array
    input  tDSC_RCPS                cfg_rcps,                        // rate control parameter set

    // AXI4-Stream input
    input  logic                    axi_clk,                         // AXI input and output clock
    input  logic                    axi_reset_n,                     // AXI domain reset
    input  logic                    axi_tvalid_in,                   // stream data valid
    output logic                    axi_tready_in,                   // encoder ready to receive stream data
    input  logic                    axi_tline_in,                    // start of line indicator, axi_tuser[0]
    input  logic                    axi_tframe_in,                   // start of frame indicator, axi_tuser[1]
    input  logic [191:0]            axi_tdata_in,                    // encoded stream input (4 pixels per cycle, uncompressed)// AXI4-Stream output

    // AXI4-Stream output
    output logic                    axi_tvalid_out,                  // stream data valid
    input  logic                    axi_tready_out,                  // encoder ready to receive stream data
    output logic                    axi_tline_out,                   // start of line indicator, axi_tuser[0]
    output logic                    axi_tframe_out,                  // start of frame indicator, axi_tuser[1]
    output logic [191:0]            axi_tdata_out,                   // encoded stream output (4 pixels per cycle)

    // BIST connections
    input  logic [11:0]             bist_sram_in  [4*pSPC-1:0],      // BIST input, per slice
    output logic [11:0]             bist_sram_out [4*pSPC-1:0]       // BIST output, per slice
);

    // ------------------------------------------------------------------------------------------------------------
    //                                          internal definitions
    // ------------------------------------------------------------------------------------------------------------

    logic                           i_valid_pack;
    logic                           i_ready_pack;

    logic                           i_line_pack;
    tSTD_PIXEL                      i_data_pack [3:0];

    logic [pSPC-1:0]                i_valid_part;
    logic [pSPC-1:0]                i_ready_part;
    logic [pSPC-1:0]                i_last_part;
    tSTD_PIXEL                      i_data_part  [pSPC*4-1:0];

    tDSC_PIXEL                      i_axi_tpixel_in [3:0];
    logic [pSPC-1:0]                i_axi_accept;
    logic [pSPC-1:0]                i_axi_ready;
    logic [pSPC-1:0]                i_axi_last;
    logic [pSPC-1:0] [63:0]         i_axi_muxword;

    logic                           i_axi_tframe_mux;
    logic                           i_axi_tline_mux;
    logic                           i_axi_tvalid_mux;
    logic                           i_axi_tready_mux;
    logic [63:0]                    i_axi_tdata_mux;

    logic                           i_axi_tready_pack;
    logic                           i_axi_tready_bypass;

    // ------------------------------------------------------------------------------------------------------------
    //                                                 components
    // ------------------------------------------------------------------------------------------------------------

    assign axi_tready_in = (i_axi_tready_pack | i_axi_tready_bypass);
    assign i_axi_tpixel_in = '{axi_tdata_in[191:144], axi_tdata_in[143:96], axi_tdata_in[95:48], axi_tdata_in[47:0]};


    // ---------------------------------------------
    //  data path width conversion
    // ---------------------------------------------
    dsce_pack  dsce_pack_inst
    (
        // clock and control interface
        .axi_clk                (axi_clk),
        .axi_reset_n            (axi_reset_n),
        .cfg_dsc_encoder        (cfg_dsc_encoder),
        .cfg_pic_width          (cfg_pps.pic_width),
        .axi_encoder_enable     (axi_encoder_enable),
        // AXI input path
        .axi_tline_in           (axi_tline_in),
        .axi_tvalid_in          (axi_tvalid_in),
        .axi_tready_in          (i_axi_tready_pack),
        .axi_tdata_in           (i_axi_tpixel_in),
        // output path
        .axi_tline_out          (i_line_pack),
        .axi_tvalid_out         (i_valid_pack),
        .axi_tready_out         (i_ready_pack),
        .axi_tdata_out          (i_data_pack)
    );


    // ---------------------------------------------
    //  slice partition steering
    // ---------------------------------------------
    dsce_partition
    #(
        .pSPC           (pSPC)
    )  dsce_partition_inst
    (
        // clock and control interface
        .axi_clk                (axi_clk),
        .axi_reset_n            (axi_reset_n),
        .axi_pps_update         (axi_pps_update),
        .cfg_pps                (cfg_pps),
        .cfg_dsc_encoder        (cfg_dsc_encoder),
        // streaming input data path
        .axi_valid_in           (i_valid_pack),
        .axi_ready_in           (i_ready_pack),
        .axi_line_in            (i_line_pack),
        .axi_data_in            (i_data_pack),
        // slice processor data path
        .axi_last_out           (i_last_part),
        .axi_valid_out          (i_valid_part),
        .axi_ready_out          (i_ready_part),
        .axi_data_out           (i_data_part)
    );


    // ---------------------------------------------
    //  slice processors
    // ---------------------------------------------
    generate for (genvar gx = 0; gx < pSPC; gx++) begin : gen_slice
        dsce_slice
        #(
            .pSPC                       (pSPC),
            .pMAX_SLICE_LINE_SIZE       (pMAX_SLICE_LINE_SIZE),
            .pINCLUDE_BLOCK_PREDICTION  (pINCLUDE_BLOCK_PREDICTION),
            .pDEBUG_MESSAGES            (pDEBUG_MESSAGES)
        ) dsce_slice_inst
        (
            // clock and control interface
            .axi_clk                    (axi_clk),
            .axi_reset_n                (axi_reset_n),
            .axi_pps_update             (axi_pps_update),
            .axi_encoder_enable         (axi_encoder_enable),
            .cfg_dsc_encoder            (cfg_dsc_encoder),
            .cfg_pps                    (cfg_pps),
            .cfg_rcps                   (cfg_rcps),
            .cfg_slice_status           (cfg_dsc_slice_status[gx]),
            // streaming input data path
            .axi_valid_in               (i_valid_part[gx]),
            .axi_ready_in               (i_ready_part[gx]),
            .axi_frame_in               (axi_tframe_in),
            .axi_last_in                (i_last_part[gx]),
            .axi_data_in                (i_data_part[gx*4+3:gx*4]),
            // host write interface
            .apb_clk                    (apb_clk),
            .apb_reset_n                (apb_reset_n),
            // internal data path for encoding
            .dsc_clk                    (dsc_clk),
            .dsc_reset_n                (dsc_reset_n),
            .dsc_encoder_enable         (dsc_encoder_enable),
            .dsc_pps_update             (dsc_pps_update),
            // output to the slice mux
            .axi_last_out               (i_axi_last[gx]),
            .axi_tvalid_out             (i_axi_ready[gx]),
            .axi_tready_out             (i_axi_accept[gx]),
            .axi_muxword_out            (i_axi_muxword[gx]),
            // memory BIST interface
            .bist_sram_in               (bist_sram_in[gx*4 +: 4]),
            .bist_sram_out              (bist_sram_out[gx*4 +: 4])
        );
    end endgenerate


    // ---------------------------------------------
    //  slice mux
    // ---------------------------------------------
    dsce_slice_mux
    #(
        .pSPC                   (pSPC)
    )  dsce_slice_mux_inst
    (
        // clock and control interface
        .axi_clk                (axi_clk),
        .axi_reset_n            (axi_reset_n),
        .cfg_dsc_encoder        (cfg_dsc_encoder),
        .axi_encoder_enable     (axi_encoder_enable),
        .axi_pps_update         (axi_pps_update),
        .axi_new_frame          (axi_new_frame),
        // slice processor data path
        .axi_tvalid_in          (i_axi_ready),
        .axi_tready_in          (i_axi_accept),
        .axi_tlast_in           (i_axi_last),
        .axi_tdata_in           (i_axi_muxword),
        // streaming output data path
        .axi_tframe_out         (i_axi_tframe_mux),
        .axi_tline_out          (i_axi_tline_mux),
        .axi_tvalid_out         (i_axi_tvalid_mux),
        .axi_tready_out         (i_axi_tready_mux),
        .axi_tdata_out          (i_axi_tdata_mux)
    );


    // ---------------------------------------------
    //  bypass logic
    // ---------------------------------------------
    dsce_bypass  dsce_bypass_inst
    (
        // clock and control interface
        .axi_clk                (axi_clk),
        .axi_reset_n            (axi_reset_n),
        .cfg_bypass_enable      (cfg_bypass_enable),
        .cfg_bits_per_component (cfg_pps.bits_per_component),
        .cfg_output_mode        (cfg_dsc_encoder.output_mode),
        // encoder output data path
        .axi_tframe_mux         (i_axi_tframe_mux),
        .axi_tline_mux          (i_axi_tline_mux),
        .axi_tvalid_mux         (i_axi_tvalid_mux),
        .axi_tready_mux         (i_axi_tready_mux),
        .axi_tdata_mux          (i_axi_tdata_mux),
        // input bypass path
        .axi_tvalid_in          (axi_tvalid_in),
        .axi_tready_in          (i_axi_tready_bypass),
        .axi_tline_in           (axi_tline_in),
        .axi_tframe_in          (axi_tframe_in),
        .axi_tdata_in           (axi_tdata_in),
        // streaming output data path
        .axi_tframe_out         (axi_tframe_out),
        .axi_tline_out          (axi_tline_out),
        .axi_tvalid_out         (axi_tvalid_out),
        .axi_tready_out         (axi_tready_out),
        .axi_tdata_out          (axi_tdata_out)
    );

endmodule : dsce_engine

