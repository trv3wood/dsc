`ifdef DSC_ICH_MODEL_SUBSTITUTE

import dsce_defs_pkg::*;

import "DPI-C" function void dsc_ich_model_reset();
import "DPI-C" function void dsc_ich_model_group(
    input int last, input int bits, input int version, input int primary_qp,
    input int qy, input int qc, input int force_mpp, input int next_very_flat,
    input int vlc_0, input int vlc_1, input int vlc_2,
    input longint unsigned group_0, input longint unsigned group_1,
    input longint unsigned group_2, input longint unsigned prev_0,
    input longint unsigned prev_1, input longint unsigned prev_2,
    input longint unsigned prev_3, input longint unsigned prev_4,
    input longint unsigned prev_5, input longint unsigned prev_6);
import "DPI-C" function void dsc_ich_model_decide(
    input longint unsigned predict_0, input longint unsigned predict_1,
    input longint unsigned predict_2,
    input int residual_y_0, input int residual_co_0, input int residual_cg_0,
    input int residual_y_1, input int residual_co_1, input int residual_cg_1,
    input int residual_y_2, input int residual_co_2, input int residual_cg_2,
    input int qy, input int qc, input int residual_size_0,
    input int residual_size_1, input int residual_size_2,
    output int select, output int index_0, output int index_1,
    output int index_2, output longint unsigned pixel_0,
    output longint unsigned pixel_1, output longint unsigned pixel_2);
import "DPI-C" function void dsc_ich_model_update(
    input int valid, input int last,
    input longint unsigned predict_0, input longint unsigned predict_1,
    input longint unsigned predict_2,
    input int residual_y_0, input int residual_co_0, input int residual_cg_0,
    input int residual_y_1, input int residual_co_1, input int residual_cg_1,
    input int residual_y_2, input int residual_co_2, input int residual_cg_2,
    input int qy, input int qc, input int vlc_0, input int vlc_1,
    input int vlc_2);

module dsce_ich_function_model
(
    input logic dsc_clk, input logic dsc_reset_n,
    input tDSCE_CONFIG cfg_dsc_encoder, input tDSC_PPS cfg_pps,
    input logic dsc_pps_update, input logic dsc_start_of_slice,
    input logic dsc_start_of_slice_line,
    input tDSC_PIXEL dsc_line_prev_in [6:0],
    input logic dsc_group_valid_in, input logic dsc_group_last_in,
    input tDSC_PIXEL dsc_group_in [2:0], input tDSC_QLEVEL dsc_primary_qp,
    input tDSC_QLEVEL dsc_qlevel_y_in, input tDSC_QLEVEL dsc_qlevel_c_in,
    input logic dsc_force_mpp_in, input logic dsc_ich_next_is_very_flat,
    input logic [4:0] dsc_vlc_size_in [2:0],
    input logic dsc_predict_valid_in, input logic dsc_predict_last_in,
    input tDSC_PIXEL dsc_predict_in [2:0],
    input tDSC_RESIDUAL_PIXEL dsc_quant_residual_in [2:0],
    input logic [4:0] dsc_residual_size_in [2:0],
    input tDSC_QLEVEL dsc_qlevel_y_res, input tDSC_QLEVEL dsc_qlevel_c_res,
    output logic dsc_ich_valid_out, output logic dsc_ich_select_out,
    output tDSC_ICH_INDEX dsc_ich_index_out [2:0],
    output tDSC_PIXEL dsc_ich_group_out [2:0]
);
    int model_select;
    int model_index [2:0];
    longint unsigned model_pixel [2:0];

    // 仿真 adapter 在下降沿求值，使 function model 的结果在下一个采样上升沿前稳定。
    always @(posedge dsc_clk or negedge dsc_clk or negedge dsc_reset_n) begin : ModelAdapter
        if (!dsc_reset_n) begin
            dsc_ich_model_reset();
            dsc_ich_valid_out <= 1'b0;
            dsc_ich_select_out <= 1'b0;
            dsc_ich_index_out <= '{default: kDSC_ICH_INDEX_INIT};
            dsc_ich_group_out <= '{default: kDSC_PIXEL_INIT};
        end else if (dsc_clk) begin
            if (dsc_start_of_slice)
                dsc_ich_model_reset();
            // 同拍反馈属于当前输入左侧的 group，候选搜索前必须先更新历史。
            dsc_ich_model_update(
                dsc_predict_valid_in, dsc_predict_last_in,
                dsc_predict_in[0], dsc_predict_in[1], dsc_predict_in[2],
                dsc_quant_residual_in[0].res_y,
                dsc_quant_residual_in[0].res_co,
                dsc_quant_residual_in[0].res_cg,
                dsc_quant_residual_in[1].res_y,
                dsc_quant_residual_in[1].res_co,
                dsc_quant_residual_in[1].res_cg,
                dsc_quant_residual_in[2].res_y,
                dsc_quant_residual_in[2].res_co,
                dsc_quant_residual_in[2].res_cg, dsc_qlevel_y_res,
                dsc_qlevel_c_res, dsc_vlc_size_in[0], dsc_vlc_size_in[1],
                dsc_vlc_size_in[2]);
            if (dsc_group_valid_in) begin
                dsc_ich_model_group(
                    dsc_group_last_in, cfg_pps.bits_per_component,
                    cfg_pps.dsc_version_minor, dsc_primary_qp,
                    dsc_qlevel_y_in, dsc_qlevel_c_in, dsc_force_mpp_in,
                    dsc_ich_next_is_very_flat, dsc_vlc_size_in[0],
                    dsc_vlc_size_in[1], dsc_vlc_size_in[2],
                    dsc_group_in[0], dsc_group_in[1], dsc_group_in[2],
                    dsc_line_prev_in[0], dsc_line_prev_in[1],
                    dsc_line_prev_in[2], dsc_line_prev_in[3],
                    dsc_line_prev_in[4], dsc_line_prev_in[5],
                    dsc_line_prev_in[6]);
            end
        end else begin
            dsc_ich_valid_out <= dsc_predict_valid_in;
            if (dsc_predict_valid_in) begin
                dsc_ich_model_decide(
                    dsc_predict_in[0], dsc_predict_in[1], dsc_predict_in[2],
                    dsc_quant_residual_in[0].res_y,
                    dsc_quant_residual_in[0].res_co,
                    dsc_quant_residual_in[0].res_cg,
                    dsc_quant_residual_in[1].res_y,
                    dsc_quant_residual_in[1].res_co,
                    dsc_quant_residual_in[1].res_cg,
                    dsc_quant_residual_in[2].res_y,
                    dsc_quant_residual_in[2].res_co,
                    dsc_quant_residual_in[2].res_cg, dsc_qlevel_y_res,
                    dsc_qlevel_c_res,
                    dsc_residual_size_in[0], dsc_residual_size_in[1],
                    dsc_residual_size_in[2], model_select, model_index[0],
                    model_index[1], model_index[2], model_pixel[0],
                    model_pixel[1], model_pixel[2]);
                dsc_ich_select_out <= model_select[0];
                for (int sample = 0; sample < 3; sample++) begin
                    dsc_ich_index_out[sample] <= tDSC_ICH_INDEX'(model_index[sample]);
                    dsc_ich_group_out[sample] <= tDSC_PIXEL'(model_pixel[sample][47:0]);
                end
            end
        end
    end
endmodule

`endif
