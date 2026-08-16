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
//     DESCRIPTION : Indexed color history block for the DSC encoder.
// ------------------------------------------------------------------------------------------------

// ----------------------------------------------
//  includes
// ----------------------------------------------
import dsce_defs_pkg::*;


// ----------------------------------------------
//  entity declaration
// ----------------------------------------------
module dsce_ich
(
    // clock and control interface
    input  logic                    dsc_clk,                        // DSC processing clock
    input  logic                    dsc_reset_n,                    // DSC domain reset
    input  tDSCE_CONFIG             cfg_dsc_encoder,                // general encoder configuration
    input  tDSC_PPS                 cfg_pps,                        // parameter set output array
    input  logic                    dsc_pps_update,                 // update pps parameters flag

    // control signal and previous line input
    input  logic                    dsc_start_of_slice,             // start of the current slice
    input  logic                    dsc_start_of_slice_line,        // start of a new slice line
    input  tDSC_PIXEL               dsc_line_prev_in [6:0],         // pixels from the previous line

    // original pixel data path
    input  logic                    dsc_group_valid_in,             // valid data in
    input  logic                    dsc_group_last_in,              // last group in the slice
    input  tDSC_PIXEL               dsc_group_in [2:0],             // current source group
    input  tDSC_QLEVEL              dsc_primary_qp,                 // primary Qp value for the group
    input  tDSC_QLEVEL              dsc_qlevel_y_in,                // qlevel, luma
    input  tDSC_QLEVEL              dsc_qlevel_c_in,                // qlevel, chroma
    input  logic                    dsc_force_mpp_in,               // force MPP mode
    input  logic                    dsc_ich_next_is_very_flat,      // next group is very flat
    input  logic [4:0]              dsc_vlc_size_in [2:0],          // vlc adjustment size

    // predicted pixel input
    input  logic                    dsc_predict_valid_in,           // valid data in
    input  logic                    dsc_predict_last_in,            // last group in a slice line
    input  tDSC_PIXEL               dsc_predict_in [2:0],           // precition value
    input  tDSC_RESIDUAL_PIXEL      dsc_quant_residual_in [2:0],    // quantized residual
    input  logic [4:0]              dsc_residual_size_in [2:0],     // max size of the residuals
    input  tDSC_QLEVEL              dsc_qlevel_y_res,               // qlevel, residuals, y
    input  tDSC_QLEVEL              dsc_qlevel_c_res,               // qlevel, residuals, c

    // ich lookup output
    output logic                    dsc_ich_valid_out,              // valid predicted pixels out
    output logic                    dsc_ich_select_out,             // select the ICH values (comb path)
    output tDSC_ICH_INDEX           dsc_ich_index_out [2:0],        // ICH index values
    output tDSC_PIXEL               dsc_ich_group_out [2:0]         // selected ICH entry values
);

    // ------------------------------------------------------------------------------------------------------------
    //                                          internal definitions
    // ------------------------------------------------------------------------------------------------------------

    // ----- history interconnect ----- //
    logic [31:0]                    i_ich_entry_valid;
    tDSC_PIXEL                      i_ich_entry [31:0];
    logic [2:0]                     i_ich_hit;
    logic [2:0]                     i_ich_hit_current;
    tDSC_ICH_INDEX                  i_ich_index [2:0];
    tDSC_PIXEL                      i_ich_pixel [2:0];
    logic                           i_ich_select_decision;

    // ----- predict reconstruction ----- //
    tDSC_PIXEL                      i_predict_group_in [2:0];
    tDSC_PIXEL                      i_recon_group [2:0];

    // ICH 选择是本拍组合决策，直接转发给 decision，避免跨 always_comb 的 delta 延迟。
    assign dsc_ich_select_out = i_ich_select_decision & ~dsc_force_mpp_in;


    // ------------------------------------------------------------------------------------------------------------
    //                                             processes
    // ------------------------------------------------------------------------------------------------------------
    always_comb begin : PredictRecon
        for (int rx = 0; rx < 3; rx++) begin : PredictReconLoop
            i_predict_group_in[rx].y  = dsce_recon(dsc_predict_in[rx].y,  dsc_quant_residual_in[rx].res_y,  dsc_qlevel_y_res);
            i_predict_group_in[rx].co = dsce_recon(dsc_predict_in[rx].co, dsc_quant_residual_in[rx].res_co, dsc_qlevel_c_res);
            i_predict_group_in[rx].cg = dsce_recon(dsc_predict_in[rx].cg, dsc_quant_residual_in[rx].res_cg, dsc_qlevel_c_res);
        end : PredictReconLoop
    end : PredictRecon

    always_comb begin : ReconSelection
        if (dsc_ich_select_out == 1'b0) begin
            i_recon_group = i_predict_group_in;
        end else begin
            i_recon_group = dsc_ich_group_out;
        end // if
    end : ReconSelection


    // ------------------------------------------------------------------------------------------------------------
    //                                             components
    // ------------------------------------------------------------------------------------------------------------

    // -------------------------------------------------------------------------------
    //   ICH history entries
    // -------------------------------------------------------------------------------
    dsce_ich_history  dsce_ich_history_inst
    (
        // clock and control interface
        .dsc_clk                        (dsc_clk),
        .dsc_reset_n                    (dsc_reset_n),
        // slice control signals
        .dsc_start_of_slice             (dsc_start_of_slice),
        .dsc_start_of_slice_line        (dsc_start_of_slice_line),
        // original pixel input path
        .dsc_group_valid_in             (dsc_group_valid_in),
        .dsc_group_last_in              (dsc_group_last_in),
        .dsc_group_in                   (dsc_group_in),
        .dsc_line_prev_in               (dsc_line_prev_in),
        // reconstructed pixel input
        .dsc_update_valid_in            (dsc_predict_valid_in),
        .dsc_update_last_in             (dsc_predict_last_in),
        .dsc_ich_selected_in            (dsc_ich_select_out),
        .dsc_ich_index_in               (i_ich_index),
        .dsc_recon_group_in             (i_recon_group),
        // ich history output
        .dsc_ich_entry_valid_out        (i_ich_entry_valid),
        .dsc_ich_entry_out              (i_ich_entry)
    );


    // -------------------------------------------------------------------------------
    //   Candidate selection and first condition check
    // -------------------------------------------------------------------------------
    dsce_ich_candidate  dsce_ich_candidate_inst
    (
        // clock and control interface
        .dsc_clk                        (dsc_clk),
        .dsc_reset_n                    (dsc_reset_n),
        .cfg_bits_per_component         (cfg_pps.bits_per_component),
        // slice control signals
        .dsc_start_of_slice             (dsc_start_of_slice),
        .dsc_start_of_slice_line        (dsc_start_of_slice_line),
        // original pixel input path
        .dsc_group_valid_in             (dsc_group_valid_in),
        .dsc_group_last_in              (dsc_group_last_in),
        .dsc_group_in                   (dsc_group_in),
        .dsc_primary_qp                  (dsc_primary_qp),
        // ich history input
        .dsc_ich_entry_valid_in         (i_ich_entry_valid),
        .dsc_ich_entry_in               (i_ich_entry),
        // ICH candidate selection
        .dsc_ich_hit                    (i_ich_hit),
        .dsc_ich_hit_current            (i_ich_hit_current),
        .dsc_ich_index_out              (i_ich_index),
        .dsc_ich_pixel_out              (i_ich_pixel)
    );


    // -------------------------------------------------------------------------------
    //   Place holder for the decision block
    // -------------------------------------------------------------------------------
    dsce_ich_decision  dsce_ich_decision_inst
    (
        // clock and control interface
        .dsc_clk                        (dsc_clk),
        .dsc_reset_n                    (dsc_reset_n),
        .cfg_bits_per_component         (cfg_pps.bits_per_component),
        .cfg_convert_rgb                (cfg_pps.convert_rgb),
        .cfg_dsc_version_minor          (cfg_pps.dsc_version_minor),
        .cfg_slice_alignment            (cfg_dsc_encoder.slice_width_alignment),
        // original pixel input path
        .dsc_start_of_slice             (dsc_start_of_slice),
        .dsc_group_valid_in             (dsc_group_valid_in),
        .dsc_group_last_in              (dsc_group_last_in),
        .dsc_group_in                   (dsc_group_in),
        .dsc_ich_next_is_very_flat      (dsc_ich_next_is_very_flat),
        .dsc_vlc_size_in                (dsc_vlc_size_in),
        .dsc_qlevel_y_in                (dsc_qlevel_y_in),
        .dsc_qlevel_c_in                (dsc_qlevel_c_in),
        .dsc_force_mpp_in               (dsc_force_mpp_in),
        // predict and ICH inputs
        .dsc_predict_valid_in           (dsc_predict_valid_in),
        .dsc_predict_group_in           (i_predict_group_in),
        .dsc_residual_size_in           (dsc_residual_size_in),
        .dsc_ich_hit                    (i_ich_hit),
        .dsc_ich_index_in               (i_ich_index),
        .dsc_ich_pixel_in               (i_ich_pixel),
        // ICH candidate selection
        .dsc_ich_valid_out              (dsc_ich_valid_out),
        .dsc_ich_select_out             (i_ich_select_decision),
        .dsc_ich_index_out              (dsc_ich_index_out),
        .dsc_ich_group_out              (dsc_ich_group_out)
    );

endmodule : dsce_ich
