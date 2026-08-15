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
//     DESCRIPTION : Top level description for the implementation of the Display Stream
//                   Compression (DSC) encoder.
// ------------------------------------------------------------------------------------------------


// ----------------------------------------------
//  module declaration
// ----------------------------------------------
module dsc_encoder
#(
    parameter int pSLICE_PROCESSOR_COUNT    = 4,         // number of slice processors (must be a power of 2)
    parameter int pMAX_SLICE_LINE_SIZE      = 4096,      // maximum reference line size
    parameter int pINCLUDE_BLOCK_PREDICTION = 1,         // includes support for block prediction
    parameter int pDEBUG_MESSAGES           = 1          // display debug messages
)
(
    // apb interface
    input  logic         apb_clk,                        // APB bus clock
    input  logic         apb_select,                     // select
    input  logic         apb_enable,                     // enable
    input  logic         apb_write,                      // write enable
    input  logic [3:0]   apb_strobe,                     // byte write strobe
    input  logic [2:0]   apb_protect,                    // access protection fields
    input  logic [11:0]  apb_addr,                       // address
    input  logic [31:0]  apb_wdata,                      // write data
    output logic         apb_ready,                      // ready output
    output logic         apb_slave_error,                // slave programming error
    output logic         apb_int,                        // interrupt out
    output logic [31:0]  apb_rdata,                      // read data

    // encoder control signals
    input  logic         dsc_clk,                        // encoder clock domain
    input  logic         async_reset_n,                  // global core reset (async)
    input  logic         async_test_mode,                // scan test mode enable

    // AXI4-Stream input
    input  logic         axi_clk,                        // AXI input and output clock
    input  logic         axi_tvalid_in,                  // stream data valid
    output logic         axi_tready_in,                  // encoder ready to receive stream data
    input  logic         axi_tline_in,                   // start of line indicator, axi_tuser[0]
    input  logic         axi_tframe_in,                  // start of frame indicator, axi_tuser[1]
    input  logic [191:0] axi_tdata_in,                   // encoded stream input (up to4 pixels per cycle, uncompressed)

    // AXI4-Stream output
    output logic         axi_tvalid_out,                 // stream data valid
    input  logic         axi_tready_out,                 // encoder ready to receive stream data
    output logic         axi_tline_out,                  // start of line indicator, axi_tuser[0]
    output logic         axi_tframe_out,                 // start of frame indicator, axi_tuser[1]
    output logic [191:0] axi_tdata_out,                  // encoded stream output (4 pixels per cycle)

    // BIST connections
    input  logic [11:0]  bist_sram_in  [pSLICE_PROCESSOR_COUNT*4+1:0], // BIST input
    output logic [11:0]  bist_sram_out [pSLICE_PROCESSOR_COUNT*4+1:0]  // BIST output
);

    // ------------------------------------------------------------------------------------------------------------
    //                                          internal definitions
    // ------------------------------------------------------------------------------------------------------------
    import dsce_defs_pkg::*;

    logic                   apb_reset_n;
    logic                   axi_reset_n;
    logic                   dsc_reset_n;
    logic                   apb_soft_reset;

    tDSCE_CONFIG            cfg_dsc_encoder;
    tDSCE_CONTROL_STATUS    cfg_dsc_encoder_status;
    tDSCE_SLICE_STATUS      cfg_dsc_slice_status [pSLICE_PROCESSOR_COUNT-1:0];
    tDSCE_INTERRUPT_CONFIG  cfg_dsc_interrupt;
    tDSCE_INTERRUPT_STATUS  cfg_dsc_interrupt_status;
    tDSCE_TIMERS_CONFIG     cfg_dsc_timers_config;
    tDSCE_TIMERS_STATUS     cfg_dsc_timers_status;
    logic                   i_cfg_bypass_enable;

    logic                   apb_pps_write;
    logic [6:0]             apb_pps_index;
    logic [7:0]             apb_pps_wdata;
    logic                   apb_pps_commit;
    logic [7:0]             apb_pps_rdata;

    logic                   axi_pps_refresh;
    logic                   axi_pps_refresh_complete;
    logic                   axi_pps_update;
    logic                   axi_new_frame;
    logic                   dsc_pps_update;
    logic                   dsc_new_frame;
    logic                   axi_encoder_enable;
    logic                   dsc_encoder_enable;

    logic                   apb_one_usec_tick;

    tDSC_PPS                cfg_pps;
    tDSC_RCPS               cfg_rcps;


    // ------------------------------------------------------------------------------------------------------------
    //                                          combinatorial process
    // ------------------------------------------------------------------------------------------------------------
    always_comb begin : CombLogic
        i_cfg_bypass_enable = ~cfg_dsc_encoder_status.encoder_active;
    end : CombLogic


    // ------------------------------------------------------------------------------------------------------------
    //                                          component instantiations
    // ------------------------------------------------------------------------------------------------------------

    // ----------------------------------------------
    //  APB host interface
    // ----------------------------------------------
    dsce_apb
    #(
        .pSPC                       (pSLICE_PROCESSOR_COUNT),
        .pINCLUDE_BLOCK_PREDICTION  (pINCLUDE_BLOCK_PREDICTION),
        .pMAX_SLICE_LINE_SIZE       (pMAX_SLICE_LINE_SIZE)
    )  dsce_apb_inst
    (
        // apb interface
        .apb_clk                    (apb_clk),
        .apb_reset_n                (apb_reset_n),
        .apb_select                 (apb_select),
        .apb_enable                 (apb_enable),
        .apb_write                  (apb_write),
        .apb_strobe                 (apb_strobe),
        .apb_protect                (apb_protect),
        .apb_addr                   (apb_addr),
        .apb_wdata                  (apb_wdata),
        .apb_ready                  (apb_ready),
        .apb_slave_error            (apb_slave_error),
        .apb_rdata                  (apb_rdata),
        // PPS access interface
        .apb_pps_write              (apb_pps_write),
        .apb_pps_index              (apb_pps_index),
        .apb_pps_wdata              (apb_pps_wdata),
        .apb_pps_commit             (apb_pps_commit),
        .apb_pps_rdata              (apb_pps_rdata),
        // internal register assignments and control signals
        .cfg_dsc_encoder            (cfg_dsc_encoder),
        .cfg_dsc_encoder_status     (cfg_dsc_encoder_status),
        .cfg_dsc_interrupt          (cfg_dsc_interrupt),
        .cfg_dsc_interrupt_status   (cfg_dsc_interrupt_status),
        .cfg_dsc_timers_config      (cfg_dsc_timers_config),
        .cfg_dsc_timers_status      (cfg_dsc_timers_status),
        .apb_soft_reset             (apb_soft_reset)
    );

    // ----------------------------------------------
    //  host timer(s)
    // ----------------------------------------------
    dsce_timers  dsce_timers_inst
    (
        // apb clock domain
        .apb_clk                    (apb_clk),
        .apb_reset_n                (apb_reset_n),
        .apb_timer_tick             (apb_one_usec_tick),
        // timer control and status
        .cfg_dsc_timers_config      (cfg_dsc_timers_config),
        .cfg_dsc_timers_status      (cfg_dsc_timers_status)
    );

    // ----------------------------------------------
    //  interrupt controller
    // ----------------------------------------------
    dsce_interrupt
    #(
        .pSPC                       (pSLICE_PROCESSOR_COUNT)
    )  dsce_interrupt_inst
    (
        // clock, reset, config and status
        .apb_clk                    (apb_clk),
        .apb_reset_n                (apb_reset_n),
        .cfg_dsc_interrupt          (cfg_dsc_interrupt),
        .cfg_dsc_interrupt_status   (cfg_dsc_interrupt_status),
        // internal event detection status flags
        .cfg_dsc_encoder_status     (cfg_dsc_encoder_status),
        .cfg_dsc_slice_status       (cfg_dsc_slice_status),
        .cfg_dsc_timers_status      (cfg_dsc_timers_status),
        // host interface interrupt output
        .apb_int                    (apb_int)
    );


    // ----------------------------------------------
    //  picture parameter set
    // ----------------------------------------------
    dsce_pps  dsce_pps_inst
    (
        // apb clock domain
        .apb_clk                    (apb_clk),
        .apb_reset_n                (apb_reset_n),
        // read/write interface from the APB host
        .apb_pps_write              (apb_pps_write),
        .apb_pps_index              (apb_pps_index),
        .apb_pps_wdata              (apb_pps_wdata),
        .apb_pps_commit             (apb_pps_commit),
        .apb_pps_rdata              (apb_pps_rdata),
        // encode engine interface
        .axi_clk                    (axi_clk),
        .axi_reset_n                (axi_reset_n),
        .axi_pps_refresh            (axi_pps_refresh),
        .axi_pps_refresh_complete   (axi_pps_refresh_complete),
        .cfg_pps                    (cfg_pps),
        .cfg_rcps                   (cfg_rcps),
        // bist interface
        .bist_sram_in               (bist_sram_in[pSLICE_PROCESSOR_COUNT*4+1:pSLICE_PROCESSOR_COUNT*4]),
        .bist_sram_out              (bist_sram_out[pSLICE_PROCESSOR_COUNT*4+1:pSLICE_PROCESSOR_COUNT*4])
    );


    // ----------------------------------------------
    //  command processor
    // ----------------------------------------------
    dsce_command  dsce_command_inst
    (
        // clock domains and resets
        .axi_clk                    (axi_clk),
        .axi_reset_n                (axi_reset_n),
        .dsc_clk                    (dsc_clk),
        .dsc_reset_n                (dsc_reset_n),
        // source input
        .axi_tframe_in              (axi_tframe_in),
        // host interface config and pps management
        .cfg_dsc_encoder            (cfg_dsc_encoder),
        .axi_pps_refresh            (axi_pps_refresh),
        .axi_pps_refresh_complete   (axi_pps_refresh_complete),
        // status input and output
        .cfg_dsc_encoder_status     (cfg_dsc_encoder_status),
        // control outputs
        .apb_one_usec_tick          (apb_one_usec_tick),
        .axi_encoder_enable         (axi_encoder_enable),
        .axi_pps_update             (axi_pps_update),
        .axi_new_frame              (axi_new_frame),
        .dsc_encoder_enable         (dsc_encoder_enable),
        .dsc_pps_update             (dsc_pps_update),
        .dsc_new_frame              (dsc_new_frame)
    );


    // ----------------------------------------------
    //  reset controller
    // ----------------------------------------------
    dsce_reset  dsce_reset_inst
    (
        // apb clock domain
        .apb_clk                    (apb_clk),
        .axi_clk                    (axi_clk),
        .dsc_clk                    (dsc_clk),
        // core reset
        .async_reset_n              (async_reset_n),
        .apb_soft_reset             (apb_soft_reset),
        .async_test_mode            (async_test_mode),
        // reset outputs
        .apb_reset_n                (apb_reset_n),
        .axi_reset_n                (axi_reset_n),
        .dsc_reset_n                (dsc_reset_n)
    );


    // ----------------------------------------------
    //  encode engine
    // ----------------------------------------------
    dsce_engine
    #(
        .pSPC                       (pSLICE_PROCESSOR_COUNT),
        .pINCLUDE_BLOCK_PREDICTION  (pINCLUDE_BLOCK_PREDICTION),
        .pMAX_SLICE_LINE_SIZE       (pMAX_SLICE_LINE_SIZE),
        .pDEBUG_MESSAGES            (pDEBUG_MESSAGES)
    )  dsce_engine_inst
    (
        // control interface
        .dsc_clk                    (dsc_clk),
        .dsc_reset_n                (dsc_reset_n),
        .dsc_encoder_enable         (dsc_encoder_enable),
        .cfg_bypass_enable          (i_cfg_bypass_enable),
        .cfg_dsc_slice_status       (cfg_dsc_slice_status),
        // host interface
        .apb_clk                    (apb_clk),
        .apb_reset_n                (apb_reset_n),
        .cfg_dsc_encoder            (cfg_dsc_encoder),
        .axi_encoder_enable         (axi_encoder_enable),
        .axi_pps_update             (axi_pps_update),
        .dsc_pps_update             (dsc_pps_update),
        .axi_new_frame              (axi_new_frame),
        .dsc_new_frame              (dsc_new_frame),
        .cfg_pps                    (cfg_pps),
        .cfg_rcps                   (cfg_rcps),
        // AXI4-Stream input
        .axi_clk                    (axi_clk),
        .axi_reset_n                (axi_reset_n),
        .axi_tvalid_in              (axi_tvalid_in),
        .axi_tready_in              (axi_tready_in),
        .axi_tline_in               (axi_tline_in),
        .axi_tframe_in              (axi_tframe_in),
        .axi_tdata_in               (axi_tdata_in),
        // AXI4-Stream output
        .axi_tvalid_out             (axi_tvalid_out),
        .axi_tready_out             (axi_tready_out),
        .axi_tline_out              (axi_tline_out),
        .axi_tframe_out             (axi_tframe_out),
        .axi_tdata_out              (axi_tdata_out),
        // BIST connections
        .bist_sram_in               (bist_sram_in[pSLICE_PROCESSOR_COUNT*4-1:0]),
        .bist_sram_out              (bist_sram_out[pSLICE_PROCESSOR_COUNT*4-1:0])
    );

endmodule : dsc_encoder


