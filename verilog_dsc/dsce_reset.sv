// ------------------------------------------------------------------------------------------------
//     COPYRIGHT © 2015-2021, TRILINEAR TECHNOLOGIES, INC.
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
//     DESCRIPTION : Generate proper resets from the global core reset.  The external core
//                   reset is considered to by asychronous.
// ------------------------------------------------------------------------------------------------



// ----------------------------------------------
//  module declaration
// ----------------------------------------------
module dsce_reset
(
    // apb clock domain
    input  logic        apb_clk,                        // APB bus clock
    input  logic        axi_clk,                        // AXI bus clock
    input  logic        dsc_clk,                        // encoder clock

    // core reset
    input  logic        async_reset_n,                  // async core reset
    input  logic        apb_soft_reset,                 // soft resets
    input  logic        async_test_mode,                // enable test mode

    // reset outputs
    output logic        apb_reset_n,                    // host interface reset
    output logic        axi_reset_n,                    // AXI domain reset
    output logic        dsc_reset_n                     // encoder domain reset
);
    // ------------------------------------------------------------------------------------------------------------
    //                                          internal definitions
    // ------------------------------------------------------------------------------------------------------------

    // ---------------------------------------------
    // internal signal definitions
    // ---------------------------------------------
    logic [7:0]       i_apb_reset_sr;                         // APB host interface reset shift register
    logic [7:0]       i_axi_reset_sr;                         // AXI reset shift register
    logic [7:0]       i_dsc_reset_sr;                         // encoder reset shift register
    logic [7:0]       i_axi_reset_soft;                       // soft link reset
    logic             i_combined_axi_reset_n;                   // combined AXI reset
    logic             i_combined_dsc_reset_n;                   // combined DSC reset

    // ------------------------------------------------------------------------------------------------------------
    //                                          process assignments
    // ------------------------------------------------------------------------------------------------------------

    // --------------------------------------------------------------------------
    //  map the high bit of the shift register to the reset output
    // --------------------------------------------------------------------------
    always_comb begin : SigMap
        // map the top bits of the shift register to the reset
        apb_reset_n = (async_test_mode == 1'b1) ? async_reset_n : i_apb_reset_sr[7];
        axi_reset_n = (async_test_mode == 1'b1) ? async_reset_n : i_axi_reset_sr[7];
        dsc_reset_n = (async_test_mode == 1'b1) ? async_reset_n : i_dsc_reset_sr[7];
    end : SigMap


    // --------------------------------------------------------------------------
    //  Host interface reset
    // --------------------------------------------------------------------------
    always@(posedge apb_clk or negedge async_reset_n) begin : APBReset
        if (async_reset_n == 1'b0) begin
            i_apb_reset_sr <= 8'h00;
            i_axi_reset_soft <= 8'h00;

        end else begin
            i_apb_reset_sr <= {i_apb_reset_sr[6:0], 1'b1};

            if (apb_soft_reset == 1'b1)  begin
                i_axi_reset_soft <= 8'h00;
            end else begin
                i_axi_reset_soft <= {i_axi_reset_soft[6:0], 1'b1};
            end // if
        end // if
    end : APBReset


    // --------------------------------------------------------------------------
    //  AXI reset
    // --------------------------------------------------------------------------
    assign i_combined_axi_reset_n = (async_test_mode == 1'b0) ? async_reset_n & i_axi_reset_soft[7] : async_reset_n;

    always@(posedge axi_clk or negedge i_combined_axi_reset_n) begin : AXIReset
        if (i_combined_axi_reset_n == 1'b0) begin
            i_axi_reset_sr <= 8'h00;
        end else begin
            i_axi_reset_sr <= {i_axi_reset_sr[6:0], 1'b1};
        end // if
    end : AXIReset


    // --------------------------------------------------------------------------
    //  Encoder engine reset
    // --------------------------------------------------------------------------
    assign i_combined_dsc_reset_n = (async_test_mode == 1'b0) ? async_reset_n & i_axi_reset_soft[7] : async_reset_n;

    always@(posedge dsc_clk or negedge i_combined_dsc_reset_n) begin : DSCReset
        if (i_combined_dsc_reset_n == 1'b0) begin
            i_dsc_reset_sr <= 8'h00;
        end else begin
            i_dsc_reset_sr <= {i_dsc_reset_sr[6:0], 1'b1};
        end // if
    end : DSCReset

endmodule : dsce_reset


