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
//     DESCRIPTION : Decision block for residual selection.  Also performs quantization and
//                   key calculations for the VLC block.
// ------------------------------------------------------------------------------------------------

// ----------------------------------------------
//  includes
// ----------------------------------------------
import dsce_defs_pkg::*;


// ----------------------------------------------
//  entity declaration
// ----------------------------------------------
module dsce_decision
(
    // clock and control interface
    input  logic                    dsc_clk,                        // DSC processing clock
    input  logic                    dsc_reset_n,                    // DSC domain reset
    input  tDSCE_CONFIG             cfg_dsc_encoder,                // general encoder configuration
    input  logic                    dsc_pps_update,                 // update pps parameters flag
    input  tDSC_PPS                 cfg_pps,                        // parameter set output array

    // control inputs
    input  logic                    dsc_valid_in,                   // valid data in
    input  logic                    dsc_last_in,                    // last group in the slice
    input  tDSC_QLEVEL              dsc_qlevel_y_res_in,            // luma quant level for residuals
    input  tDSC_QLEVEL              dsc_qlevel_c_res_in,            // chroma quant level for residuals
    input  logic                    dsc_force_mpp_in,               // force the MPP mode to avoid underflow

    // predicted / ICH path in
    input  logic                    dsc_use_bp_in,                  // previously computed block prediction select
    input  tDSC_PIXEL               dsc_bp_predict_in [2:0],        // block predict
    input  tDSC_PIXEL               dsc_mmap_predict_in [2:0],      // mmap predict
    input  tDSC_PIXEL               dsc_mpp_predict_in [2:0],       // midpoint predict
    input  tDSC_RESIDUAL_PIXEL      dsc_bp_residual_in [2:0],       // group residuals, bp
    input  tDSC_RESIDUAL_PIXEL      dsc_mmap_residual_in [2:0],     // group residuals, mmap
    input  tDSC_RESIDUAL_PIXEL      dsc_mpp_residual_in [2:0],      // group residuals, mpp
    input  logic                    dsc_ich_selected_in,            // valid entries found for the ICH path
    input  tDSC_PIXEL               dsc_ich_group_in [2:0],         // pixel values from the ICH selection

    // residuals out
    output logic                    dsc_ich_selected_out,           // final ICH selection determination
    output logic [2:0]              dsc_mpp_out,                    // MPP selected for each unit
    output tDSC_PIXEL               dsc_predict_out [2:0],          // precition out
    output tDSC_RESIDUAL_PIXEL      dsc_quant_residual_out [2:0],   // quantized residual out
    output tDSC_PIXEL               dsc_recon_group_out [2:0],      // reconstructed predict group out
    output tDSC_PIXEL               dsc_right_pixel_out,            // rightmost pixel out from the previous group

    // VLC parameters
    output logic [4:0]              dsc_residual_size_out [2:0],    // size of residuals out
    output logic [4:0]              dsc_vlc_size_out [2:0]          // adjust size for VLC
);

    // ICH 的最终选择不依赖本模块内部状态，直接传递避免组合块之间的 delta 延迟。
    assign dsc_ich_selected_out = dsc_ich_selected_in & ~dsc_force_mpp_in;

    // ------------------------------------------------------------------------------------------------------------
    //                                          internal definitions
    // ------------------------------------------------------------------------------------------------------------

    logic [4:0]                     i_bits_per_component;
    logic                           i_convert_rgb;
    logic [4:0]                     i_bitdepth_y, i_bitdepth_c;
    logic [3:1]                     i_last_pipe;
    logic                           i_last_group_out;

    logic [2:0]                     i_component_mpp [2:0];
    logic [2:0]                     i_use_mpp;
    logic [2:0]                     i_zero_right;

    logic [4:0]                     i_max_residual_size_y, i_max_residual_size_c;
    tDSC_PIXEL                      i_mmap_bp_predict [2:0];
    tDSC_RESIDUAL_PIXEL             i_mmap_bp_residual [2:0];
    tDSC_RESIDUAL_PIXEL             i_mpp_residual [2:0];
    tDSC_RESIDUAL_PIXEL             i_predict_residual [2:0];
    tDSC_PIXEL                      i_predict_pixel [2:0];
    tDSC_RESIDUAL_PIXEL             i_quantized_residual [2:0];
    logic [4:0]                     i_max_predict_size [2:0];
    logic [4:0]                     i_predict_size [8:0];
    logic [6:0]                     i_vlc_size [2:0];

    // 当前组右像素的组合计算与行末锁存值
    tDSC_PIXEL                      i_right_pixel_comb;
    tDSC_PIXEL                      i_right_reg;


    // ------------------------------------------------------------------------------------------------------------
    //                                             processes
    // ------------------------------------------------------------------------------------------------------------

    // signal assignments
    always_comb begin : SignalMap
        // zero residuals for pixels outside of the right edge
        i_zero_right = (dsc_last_in == 1'b1 || i_last_pipe != 3'd0) ? ~cfg_dsc_encoder.slice_width_alignment : 3'b000;

        // select mmap or bp
        case ({i_zero_right[0], dsc_use_bp_in})
            2'b00:    i_mmap_bp_residual[0] = dsc_mmap_residual_in[0];
            2'b01:    i_mmap_bp_residual[0] = dsc_bp_residual_in[0];
            default:  i_mmap_bp_residual[0] = kDSC_RESIDUAL_PIXEL_INIT;
        endcase

        case ({i_zero_right[1], dsc_use_bp_in})
            2'b00:    i_mmap_bp_residual[1] = dsc_mmap_residual_in[1];
            2'b01:    i_mmap_bp_residual[1] = dsc_bp_residual_in[1];
            default:  i_mmap_bp_residual[1] = kDSC_RESIDUAL_PIXEL_INIT;
        endcase

        case ({i_zero_right[2], dsc_use_bp_in})
            2'b00:    i_mmap_bp_residual[2] = dsc_mmap_residual_in[2];
            2'b01:    i_mmap_bp_residual[2] = dsc_bp_residual_in[2];
            default:  i_mmap_bp_residual[2] = kDSC_RESIDUAL_PIXEL_INIT;
        endcase

        for (int mpx = 0; mpx < 3; mpx++) begin : DataSourceInputLoop
            i_mmap_bp_predict[mpx] = (dsc_use_bp_in == 1'b1) ? dsc_bp_predict_in[mpx] : dsc_mmap_predict_in[mpx];
            i_mpp_residual[mpx] = (i_zero_right[mpx] == 1'b1) ? kDSC_RESIDUAL_PIXEL_INIT : dsc_mpp_residual_in[mpx];
        end : DataSourceInputLoop

        // size threshold detection
        for (int ux = 0; ux < 3; ux++) begin : ComponentMapLoop
            i_component_mpp[ux][0] = dsce_mpp_select(i_mmap_bp_residual[ux].res_y,  i_bitdepth_y, dsc_qlevel_y_res_in);
            i_component_mpp[ux][1] = dsce_mpp_select(i_mmap_bp_residual[ux].res_co, i_bitdepth_c, dsc_qlevel_c_res_in);
            i_component_mpp[ux][2] = dsce_mpp_select(i_mmap_bp_residual[ux].res_cg, i_bitdepth_c, dsc_qlevel_c_res_in);
        end : ComponentMapLoop

        i_use_mpp[0] = (i_component_mpp[0][0] | i_component_mpp[1][0]) | (i_component_mpp[2][0] | dsc_force_mpp_in);
        i_use_mpp[1] = (i_component_mpp[0][1] | i_component_mpp[1][1]) | (i_component_mpp[2][1] | dsc_force_mpp_in);
        i_use_mpp[2] = (i_component_mpp[0][2] | i_component_mpp[1][2]) | (i_component_mpp[2][2] | dsc_force_mpp_in);

        i_max_residual_size_y = i_bitdepth_y - dsc_qlevel_y_res_in;
        i_max_residual_size_c = i_bitdepth_c - dsc_qlevel_c_res_in;

        // prediction path
        for (int rx = 0; rx < 3; rx++) begin : PredictMappingLoop
            i_predict_pixel[rx].y  = (i_use_mpp[0] == 1'b1) ? dsc_mpp_predict_in[rx].y  : i_mmap_bp_predict[rx].y;
            i_predict_pixel[rx].co = (i_use_mpp[1] == 1'b1) ? dsc_mpp_predict_in[rx].co : i_mmap_bp_predict[rx].co;
            i_predict_pixel[rx].cg = (i_use_mpp[2] == 1'b1) ? dsc_mpp_predict_in[rx].cg : i_mmap_bp_predict[rx].cg;

            i_predict_residual[rx].res_y  = (i_use_mpp[0] == 1'b1) ? i_mpp_residual[rx].res_y  : i_mmap_bp_residual[rx].res_y;
            i_predict_residual[rx].res_co = (i_use_mpp[1] == 1'b1) ? i_mpp_residual[rx].res_co : i_mmap_bp_residual[rx].res_co;
            i_predict_residual[rx].res_cg = (i_use_mpp[2] == 1'b1) ? i_mpp_residual[rx].res_cg : i_mmap_bp_residual[rx].res_cg;
        end : PredictMappingLoop

    end : SignalMap

    always_comb begin : ICHOutputMap
        // ICH 只影响最终模式标志，不参与预测像素和残差的生成。
        if (dsc_ich_selected_in == 1'b1 && dsc_force_mpp_in == 1'b0) begin
            dsc_mpp_out = 3'b000;
        end else begin
            dsc_mpp_out = i_use_mpp;
        end // if
    end : ICHOutputMap


    // -------------------------------------------------------
    //  register paths for local timing optimization
    // -------------------------------------------------------
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : Locals
        if (dsc_reset_n == 1'b0) begin
            i_convert_rgb <= 1'b0;
            i_bits_per_component <= 5'h00;
            i_bitdepth_y <= 5'd0;
            i_bitdepth_c <= 5'd0;
            i_last_pipe <= 3'b000;
            i_last_group_out <= 1'b0;

        end else begin

            // store PPS paramters when there is an update
            if (dsc_pps_update == 1'b1) begin
                i_convert_rgb <= cfg_pps.convert_rgb;
                i_bits_per_component <= (cfg_pps.bits_per_component == 4'h0) ? 5'd16 : {1'b0, cfg_pps.bits_per_component};
            end // if

            i_bitdepth_y <= i_bits_per_component;
            i_bitdepth_c <= (i_convert_rgb == 1'b1) ? i_bits_per_component + 5'd1 : i_bits_per_component;

            // 4 stage pipeline tracking
            i_last_pipe <= {i_last_pipe[2:1], dsc_valid_in & dsc_last_in};

            // flag for the last output group of a slice line
            if (dsc_valid_in == 1'b1) begin
                i_last_group_out <= dsc_last_in;
            end // if

        end // if
    end : Locals


    // -------------------------------------------------------
    //  parameter outputs
    // -------------------------------------------------------
    always_comb begin : OutputGen
        // quantization step
        for (int qx = 0; qx < 3; qx++) begin : ResidualMappingLoop
            i_quantized_residual[qx].res_y  = dsce_quantization_with_range_check(i_predict_residual[qx].res_y,  dsc_qlevel_y_res_in, i_max_residual_size_y);
            i_quantized_residual[qx].res_co = dsce_quantization_with_range_check(i_predict_residual[qx].res_co, dsc_qlevel_c_res_in, i_max_residual_size_c);
            i_quantized_residual[qx].res_cg = dsce_quantization_with_range_check(i_predict_residual[qx].res_cg, dsc_qlevel_c_res_in, i_max_residual_size_c);
        end : ResidualMappingLoop

        // maximum size of the prediction residual
        i_max_predict_size[0] = (i_use_mpp[0] == 1'b1) ? (i_bitdepth_y - dsc_qlevel_y_res_in) : dsce_max_3(dsce_residual_size(i_quantized_residual[0].res_y) , dsce_residual_size(i_quantized_residual[1].res_y) , dsce_residual_size(i_quantized_residual[2].res_y));
        i_max_predict_size[1] = (i_use_mpp[1] == 1'b1) ? (i_bitdepth_c - dsc_qlevel_c_res_in) : dsce_max_3(dsce_residual_size(i_quantized_residual[0].res_co), dsce_residual_size(i_quantized_residual[1].res_co), dsce_residual_size(i_quantized_residual[2].res_co));
        i_max_predict_size[2] = (i_use_mpp[2] == 1'b1) ? (i_bitdepth_c - dsc_qlevel_c_res_in) : dsce_max_3(dsce_residual_size(i_quantized_residual[0].res_cg), dsce_residual_size(i_quantized_residual[1].res_cg), dsce_residual_size(i_quantized_residual[2].res_cg));

        // actual sizes of the residuals for VLC
        for (int sx = 0; sx < 3; sx++) begin : PredictSizeLoop
            i_predict_size[sx*3+0] = (i_use_mpp[0] == 1'b1) ? (i_bitdepth_y - dsc_qlevel_y_res_in) : {1'b0, dsce_residual_size(i_quantized_residual[sx].res_y)};
            i_predict_size[sx*3+1] = (i_use_mpp[1] == 1'b1) ? (i_bitdepth_c - dsc_qlevel_c_res_in) : {1'b0, dsce_residual_size(i_quantized_residual[sx].res_co)};
            i_predict_size[sx*3+2] = (i_use_mpp[2] == 1'b1) ? (i_bitdepth_c - dsc_qlevel_c_res_in) : {1'b0, dsce_residual_size(i_quantized_residual[sx].res_cg)};
        end : PredictSizeLoop

        i_vlc_size[0] = ({2'b00, i_predict_size[0]} + {2'b00, i_predict_size[3]}) + ({1'b0, i_predict_size[6], 1'b0} + 7'd2);
        i_vlc_size[1] = ({2'b00, i_predict_size[1]} + {2'b00, i_predict_size[4]}) + ({1'b0, i_predict_size[7], 1'b0} + 7'd2);
        i_vlc_size[2] = ({2'b00, i_predict_size[2]} + {2'b00, i_predict_size[5]}) + ({1'b0, i_predict_size[8], 1'b0} + 7'd2);

        // residual output
        dsc_vlc_size_out = '{i_vlc_size[2][6:2], i_vlc_size[1][6:2], i_vlc_size[0][6:2]};
        dsc_quant_residual_out = i_quantized_residual;
        dsc_predict_out = i_predict_pixel;
        dsc_residual_size_out = i_max_predict_size;
    end : OutputGen

    // 重建反馈只影响后续预测状态，不能反向参与当前 ICH 的候选代价计算。
    always_comb begin : ReconOutput
        // reconstructed group out
        if (dsc_ich_selected_out == 1'b0) begin
            for (int sx = 0; sx < 3; sx++) begin : GroupReconLoop
                dsc_recon_group_out[sx].y  = dsce_recon(i_predict_pixel[sx].y,  i_quantized_residual[sx].res_y,  dsc_qlevel_y_res_in);
                dsc_recon_group_out[sx].co = dsce_recon(i_predict_pixel[sx].co, i_quantized_residual[sx].res_co, dsc_qlevel_c_res_in);
                dsc_recon_group_out[sx].cg = dsce_recon(i_predict_pixel[sx].cg, i_quantized_residual[sx].res_cg, dsc_qlevel_c_res_in);
            end : GroupReconLoop
        end else begin
            dsc_recon_group_out = dsc_ich_group_in;
        end // if

        // 当前组的末像素：行末部分组按 slice_width_alignment 选实际末像素，
        // 否则为完整组的第三个样本。行末间隙（i_last_group_out=1 且无新组）
        // 时 i_ich_selected_out 已随 dsc_predict_valid_in 回落为 0，dsc_recon_group_out
        // 会从 ICH 像素切换到 predict+residual 路径；此处仅作组合计算，输出用
        // RightPixel 里锁存的行末值（见 dsc_right_pixel_out 的 assign）。
        if (i_last_group_out == 1'b1 && dsc_valid_in == 1'b0) begin
            case (cfg_dsc_encoder.slice_width_alignment)
                3'h1:       i_right_pixel_comb = dsc_recon_group_out[0];
                3'h3:       i_right_pixel_comb = dsc_recon_group_out[1];
                default:    i_right_pixel_comb = dsc_recon_group_out[2];
            endcase
        end else begin
            i_right_pixel_comb = dsc_recon_group_out[2];
        end // if
    end : ReconOutput


    // 普通组在 fd(=pd) 沿的 MPP/MMAP 采样依赖组合 dsc_recon_group_out 已稳定为
    // 上一组末像素；行末间隙组合会因 ICH 回落而错位，改用 pd 沿锁存的行末值。
    assign dsc_right_pixel_out = (i_last_group_out == 1'b1 && dsc_valid_in == 1'b0) ?
                                 i_right_reg : i_right_pixel_comb;

    // pd 沿锁存当前组末像素，供行末间隙输出稳定值
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : RightPixel
        if (dsc_reset_n == 1'b0) begin
            i_right_reg <= kDSC_PIXEL_INIT;
        end else if (dsc_valid_in == 1'b1) begin
            i_right_reg <= i_right_pixel_comb;
        end // if
    end : RightPixel

endmodule : dsce_decision
