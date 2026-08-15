// ------------------------------------------------------------------------------------------------
//     COPYRIGHT © 2015-2022, TRILINEAR TECHNOLOGIES, INC.
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
//     DESCRIPTION : Interrupt controller for the standalone DSC encoder implementation.
// ------------------------------------------------------------------------------------------------

// ----------------------------------------------
//  includes
// ----------------------------------------------
import dsce_defs_pkg::*;
import dsce_regdefs_pkg::*;


// ----------------------------------------------
//  module declaration
// ----------------------------------------------
module dsce_interrupt
#(
    parameter int pSPC = 4                                              // slice processor count
)
(
    // clock, reset, config and status
    input  logic                    apb_clk,                            // APB bus clock
    input  logic                    apb_reset_n,                        // domain reset
    input  tDSCE_INTERRUPT_CONFIG   cfg_dsc_interrupt,                  // interrupt config
    output tDSCE_INTERRUPT_STATUS   cfg_dsc_interrupt_status,           // interrupt status

    // internal event detection status flags
    input  tDSCE_CONTROL_STATUS     cfg_dsc_encoder_status,             // encoder operating status
    input  tDSCE_SLICE_STATUS       cfg_dsc_slice_status [pSPC-1:0],    // encoder operating status
    input  tDSCE_TIMERS_STATUS      cfg_dsc_timers_status,              // host timer status

    // host interface interrupt output
    output logic                    apb_int                             // host interrupt, active high
);
    // ------------------------------------------------------------------------------------------------------------
    //                                          internal definitions
    // ------------------------------------------------------------------------------------------------------------

    // interrupt states
    logic [6:0]         i_int_pending;
    logic [6:0]         i_int_detected;
    logic [7:0]         i_input_frame_count;
    logic               i_check_frame_count;

    // sync stages
    logic [1:0]         i_sync_end_frame;
    logic [1:0]         i_sync_rate_error;
    logic [1:0]         i_sync_timeout;
    logic [1:0]         i_sync_timer_int;
    logic [pSPC-1:0]    i_sync_slice_overflow;

    //  interrupt bit field definitions
    localparam int kDSCE_INT_SLICE_ERROR_INDEX      = 6;
    localparam int kDSCE_INT_TIMER_INDEX            = 5;
    localparam int kDSCE_INT_FRAME_COUNT_INDEX      = 4;
    localparam int kDSCE_INT_RATE_ERROR_INDEX       = 3;
    localparam int kDSCE_INT_END_OF_FRAME_INDEX     = 2;
    localparam int kDSCE_INT_END_OF_SLICE_INDEX     = 1;
    localparam int kDSCE_INT_ENCODER_TIMEOUT_INDEX  = 0;


    // ------------------------------------------------------------------------------------------------------------
    //                                          functional processes
    // ------------------------------------------------------------------------------------------------------------

    // --------------------------------------------------------------------------
    //  internal signal assignments
    // --------------------------------------------------------------------------
    always_comb begin : SignalMap
        cfg_dsc_interrupt_status.cause = i_int_pending;
        cfg_dsc_interrupt_status.state = i_int_detected;
        cfg_dsc_interrupt_status.encoded_frame_count = i_input_frame_count;
    end : SignalMap


    // --------------------------------------------------------------------------
    //  interrupt handler logic
    // --------------------------------------------------------------------------
    always_ff@(posedge apb_clk or negedge apb_reset_n) begin : InterruptHandler
        if (apb_reset_n == 1'b0) begin
            apb_int <= 1'b0;

            i_input_frame_count <= 8'h00;
            i_int_detected <= 7'h00;
            i_int_pending <= 7'h00;
            i_check_frame_count <= 1'b0;

        end else begin

            // default signal states
            i_check_frame_count <= 1'b0;

            // frame count detection and frame interrupt
            if (cfg_dsc_interrupt.clear_frame_count == 1'b1) begin
                i_input_frame_count <= 8'd0;
            end else if (i_sync_end_frame[1] != i_sync_end_frame[0]) begin
                i_input_frame_count <= i_input_frame_count + 8'd1;
                i_check_frame_count <= 1'b1;
            end // if

            if (cfg_dsc_interrupt.clear == 1'b1) begin
                i_int_detected[kDSCE_INT_FRAME_COUNT_INDEX] <= 1'b0;
            end else if (i_check_frame_count == 1'b1 && i_input_frame_count == cfg_dsc_interrupt.int_frame_count) begin
                i_int_detected[kDSCE_INT_FRAME_COUNT_INDEX] <= 1'b1;
            end // if

            if (cfg_dsc_interrupt.clear == 1'b1) begin
                i_int_detected[kDSCE_INT_END_OF_FRAME_INDEX] <= 1'b0;
            end else if (i_sync_end_frame[1] != i_sync_end_frame[0]) begin
                i_int_detected[kDSCE_INT_END_OF_FRAME_INDEX] <= 1'b1;
            end // if

            // end of slice (deprecated)
            i_int_detected[kDSCE_INT_END_OF_SLICE_INDEX] <= 1'b0;

            // rate buffer error
            if (cfg_dsc_interrupt.clear == 1'b1) begin
                i_int_detected[kDSCE_INT_RATE_ERROR_INDEX] <= 1'b0;
            end else if (i_sync_rate_error[1] != i_sync_rate_error[0]) begin
                i_int_detected[kDSCE_INT_RATE_ERROR_INDEX] <= 1'b1;
            end // if

            // timeout detected
            if (cfg_dsc_interrupt.clear == 1'b1) begin
                i_int_detected[kDSCE_INT_ENCODER_TIMEOUT_INDEX] <= 1'b0;
            end else if (i_sync_timeout[1] != i_sync_timeout[0]) begin
                i_int_detected[kDSCE_INT_ENCODER_TIMEOUT_INDEX] <= 1'b1;
            end // if

            // timer interrupt
            if (cfg_dsc_interrupt.clear == 1'b1) begin
                i_int_detected[kDSCE_INT_TIMER_INDEX] <= 1'b0;
            end else if (i_sync_timer_int[1] != i_sync_timer_int[0]) begin
                i_int_detected[kDSCE_INT_TIMER_INDEX] <= 1'b1;
            end // if

            // slice overflow interrupt
            if (cfg_dsc_interrupt.clear == 1'b1) begin
                i_int_detected[kDSCE_INT_SLICE_ERROR_INDEX] <= 1'b0;
            end else if (i_sync_slice_overflow != {pSPC{1'b0}}) begin
                i_int_detected[kDSCE_INT_SLICE_ERROR_INDEX] <= 1'b1;
            end // if

            // combine the detection with the enables
            i_int_pending <= i_int_detected & cfg_dsc_interrupt.enable;

            // send the host interrupt
            if (cfg_dsc_interrupt.clear == 1'b1) begin
                apb_int <= 1'b0;
            end else if (i_int_pending != 7'h00) begin
                apb_int <= 1'b1;
            end // if
        end // if
    end : InterruptHandler


    // --------------------------------------------------------------------------
    //  sync stages
    // --------------------------------------------------------------------------
    gprim_sync2_stage sync_frame_inst   (.sync_clk (apb_clk), .reset_n (apb_reset_n), .async_in (cfg_dsc_encoder_status.end_of_frame),    .sync_out (i_sync_end_frame));
    gprim_sync2_stage sync_timeout_inst (.sync_clk (apb_clk), .reset_n (apb_reset_n), .async_in (cfg_dsc_encoder_status.encoder_timeout), .sync_out (i_sync_timeout));
    gprim_sync2_stage sync_error_inst   (.sync_clk (apb_clk), .reset_n (apb_reset_n), .async_in (cfg_dsc_encoder_status.rate_error),      .sync_out (i_sync_rate_error));
    gprim_sync2_stage sync_timer_inst   (.sync_clk (apb_clk), .reset_n (apb_reset_n), .async_in (cfg_dsc_timers_status.timer_interrupt),  .sync_out (i_sync_timer_int));

    generate for (genvar gx = 0; gx < pSPC; gx++) begin : gen_overflow_sync
        gprim_sync_stage  syn_overflow_inst (.sync_clk (apb_clk), .reset_n (apb_reset_n), .async_in (cfg_dsc_slice_status[gx].slice_overflow), .sync_out (i_sync_slice_overflow[gx]));
    end endgenerate // gen_overflow_sync

endmodule : dsce_interrupt


