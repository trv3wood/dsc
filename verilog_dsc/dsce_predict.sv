// ------------------------------------------------------------------------------------------------
//     COPYRIGHT © 2015-2023 TRILINEAR TECHNOLOGIES, INC.
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
//     DESCRIPTION : Top level for the prediction block.  MP, MMAP and block prediction
//                   are supported with optional build support for BP.
// ------------------------------------------------------------------------------------------------

// ----------------------------------------------
//  includes
// ----------------------------------------------
import dsce_defs_pkg::*;


// ----------------------------------------------
//  entity declaration
// ----------------------------------------------
module dsce_predict
#(
    parameter int pINCLUDE_BLOCK_PREDICTION = 1                // includes support for block prediction
)
(
    // clock and control interface
    input  logic                 dsc_clk,                      // DSC processing clock
    input  logic                 dsc_reset_n,                  // DSC domain reset
    input  tDSCE_CONFIG          cfg_dsc_encoder,              // general encoder configuration
    input  logic                 dsc_pps_update,               // update pps parameters flag
    input  tDSC_PPS              cfg_pps,                      // parameter set output array

    // input data path
    input  logic                 dsc_start_of_slice,           // start of new slice flag
    input  logic                 dsc_group_valid_in,           // valid data in
    input  logic                 dsc_group_last_in,            // last group in the slice
    input  tDSC_PIXEL            dsc_group_in [2:0],           // current source group
    input  tDSC_PIXEL            dsc_right_in,                 // right pixel from the previous group
    input  tDSC_PIXEL            dsc_recon_group_in [2:0],     // 上一组重建像素反馈

    // entropy feedback and rate control
    input  tDSC_PIXEL            dsc_line_prev_in [5:0],       // pixels from the previous line
    input  tDSC_QLEVEL           dsc_qlevel_y,                 // luma channel quantization level
    input  tDSC_QLEVEL           dsc_qlevel_c,                 // chroma channel quantization level

    // residual outputs
    output logic                 dsc_group_valid_out,          // valid predicted pixels out
    output logic                 dsc_last_out,                 // last flag out
    output logic                 dsc_use_bp_out,               // use block predict output
    output tDSC_PIXEL            dsc_predict_bp_out [2:0],     // block predict
    output tDSC_PIXEL            dsc_predict_mmap_out [2:0],   // mmap predict
    output tDSC_PIXEL            dsc_predict_mpp_out [2:0],    // midpoint predict
    output tDSC_RESIDUAL_PIXEL   dsc_residual_bp_out [2:0],    // block predict residual
    output tDSC_RESIDUAL_PIXEL   dsc_residual_mmap_out [2:0],  // mmap residual out
    output tDSC_RESIDUAL_PIXEL   dsc_residual_mpp_out [2:0]    // midpoint residual out
);

    // ------------------------------------------------------------------------------------------------------------
    //                                          internal definitions
    // ------------------------------------------------------------------------------------------------------------

    //  internal signal definitions
    logic                 i_valid_mpp;
    logic                 i_last_mpp;
    logic                 i_valid_mmap;

    logic                 i_valid_bp;
    logic                 i_last_bp;
    logic [3:0]           i_bp_vector;

    tDSC_PIXEL            i_predict_bp [2:0];
    tDSC_RESIDUAL_PIXEL   i_residual_bp [2:0];

    tDSC_COMPONENT        i_dsc_group_in_y [2:0];
    tDSC_COMPONENT        i_dsc_group_in_co [2:0];
    tDSC_COMPONENT        i_dsc_group_in_cg [2:0];

    tDSC_COMPONENT        i_line_prev_in_y [5:0];
    tDSC_COMPONENT        i_line_prev_in_co [5:0];
    tDSC_COMPONENT        i_line_prev_in_cg [5:0];

    tDSC_COMPONENT        i_mpp_predict_out_y [2:0];
    tDSC_COMPONENT        i_mpp_predict_out_co [2:0];
    tDSC_COMPONENT        i_mpp_predict_out_cg [2:0];
    tDSC_RESIDUAL         i_mpp_residual_out_y [2:0];
    tDSC_RESIDUAL         i_mpp_residual_out_co [2:0];
    tDSC_RESIDUAL         i_mpp_residual_out_cg [2:0];

    tDSC_COMPONENT        i_mmap_predict_out_y [2:0];
    tDSC_COMPONENT        i_mmap_predict_out_co [2:0];
    tDSC_COMPONENT        i_mmap_predict_out_cg [2:0];
    tDSC_RESIDUAL         i_mmap_residual_out_y [2:0];
    tDSC_RESIDUAL         i_mmap_residual_out_co [2:0];
    tDSC_RESIDUAL         i_mmap_residual_out_cg [2:0];


    // ------------------------------------------------------------------------------------------------------------
    //                                             processes
    // ------------------------------------------------------------------------------------------------------------

    // signal assignments
    always_comb begin : SignalMap
        dsc_group_valid_out = i_valid_mpp;
        dsc_last_out = i_last_mpp;
        dsc_predict_bp_out = i_predict_bp;
        dsc_residual_bp_out = i_residual_bp;

        // array maps from the predict blocks
        for (int mpx = 0; mpx < 3; mpx++) begin : MPPAssignLoop
            dsc_predict_mpp_out[mpx].y  = i_mpp_predict_out_y[mpx];
            dsc_predict_mpp_out[mpx].co = i_mpp_predict_out_co[mpx];
            dsc_predict_mpp_out[mpx].cg = i_mpp_predict_out_cg[mpx];

            dsc_residual_mpp_out[mpx].res_y  = i_mpp_residual_out_y[mpx];
            dsc_residual_mpp_out[mpx].res_co = i_mpp_residual_out_co[mpx];
            dsc_residual_mpp_out[mpx].res_cg = i_mpp_residual_out_cg[mpx];
        end : MPPAssignLoop

        for (int mmx = 0; mmx < 3; mmx++) begin : MMAPAssignLoop
            dsc_predict_mmap_out[mmx].y  = i_mmap_predict_out_y[mmx];
            dsc_predict_mmap_out[mmx].co = i_mmap_predict_out_co[mmx];
            dsc_predict_mmap_out[mmx].cg = i_mmap_predict_out_cg[mmx];

            dsc_residual_mmap_out[mmx].res_y  = i_mmap_residual_out_y[mmx];
            dsc_residual_mmap_out[mmx].res_co = i_mmap_residual_out_co[mmx];
            dsc_residual_mmap_out[mmx].res_cg = i_mmap_residual_out_cg[mmx];
        end : MMAPAssignLoop

        for (int dsx = 0; dsx < 3; dsx++) begin : GroupInAssignLoop
            i_dsc_group_in_y[dsx]  = dsc_group_in[dsx].y;
            i_dsc_group_in_co[dsx] = dsc_group_in[dsx].co;
            i_dsc_group_in_cg[dsx] = dsc_group_in[dsx].cg;
        end : GroupInAssignLoop

        for (int prx = 0; prx < 6; prx++) begin : PrevLineAssignLoop
            i_line_prev_in_y[prx]  = dsc_line_prev_in[prx].y;
            i_line_prev_in_co[prx] = dsc_line_prev_in[prx].co;
            i_line_prev_in_cg[prx] = dsc_line_prev_in[prx].cg;
        end : PrevLineAssignLoop
    end : SignalMap


    // ------------------------------------------------------------------------------------------------------------
    //                                   prediction blocks
    // ------------------------------------------------------------------------------------------------------------
