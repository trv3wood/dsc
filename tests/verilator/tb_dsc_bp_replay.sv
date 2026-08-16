`timescale 1ns/1ps

import dsce_defs_pkg::*;

module tb_dsc_bp_replay;
    localparam int kGROUPS = 3456;

    logic dsc_clk = 1'b0;
    logic dsc_reset_n = 1'b0;
    logic dsc_pps_update = 1'b0;
    tDSCE_CONFIG cfg_dsc_encoder = kDSCE_CONFIG_INIT;
    tDSC_PPS cfg_pps = kDSC_PPS_INIT;

    logic valid_in = 1'b0;
    logic last_in = 1'b0;
    tDSC_PIXEL group_in [2:0];
    tDSC_PIXEL prev_in [5:0];
    tDSC_PIXEL recon_in [2:0];

    // RTL outputs
    logic rtl_valid;
    logic rtl_last;
    logic rtl_use_bp;
    logic [3:0] rtl_vector;
    tDSC_PIXEL rtl_predict [2:0];
    tDSC_RESIDUAL_PIXEL rtl_residual [2:0];
    // function model outputs
    logic model_valid;
    logic model_last;
    logic model_use_bp;
    logic [3:0] model_vector;
    tDSC_PIXEL model_predict [2:0];
    tDSC_RESIDUAL_PIXEL model_residual [2:0];

    int use_bp_mismatches = 0;
    int vector_mismatches = 0;
    int predict_mismatches = 0;
    int residual_mismatches = 0;
    int compare_count = 0;

    // trace storage: 1 + 12 packed pixels per group
    logic [47:0] trace_pixel [0:kGROUPS-1][0:11];
    logic        trace_last [0:kGROUPS-1];

    always #3 dsc_clk = ~dsc_clk;

    dsce_bpvector rtl (
        .dsc_clk, .dsc_reset_n, .cfg_dsc_encoder, .dsc_pps_update, .cfg_pps,
        .dsc_valid_in(valid_in), .dsc_last_in(last_in),
        .dsc_group_in(group_in), .dsc_prev_line_in(prev_in),
        .dsc_recon_group_in(recon_in),
        .dsc_valid_out(rtl_valid), .dsc_last_out(rtl_last),
        .dsc_use_bp(rtl_use_bp), .dsc_bpvector(rtl_vector),
        .dsc_predict_out(rtl_predict), .dsc_residual_out(rtl_residual));

    dsce_bpvector_function_model model (
        .dsc_clk, .dsc_reset_n, .cfg_dsc_encoder, .dsc_pps_update, .cfg_pps,
        .dsc_valid_in(valid_in), .dsc_last_in(last_in),
        .dsc_group_in(group_in), .dsc_prev_line_in(prev_in),
        .dsc_recon_group_in(recon_in),
        .dsc_valid_out(model_valid), .dsc_last_out(model_last),
        .dsc_use_bp(model_use_bp), .dsc_bpvector(model_vector),
        .dsc_predict_out(model_predict), .dsc_residual_out(model_residual));

    always @(posedge dsc_clk) begin : Scoreboard
        if (rtl_valid && model_valid) begin
            compare_count++;
            if (rtl_use_bp !== model_use_bp) begin
                if (use_bp_mismatches == 0)
                    $display("BP_USE_BP_MISMATCH count=%0d rtl=%0b model=%0b vector_rtl=%0d vector_model=%0d",
                             compare_count, rtl_use_bp, model_use_bp, rtl_vector, model_vector);
                use_bp_mismatches++;
            end
            if (rtl_vector !== model_vector) begin
                if (vector_mismatches < 8)
                    $display("BP_VECTOR_MISMATCH count=%0d rtl=%0d model=%0d",
                             compare_count, rtl_vector, model_vector);
                vector_mismatches++;
            end
            if (rtl_use_bp === model_use_bp && rtl_use_bp) begin
                for (int sample = 0; sample < 3; sample++) begin
                    if (rtl_predict[sample] !== model_predict[sample]) begin
                        if (predict_mismatches < 8)
                            $display("BP_PREDICT_MISMATCH count=%0d sample=%0d rtl=%03x/%03x/%03x model=%03x/%03x/%03x",
                                     compare_count, sample,
                                     rtl_predict[sample].y, rtl_predict[sample].co, rtl_predict[sample].cg,
                                     model_predict[sample].y, model_predict[sample].co, model_predict[sample].cg);
                        predict_mismatches++;
                    end
                    if (rtl_residual[sample] !== model_residual[sample]) begin
                        if (residual_mismatches < 8)
                            $display("BP_RESIDUAL_MISMATCH count=%0d sample=%0d rtl=%03x/%03x/%03x model=%03x/%03x/%03x",
                                     compare_count, sample,
                                     rtl_residual[sample].res_y, rtl_residual[sample].res_co, rtl_residual[sample].res_cg,
                                     model_residual[sample].res_y, model_residual[sample].res_co, model_residual[sample].res_cg);
                        residual_mismatches++;
                    end
                end
            end
        end
    end

    initial begin : TestSequence
        int trace_handle;
        logic [47:0] pv [0:11];
        int tl;

        cfg_pps.bits_per_component = 4'd8;
        cfg_pps.convert_rgb = 1'b1;
        cfg_pps.slice_width = 16'd96;
        cfg_pps.slice_height = 16'd108;
        cfg_pps.block_pred_enable = 1'b1;

        trace_handle = $fopen("tests/verilator/generated/bp_input_trace.txt", "r");
        if (trace_handle == 0) $fatal(1, "无法打开 BP 输入 trace");

        for (int group = 0; group < kGROUPS; group++) begin
            $fscanf(trace_handle, "%d %h %h %h %h %h %h %h %h %h %h %h %h",
                    tl, pv[0], pv[1], pv[2], pv[3], pv[4], pv[5], pv[6], pv[7],
                    pv[8], pv[9], pv[10], pv[11]);
            trace_last[group] = tl[0];
            for (int px = 0; px < 12; px++)
                trace_pixel[group][px] = pv[px];
        end
        $fclose(trace_handle);

        repeat (8) @(posedge dsc_clk);
        dsc_reset_n = 1'b1;
        @(negedge dsc_clk);
        dsc_pps_update = 1'b1;
        @(negedge dsc_clk);
        dsc_pps_update = 1'b0;

        for (int group = 0; group < kGROUPS; group++) begin
            for (int px = 0; px < 3; px++) begin
                group_in[px].y  = trace_pixel[group][px][15:0];
                group_in[px].co = trace_pixel[group][px][31:16];
                group_in[px].cg = trace_pixel[group][px][47:32];
            end
            for (int px = 0; px < 6; px++) begin
                prev_in[px].y  = trace_pixel[group][px + 3][15:0];
                prev_in[px].co = trace_pixel[group][px + 3][31:16];
                prev_in[px].cg = trace_pixel[group][px + 3][47:32];
            end
            for (int px = 0; px < 3; px++) begin
                recon_in[px].y  = trace_pixel[group][px + 9][15:0];
                recon_in[px].co = trace_pixel[group][px + 9][31:16];
                recon_in[px].cg = trace_pixel[group][px + 9][47:32];
            end
            last_in = trace_last[group];
            @(negedge dsc_clk);
            valid_in = 1'b1;
            @(negedge dsc_clk);
            valid_in = 1'b0;
            repeat (2) @(negedge dsc_clk);
        end

        repeat (256) @(negedge dsc_clk);
        $display("BP_REPLAY compared=%0d use_bp_mismatches=%0d vector_mismatches=%0d predict_mismatches=%0d residual_mismatches=%0d",
                 compare_count, use_bp_mismatches, vector_mismatches, predict_mismatches, residual_mismatches);
        if (use_bp_mismatches == 0 && vector_mismatches == 0 && predict_mismatches == 0 && residual_mismatches == 0)
            $display("PASS: BP replay 与 function model 一致");
        else
            $display("FAIL: BP replay 存在差异");
        $finish;
    end
endmodule
