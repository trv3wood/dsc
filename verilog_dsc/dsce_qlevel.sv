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
//     DESCRIPTION : Map the primaryQp value to the associated qlevel.  This block contains
//                   no pipeline stages for the lookup but does allow for loading through
//                   the APB interface.  This allows for the lookup to occur in a single
//                   level of logic rather than a multiple stage table based on selects.
// ------------------------------------------------------------------------------------------------

// ----------------------------------------------
//  includes
// ----------------------------------------------
import dsce_defs_pkg::*;


// ----------------------------------------------
//  entity declaration
// ----------------------------------------------
module dsce_qlevel
(
    // clock and control interface
    input  logic                    apb_clk,                    // APB host domain
    input  logic                    apb_reset_n,                // APB domain reset
    input  logic [3:0]              cfg_bits_per_component,     // PPS value for bpc
    input  logic                    cfg_convert_rgb,            // csc active
    input  logic [3:0]              cfg_dsc_version_minor,      // dsc revision level

    // lookup path
    input  logic                    dsc_clk,                    // encoder clock
    input  logic                    dsc_reset_n,                // dsc domain reset
    input  logic                    dsc_pps_update,             // update pps parameters flag
    input  logic                    dsc_qp_valid_in,            // input group valid
    input  tDSC_QLEVEL              dsc_primary_qp,             // primary QP value

    // qlevel generation for various processing phases
    output tDSC_QLEVEL              dsc_primary_qp_res,         // primary QP value, residual phase
    output tDSC_QLEVEL              dsc_qlevel_y,               // qlevel output, y
    output tDSC_QLEVEL              dsc_qlevel_c,               // qlevel output, c
    output tDSC_QLEVEL              dsc_qlevel_y_res,           // qlevel, residuals, y
    output tDSC_QLEVEL              dsc_qlevel_c_res            // qlevel, residuals, c
);

    // ------------------------------------------------------------------------------------------------------------
    //                                          internal definitions
    // ------------------------------------------------------------------------------------------------------------

    logic   [2:1]                   i_pipeline_stage;
    logic                           i_convert_rgb;
    logic   [3:0]                   i_bits_per_component;
    logic   [3:0]                   i_dsc_version_minor;
    tDSC_QLEVEL                     i_qlevel_c;

    // ------------------------------------------------------------------------------------------------------------
    //                                             processes
    // ------------------------------------------------------------------------------------------------------------

    // -------------------------------------------------------
    //  locally register picture parameters for routing
    // -------------------------------------------------------
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : ConfigParameters
        if (dsc_reset_n == 1'b0) begin
            i_convert_rgb <= 1'b0;
            i_bits_per_component <= 4'd0;
            i_dsc_version_minor <= 4'd0;

        end else begin

            // ----- pps parameters ----- //
            if (dsc_pps_update == 1'b1) begin
                i_bits_per_component <= cfg_bits_per_component;
                i_convert_rgb <= cfg_convert_rgb;
                i_dsc_version_minor <= cfg_dsc_version_minor;
            end // if

        end // if
    end : ConfigParameters

    // -------------------------------------------------------
    //  asynchronous table lookup
    // -------------------------------------------------------
    always_comb begin : TableLookup
        dsc_qlevel_y = dsce_qp_to_qlevel(kBPC_Y_FLAG, i_bits_per_component, dsc_primary_qp);
        i_qlevel_c = dsce_qp_to_qlevel(kBPC_C_FLAG, i_bits_per_component, dsc_primary_qp);

        if (i_dsc_version_minor == 4'd2 && i_convert_rgb == 1'b0) begin
            dsc_qlevel_c = (i_qlevel_c == 5'd0) ? 5'd0 : i_qlevel_c - 5'd1;
        end else begin
            dsc_qlevel_c = i_qlevel_c;
        end // if
    end : TableLookup


    // -------------------------------------------------------
    //  clocked qlevel output in the dsc domain
    // -------------------------------------------------------
    always @(posedge dsc_clk or negedge dsc_reset_n) begin : ResidualPhaseQLevel
        if (dsc_reset_n == 1'b0) begin
            dsc_qlevel_y_res <= kDSC_QLEVEL_ZERO;
            dsc_qlevel_c_res <= kDSC_QLEVEL_ZERO;
            dsc_primary_qp_res <= kDSC_QLEVEL_ZERO;

            i_pipeline_stage <= 2'b00;

        end else begin

            i_pipeline_stage <= {i_pipeline_stage[1], dsc_qp_valid_in};

            if (i_pipeline_stage[2] == 1'b1) begin
                dsc_qlevel_y_res <= dsc_qlevel_y;
                dsc_qlevel_c_res <= dsc_qlevel_c;
                dsc_primary_qp_res <= dsc_primary_qp;
            end // if
        end // if
    end : ResidualPhaseQLevel


endmodule : dsce_qlevel