`ifdef DSC_MPP_MODEL_SUBSTITUTE
    dsce_mpp_function_model
`else
    dsce_mpp
`endif
    #(
        .pCOMPONENT_SELECT   (0)
    ) dsce_mpp_y_inst
    (
        // clock and control interface
        .dsc_clk                    (dsc_clk),
        .dsc_reset_n                (dsc_reset_n),
        .dsc_pps_update             (dsc_pps_update),
        .cfg_pps                    (cfg_pps),
        // input samples
        .dsc_start_of_slice         (dsc_start_of_slice),
        .dsc_group_valid_in         (dsc_group_valid_in),
        .dsc_group_last_in          (dsc_group_last_in),
        .dsc_group_in               (i_dsc_group_in_y),
        .dsc_right_in               (dsc_right_in.y),
        .dsc_qlevel                 (dsc_qlevel_y),
        // output predictors
        .dsc_predict_valid_out      (i_valid_mpp),
        .dsc_predict_last_out       (i_last_mpp),
        .dsc_predict_out            (i_mpp_predict_out_y),
        .dsc_residual_out           (i_mpp_residual_out_y)
    );


`ifdef DSC_MPP_MODEL_SUBSTITUTE
    dsce_mpp_function_model
`else
    dsce_mpp
`endif
    #(
        .pCOMPONENT_SELECT   (1)
    ) dsce_mpp_co_inst
    (
        // clock and control interface
        .dsc_clk                    (dsc_clk),
        .dsc_reset_n                (dsc_reset_n),
        .dsc_pps_update             (dsc_pps_update),
        .cfg_pps                    (cfg_pps),
        // input samples
        .dsc_start_of_slice         (dsc_start_of_slice),
        .dsc_group_valid_in         (dsc_group_valid_in),
        .dsc_group_last_in          (dsc_group_last_in),
        .dsc_group_in               (i_dsc_group_in_co),
        .dsc_right_in               (dsc_right_in.co),
        .dsc_qlevel                 (dsc_qlevel_c),
        // output predictors
        .dsc_predict_valid_out      (),
        .dsc_predict_last_out       (),
        .dsc_predict_out            (i_mpp_predict_out_co),
        .dsc_residual_out           (i_mpp_residual_out_co)
    );


