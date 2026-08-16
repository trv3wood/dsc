`ifdef DSC_BPVECTOR_MODEL_SUBSTITUTE

import dsce_defs_pkg::*;

import "DPI-C" function void dsc_bpvector_model_step(
    input int reset_model,
    input int push_group,
    input int group_last,
    input int block_pred_enable,
    input int bits_per_component,
    input longint unsigned group_0,
    input longint unsigned group_1,
    input longint unsigned group_2,
    input longint unsigned prev_0,
    input longint unsigned prev_1,
    input longint unsigned prev_2,
    input longint unsigned prev_3,
    input longint unsigned prev_4,
    input longint unsigned prev_5,
    input longint unsigned recon_0,
    input longint unsigned recon_1,
    input longint unsigned recon_2,
    output int use_bp,
    output int bp_vector,
    output longint unsigned predict_0,
    output longint unsigned predict_1,
    output longint unsigned predict_2,
    output longint unsigned residual_0,
    output longint unsigned residual_1,
    output longint unsigned residual_2
);

module dsce_bpvector_function_model
(
    input  logic                        dsc_clk,
    input  logic                        dsc_reset_n,
    input  tDSCE_CONFIG                 cfg_dsc_encoder,
    input  logic                        dsc_pps_update,
    input  tDSC_PPS                     cfg_pps,
    input  logic                        dsc_valid_in,
    input  logic                        dsc_last_in,
    input  tDSC_PIXEL                   dsc_group_in [2:0],
    input  tDSC_PIXEL                   dsc_prev_line_in [5:0],
    input  tDSC_PIXEL                   dsc_recon_group_in [2:0],
    output logic                        dsc_valid_out,
    output logic                        dsc_last_out,
    output logic                        dsc_use_bp,
    output logic [3:0]                  dsc_bpvector,
    output tDSC_PIXEL                   dsc_predict_out [2:0],
    output tDSC_RESIDUAL_PIXEL          dsc_residual_out [2:0]
);
    logic [2:0] valid_pipe;
    logic [2:0] last_pipe;
    int model_use_bp;
    int model_vector;
    longint unsigned model_predict [2:0];
    longint unsigned model_residual [2:0];
    int model_group = 0;
    int model_line = 0;

    always_ff @(posedge dsc_clk or negedge dsc_reset_n) begin : ModelAdapter
        if (!dsc_reset_n) begin
            dsc_bpvector_model_step(1, 0, 0, 0, 0,
                                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                                    model_use_bp, model_vector,
                                    model_predict[0], model_predict[1], model_predict[2],
                                    model_residual[0], model_residual[1], model_residual[2]);
            valid_pipe <= 3'b000;
            last_pipe <= 3'b000;
            dsc_valid_out <= 1'b0;
            dsc_last_out <= 1'b0;
            dsc_use_bp <= 1'b0;
            dsc_bpvector <= 4'd0;
            dsc_predict_out <= '{default: kDSC_PIXEL_INIT};
            dsc_residual_out <= '{default: kDSC_RESIDUAL_PIXEL_INIT};
            model_group = 0;
            model_line = 0;
        end else begin
            valid_pipe <= {valid_pipe[1:0], dsc_valid_in};
            last_pipe <= {last_pipe[1:0], dsc_valid_in && dsc_last_in};
            dsc_valid_out <= valid_pipe[2];
            dsc_last_out <= last_pipe[2];
            if (dsc_valid_in) begin
                dsc_bpvector_model_step(
                    0, 1, dsc_last_in, cfg_pps.block_pred_enable,
                    cfg_pps.bits_per_component,
                    longint'(dsc_group_in[0]), longint'(dsc_group_in[1]),
                    longint'(dsc_group_in[2]), longint'(dsc_prev_line_in[0]),
                    longint'(dsc_prev_line_in[1]), longint'(dsc_prev_line_in[2]),
                    longint'(dsc_prev_line_in[3]), longint'(dsc_prev_line_in[4]),
                    longint'(dsc_prev_line_in[5]),
                    longint'(dsc_recon_group_in[0]), longint'(dsc_recon_group_in[1]),
                    longint'(dsc_recon_group_in[2]),
                    model_use_bp, model_vector,
                    model_predict[0], model_predict[1], model_predict[2],
                    model_residual[0], model_residual[1], model_residual[2]);
                dsc_use_bp <= model_use_bp[0];
                dsc_bpvector <= model_vector[3:0];
                for (int sample = 0; sample < 3; sample++) begin
                    dsc_predict_out[sample] <= tDSC_PIXEL'(model_predict[sample][47:0]);
                    dsc_residual_out[sample] <= tDSC_RESIDUAL_PIXEL'(model_residual[sample][50:0]);
                end
                if (dsc_last_in) begin
                    model_group = 0;
                    model_line++;
                end else begin
                    model_group++;
                end
            end
        end
    end
endmodule

`endif
