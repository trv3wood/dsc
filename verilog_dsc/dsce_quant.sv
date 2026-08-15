// ------------------------------------------------------------------------------------------------
//     COPYRIGHT © 2015-2018, TRILINEAR TECHNOLOGIES, INC.
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
//     DESCRIPTION : DSC encoder quantization and inverse quantization block.
// ------------------------------------------------------------------------------------------------

// ----------------------------------------------
//  includes
// ----------------------------------------------
import dsce_defs_pkg::*;

// ----------------------------------------------
//  entity declaration
// ----------------------------------------------
module dsce_qaunt
#(
    parameter pCOLOR_SELECT = 0                        // select chroma plane processing
)
(
    // clock and control interface
    input  logic               dsc_clk,                // DSC processing clock
    input  logic               dsc_reset,              // DSC domain reset
                                                       
    // input samples                                   
    input  logic               dsc_valid_in,           // valid data in
    input  tDSC_SAMPLE [2:0]   dsc_group_in,           // source group input
    input  tDSC_SAMPLE [2:0]   dsc_predict_in,         // predicted group input

    input  tDSC_QLEVEL         dsc_qlevel,             // color specific qlevel value
    input  logic [14:0]        dsc_quant_offset,            // quantization offset
                                                       
    // output predictors                               
    output logic               dsc_valid_out,          // valid predicted pixels out
    output tDSC_SAMPLE [2:0]   dsc_invquant_out,       // inverse quantized group out
    output tDSC_RESIDUAL [2:0] dsc_quant_residual_out  // quantized residuals
);

    // ------------------------------------------------------------------------------------------------------------
    //                                          internal definitions
    // ------------------------------------------------------------------------------------------------------------

    logic signed [16:0] i_quant_offset;
    tDSC_RESIDUAL [2:0] i_residual;
    tDSC_RESIDUAL [2:0] i_quant_residual;

    int rx, px;

    // ------------------------------------------------------------------------------------------------------------
    //                                             processes
    // ------------------------------------------------------------------------------------------------------------

    always_comb begin : CombLogic
        i_quant_offset = {2'b00, dsc_quant_offset};

        for (rx = 0; rx < 3; rx++ )  begin
            i_residual[rx] = dsce_compute_residual(dsc_group_in[rx], dsc_predict_in[rx]);
            if (i_residual[px][16] == 1'b0) begin
                i_quant_residual[px] = (i_residual[px] + i_quant_offset) >> dsc_qlevel;
            end else begin
                i_quant_residual[px] = -((i_quant_offset - i_residual[px]) >> dsc_qlevel);
            end // if
        end // loop
    end : CombLogic


    // quantization logic
    always@(posedge dsc_clk) begin : Quant
        if (dsc_reset == 1'b1) begin
            dsc_valid_out <= dsc_valid_in;
            dsc_invquant_out <= '{default: kDSC_SAMPLE_INIT};
            dsc_quant_residual_out <= '{default: kDSC_RESIDUAL_INIT};
        end else begin
    
            for (px = 0; px < 3; px++) begin
                dsc_invquant_out[px] <= dsc_group_in[px] + i_residual[px];
                dsc_quant_residual_out[px] <= i_quant_residual[px];
            end // loop

        end // if
    end : Quant

endmodule : dsce_qaunt