`ifdef DSC_MPP_MODEL_SUBSTITUTE
    dsce_mpp_function_model
`else
    dsce_mpp
`endif
    #(
        .pCOMPONENT_SELECT          (2)
    ) dsce_mpp_cg_inst
    (
        // clock and control interface
        .dsc_clk                   (dsc_clk),
        .dsc_reset_n               (dsc_reset_n),
        .dsc_pps_update            (dsc_pps_update),
        .cfg_pps                   (cfg_pps),
        // input samples
        .dsc_start_of_slice        (dsc_start_of_slice),
        .dsc_group_valid_in        (dsc_group_valid_in),
        .dsc_group_last_in         (dsc_group_last_in),
        .dsc_group_in              (i_dsc_group_in_cg),
        .dsc_right_in              (dsc_right_in.cg),
        .dsc_qlevel                (dsc_qlevel_c),
        // output predictors
        .dsc_predict_valid_out     (),
        .dsc_predict_last_out      (),
        .dsc_predict_out           (i_mpp_predict_out_cg),
        .dsc_residual_out          (i_mpp_residual_out_cg)
    );


    dsce_mmap
    #(
        .pCOMPONENT_SELECT  (0)
    ) dsce_mmap_y_inst
    (
        // clock and control interface
        .dsc_clk                    (dsc_clk),
        .dsc_reset_n                (dsc_reset_n),
        .dsc_pps_update             (dsc_pps_update),
        .cfg_pps                    (cfg_pps),
        // input samples
        .dsc_group_valid_in         (dsc_group_valid_in),
        .dsc_group_last_in          (dsc_group_last_in),
        .dsc_start_of_slice         (dsc_start_of_slice),
        .dsc_line_prev_in           (i_line_prev_in_y),
        .dsc_group_in               (i_dsc_group_in_y),
        .dsc_right_in               (dsc_right_in.y),
        .dsc_qlevel                 (dsc_qlevel_y),
        // output predictors
        .dsc_valid_out              (i_valid_mmap),
        .dsc_predict_out            (i_mmap_predict_out_y),
        .dsc_residual_out           (i_mmap_residual_out_y)
    );


    dsce_mmap
    #(
        .pCOMPONENT_SELECT  (1)
    ) dsce_mmap_co_inst
    (
        // clock and control interface
        .dsc_clk                    (dsc_clk),
        .dsc_reset_n                (dsc_reset_n),
        .dsc_pps_update             (dsc_pps_update),
        .cfg_pps                    (cfg_pps),
        // input samples
        .dsc_group_valid_in         (dsc_group_valid_in),
        .dsc_group_last_in          (dsc_group_last_in),
        .dsc_start_of_slice         (dsc_start_of_slice),
        .dsc_line_prev_in           (i_line_prev_in_co),
        .dsc_group_in               (i_dsc_group_in_co),
        .dsc_right_in               (dsc_right_in.co),
        .dsc_qlevel                 (dsc_qlevel_c),
        // output predictors
        .dsc_valid_out              (),
        .dsc_predict_out            (i_mmap_predict_out_co),
        .dsc_residual_out           (i_mmap_residual_out_co)
    );


    dsce_mmap
    #(
        .pCOMPONENT_SELECT  (2)
    ) dsce_mmap_cg_inst
    (
        // clock and control interface
        .dsc_clk                    (dsc_clk),
        .dsc_reset_n                (dsc_reset_n),
        .dsc_pps_update             (dsc_pps_update),
        .cfg_pps                    (cfg_pps),
        // input samples
        .dsc_group_valid_in         (dsc_group_valid_in),
        .dsc_group_last_in          (dsc_group_last_in),
        .dsc_start_of_slice         (dsc_start_of_slice),
        .dsc_line_prev_in           (i_line_prev_in_cg),
        .dsc_group_in               (i_dsc_group_in_cg),
        .dsc_right_in               (dsc_right_in.cg),
        .dsc_qlevel                 (dsc_qlevel_c),
        // output predictors
        .dsc_valid_out              (),
        .dsc_predict_out            (i_mmap_predict_out_cg),
        .dsc_residual_out           (i_mmap_residual_out_cg)
    );


    // ------------------------------------------------------------------------------------------------------------
    //                                         block prediction calculation
    // ------------------------------------------------------------------------------------------------------------
    generate if (pINCLUDE_BLOCK_PREDICTION == 1) begin : gen_bp
`ifdef DSC_BPVECTOR_MODEL_SUBSTITUTE
        dsce_bpvector_function_model dsce_bpvector_inst
