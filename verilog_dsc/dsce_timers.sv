// ------------------------------------------------------------------------------------------------
//     COPYRIGHT © 2018-2021, TRILINEAR TECHNOLOGIES, INC.
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
//     DESCRIPTION : Dedicated timers block for the DSC encoder core.  This
//                   block implements a 24-bit timer with auto-reload capability.  The reference
//                   for the timer is a 1 usec clock tick.
// ------------------------------------------------------------------------------------------------

// ----------------------------------------------
//  includes
// ----------------------------------------------
import dsce_defs_pkg::*;


// ----------------------------------------------
//  module declaration
// ----------------------------------------------
module dsce_timers
(
    // apb clock domain
    input  logic                apb_clk,                // APB bus clock
    input  logic                apb_reset_n,            // APB sync reset
    input  logic                apb_timer_tick,         // single clock pulse

    // timer control and status
    input  tDSCE_TIMERS_CONFIG  cfg_dsc_timers_config,  // timers config
    output tDSCE_TIMERS_STATUS  cfg_dsc_timers_status   // timers status
);
    // ------------------------------------------------------------------------------------------------------------
    //                                          internal definitions
    // ------------------------------------------------------------------------------------------------------------

    logic   [23:0]              i_timer_value;
    logic                       i_timer_interrupt;
    logic                       i_timer_enable;

    // ------------------------------------------------------------------------------------------------------------
    //                                          process assignments
    // ------------------------------------------------------------------------------------------------------------

    // --------------------------------------------------------------------------
    //  map the high bit of the shift register to the reset output
    // --------------------------------------------------------------------------
    always_comb begin : SigMap
        cfg_dsc_timers_status.timer_value = i_timer_value;
        cfg_dsc_timers_status.timer_interrupt = i_timer_interrupt;
    end : SigMap


    // --------------------------------------------------------------------------
    //  timer management block
    // --------------------------------------------------------------------------
    always_ff@(posedge apb_clk or negedge apb_reset_n) begin : TimerManagement
        if (apb_reset_n == 1'b0) begin
            i_timer_value <= 24'd0;
            i_timer_interrupt <= 1'b0;
            i_timer_enable <= 1'b0;

        end else begin

            // delay timer enable to allow set of the timer and enable in one cycle
            i_timer_enable <= cfg_dsc_timers_config.timer_enable;

            // timer count management
            if (i_timer_enable == 1'b0) begin
                i_timer_value <= cfg_dsc_timers_config.reload_value;
            end else if (apb_timer_tick == 1'b1) begin
                // timer count and reload
                if (i_timer_value == 24'd0) begin
                    if (cfg_dsc_timers_config.autoreload == 1'b1) begin
                        i_timer_value <= cfg_dsc_timers_config.reload_value;
                    end // if
                end else begin
                    i_timer_value <= i_timer_value - 24'd1;
                end // if
            end // if

            // interrupt toggle flag
            if (i_timer_enable == 1'b1 && i_timer_value == 24'd1 && cfg_dsc_timers_config.interrupt_enable == 1'b1) begin
                i_timer_interrupt <= 1'b1;
            end else begin
                i_timer_interrupt <= 1'b0;
            end // if

        end // if
    end : TimerManagement


endmodule : dsce_timers


