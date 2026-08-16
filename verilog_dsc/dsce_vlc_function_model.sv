// dsce_vlc 的黑盒 function-model adapter。本模块只使用公开端口，
// 不读取或复用 dsce_vlc 的内部信号。
import dsce_defs_pkg::*;

module dsce_vlc_function_model
#(
    parameter int pCOLOR_SELECT = 0
)
(
    input  logic                    dsc_clk,
    input  logic                    dsc_reset_n,
    input  logic                    dsc_pps_update,
    input  tDSC_PPS                 cfg_pps,
    input  logic                    dsc_start_of_slice,
    input  logic                    dsc_predict_valid_in,
    input  logic                    dsc_predict_last_in,
    input  tDSC_RESIDUAL            dsc_residual_in [2:0],
    input  logic [4:0]              dsc_residual_size_in,
    input  logic [4:0]              dsc_vlc_size_in,
    input  tDSC_QLEVEL              dsc_primary_qp_in,
    input  tDSC_QLEVEL              dsc_qlevel_y_in,
    input  tDSC_QLEVEL              dsc_qlevel_c_in,
    input  logic                    dsc_ich_selected_in,
    input  tDSC_ICH_INDEX           dsc_ich_index_in,
    input  tDSC_FLAT_FLAGS          dsc_flatness_in,
    output logic                    dsc_unit_size_valid,
    output logic [5:0]              dsc_coded_unit_size,
    output logic [5:0]              dsc_rc_size_unit,
    output logic                    dsc_vlc_valid_out,
    output logic                    dsc_vlc_last_out,
    output logic [4:0]              dsc_vlc_size_out,
    output logic [15:0]             dsc_vlc_data_out
);

    import "DPI-C" function longint unsigned dsc_vlc_unit_model_step(
        input int unit,
        input int reset_model,
        input int push_group,
        input int group_last,
        input int bits_per_component,
        input int convert_rgb,
        input int primary_qp,
        input int qlevel_y,
        input int qlevel_c,
        input int residual_size,
        input int vlc_size,
        input int residual_0,
        input int residual_1,
        input int residual_2,
        input int ich_selected,
        input int ich_index,
        input int flatness_flags
    );

    always_ff @(posedge dsc_clk or negedge dsc_reset_n) begin : ModelAdapter
        if (!dsc_reset_n) begin
            dsc_unit_size_valid <= 1'b0;
            dsc_coded_unit_size <= 6'd0;
            dsc_rc_size_unit <= 6'd0;
            dsc_vlc_valid_out <= 1'b0;
            dsc_vlc_last_out <= 1'b0;
            dsc_vlc_size_out <= 5'd0;
            dsc_vlc_data_out <= 16'd0;
        end else begin
            logic [63:0] result;
            result = dsc_vlc_unit_model_step(
                pCOLOR_SELECT,
                dsc_start_of_slice,
                dsc_predict_valid_in,
                dsc_predict_last_in,
                cfg_pps.bits_per_component,
                cfg_pps.convert_rgb,
                dsc_primary_qp_in,
                dsc_qlevel_y_in,
                dsc_qlevel_c_in,
                dsc_residual_size_in,
                dsc_vlc_size_in,
                dsc_residual_in[0],
                dsc_residual_in[1],
                dsc_residual_in[2],
                dsc_ich_selected_in,
                dsc_ich_index_in,
                dsc_flatness_in);
            dsc_vlc_valid_out <= result[62];
            dsc_vlc_last_out <= result[61];
            dsc_vlc_size_out <= result[60:56];
            dsc_vlc_data_out <= result[55:40];
            dsc_unit_size_valid <= result[39];
            if (result[39]) begin
                dsc_coded_unit_size <= result[38:33];
                dsc_rc_size_unit <= result[32:27];
            end
        end
    end

endmodule