`else
        dsce_bpvector  dsce_bpvector_inst
`endif
        (
            // clock and control interface
            .dsc_clk             (dsc_clk),
            .dsc_reset_n         (dsc_reset_n),
            .cfg_dsc_encoder     (cfg_dsc_encoder),
            .dsc_pps_update      (dsc_pps_update),
            .cfg_pps             (cfg_pps),
            // data path, two lines
            .dsc_valid_in        (dsc_group_valid_in),
            .dsc_last_in         (dsc_group_last_in),
            .dsc_group_in        (dsc_group_in),
            .dsc_prev_line_in    (dsc_line_prev_in),
            .dsc_recon_group_in  (dsc_recon_group_in),
            .dsc_valid_out       (i_valid_bp),
            .dsc_last_out        (i_last_bp),
            .dsc_use_bp          (dsc_use_bp_out),
            .dsc_bpvector        (i_bp_vector),
            .dsc_predict_out     (i_predict_bp),
            .dsc_residual_out    (i_residual_bp)
        );
    end else begin
        assign i_valid_bp = 1'b0;
        assign i_last_bp = 1'b0;
        assign dsc_use_bp_out = 1'b0;
        assign i_bp_vector = 4'h0;
        assign i_residual_bp = '{default:kDSC_RESIDUAL_INIT};
        assign i_predict_bp = '{default:kDSC_PIXEL_INIT};
    end endgenerate

endmodule : dsce_predict
