`ifdef DSC_MPP_MODEL_SUBSTITUTE

import dsce_defs_pkg::*;

import "DPI-C" function void dsc_mpp_model_step(
    input int component,
    input int bits_per_component,
    input int convert_rgb,
    input int qlevel,
    input int right,
    input int sample_0,
    input int sample_1,
    input int sample_2,
    output int predict,
    output int residual_0,
    output int residual_1,
    output int residual_2
);

module dsce_mpp_function_model
#(
    parameter int pCOMPONENT_SELECT = 0
)
(
    input  logic                dsc_clk,
    input  logic                dsc_reset_n,
    input  logic                dsc_pps_update,
    input  tDSC_PPS             cfg_pps,
    input  logic                dsc_start_of_slice,
    input  logic                dsc_group_valid_in,
    input  logic                dsc_group_last_in,
    input  tDSC_QLEVEL          dsc_qlevel,
    input  tDSC_COMPONENT       dsc_group_in [2:0],
    input  tDSC_COMPONENT       dsc_right_in,
    output logic                dsc_predict_valid_out,
    output logic                dsc_predict_last_out,
    output tDSC_COMPONENT       dsc_predict_out [2:0],
    output tDSC_RESIDUAL        dsc_residual_out [2:0]
);
    logic [2:0] valid_pipe;
    logic [2:0] last_pipe;
    tDSC_COMPONENT predict_pipe [2:0];
    tDSC_RESIDUAL residual_pipe [2:0][2:0];
    int model_predict;
    int model_residual [2:0];

    always_ff @(posedge dsc_clk or negedge dsc_reset_n) begin : ModelAdapter
        if (!dsc_reset_n) begin
            valid_pipe <= '0;
            last_pipe <= '0;
            predict_pipe <= '{default: kDSC_COMPONENT_INIT};
            residual_pipe <= '{default: '{default: kDSC_RESIDUAL_INIT}};
            dsc_predict_valid_out <= 1'b0;
            dsc_predict_last_out <= 1'b0;
            dsc_predict_out <= '{default: kDSC_COMPONENT_INIT};
            dsc_residual_out <= '{default: kDSC_RESIDUAL_INIT};
        end else begin
            valid_pipe <= {valid_pipe[1:0], dsc_group_valid_in};
            last_pipe <= {last_pipe[1:0], dsc_group_valid_in && dsc_group_last_in};
            predict_pipe[2:1] <= predict_pipe[1:0];
            residual_pipe[2:1] <= residual_pipe[1:0];
            dsc_predict_valid_out <= valid_pipe[2];
            dsc_predict_last_out <= last_pipe[2];
            if (valid_pipe[2]) begin
                dsc_predict_out <= '{default: predict_pipe[2]};
                dsc_residual_out <= residual_pipe[2];
            end
            if (dsc_group_valid_in) begin
                dsc_mpp_model_step(
                    pCOMPONENT_SELECT, cfg_pps.bits_per_component,
                    cfg_pps.convert_rgb, dsc_qlevel, dsc_right_in,
                    dsc_group_in[0], dsc_group_in[1], dsc_group_in[2],
                    model_predict, model_residual[0], model_residual[1],
                    model_residual[2]);
                predict_pipe[0] <= tDSC_COMPONENT'(model_predict);
                for (int sample = 0; sample < 3; sample++)
                    residual_pipe[0][sample] <= tDSC_RESIDUAL'(model_residual[sample]);
            end
        end
    end
endmodule

`endif
