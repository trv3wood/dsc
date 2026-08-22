`timescale 1ns/1ps

import dsce_defs_pkg::*;

module tb_dsce_ich_decision_replay;
    localparam int pVECTOR_WIDTH = 508;
    localparam int pMAX_VECTOR_COUNT = 4096;

    logic dsc_clk = 1'b0;
    logic dsc_reset_n = 1'b0;
    logic [pVECTOR_WIDTH-1:0] vectors [0:pMAX_VECTOR_COUNT-1];
    string vector_file;
    int vector_count;

    logic [3:0] cfg_bits_per_component;
    logic cfg_convert_rgb;
    logic [3:0] cfg_dsc_version_minor;
    logic [2:0] cfg_slice_alignment;
    logic dsc_start_of_slice;
    logic dsc_group_valid_in;
    logic dsc_group_last_in;
    tDSC_PIXEL dsc_group_in [2:0];
    logic dsc_ich_next_is_very_flat;
    logic [4:0] dsc_vlc_size_in [2:0];
    tDSC_QLEVEL dsc_qlevel_y_in;
    tDSC_QLEVEL dsc_qlevel_c_in;
    logic dsc_force_mpp_in;
    logic dsc_predict_valid_in;
    tDSC_PIXEL dsc_predict_group_in [2:0];
    logic [4:0] dsc_residual_size_in [2:0];
    logic [2:0] dsc_ich_hit;
    tDSC_ICH_INDEX dsc_ich_index_in [2:0];
    tDSC_PIXEL dsc_ich_pixel_in [2:0];
    logic dsc_ich_valid_out;
    logic dsc_ich_select_out;
    tDSC_ICH_INDEX dsc_ich_index_out [2:0];
    tDSC_PIXEL dsc_ich_group_out [2:0];
    logic expected_select;

    always #5 dsc_clk = ~dsc_clk;

    dsce_ich_decision dut (.*);

    task automatic drive_vector(input int tx);
        {
            cfg_bits_per_component,
            cfg_convert_rgb,
            cfg_dsc_version_minor,
            cfg_slice_alignment,
            dsc_start_of_slice,
            dsc_group_last_in,
            dsc_group_in[0],
            dsc_group_in[1],
            dsc_group_in[2],
            dsc_ich_next_is_very_flat,
            dsc_vlc_size_in[0],
            dsc_vlc_size_in[1],
            dsc_vlc_size_in[2],
            dsc_qlevel_y_in,
            dsc_qlevel_c_in,
            dsc_force_mpp_in,
            dsc_predict_valid_in,
            dsc_predict_group_in[0],
            dsc_predict_group_in[1],
            dsc_predict_group_in[2],
            dsc_residual_size_in[0],
            dsc_residual_size_in[1],
            dsc_residual_size_in[2],
            dsc_ich_hit,
            dsc_ich_index_in[0],
            dsc_ich_index_in[1],
            dsc_ich_index_in[2],
            dsc_ich_pixel_in[0],
            dsc_ich_pixel_in[1],
            dsc_ich_pixel_in[2],
            expected_select
        } = vectors[tx];
        dsc_group_valid_in = 1'b1;
    endtask

    initial begin : Replay
        int mismatches;
        mismatches = 0;
        vector_file = "tests/verilator/vectors/ich_decision_vesa_boats_tx0_307.hex";
        vector_count = 308;
        void'($value$plusargs("vector=%s", vector_file));
        void'($value$plusargs("vector_count=%d", vector_count));
        if (vector_count <= 0 || vector_count > pMAX_VECTOR_COUNT)
            $fatal(1, "vector_count=%0d 超出 1..%0d", vector_count, pMAX_VECTOR_COUNT);
        $readmemh(vector_file, vectors, 0, vector_count - 1);
        dsc_group_valid_in = 1'b0;
        dsc_predict_valid_in = 1'b0;
        dsc_start_of_slice = 1'b0;
        repeat (3) @(posedge dsc_clk);
        dsc_reset_n = 1'b1;

        // 原 e2e 的 start-of-slice 在第一笔 group valid 之前独立到达。
        @(negedge dsc_clk);
        dsc_start_of_slice = 1'b1;
        @(posedge dsc_clk);
        @(negedge dsc_clk);
        dsc_start_of_slice = 1'b0;

        for (int tx = 0; tx < vector_count; tx++) begin
            drive_vector(tx);
            #1;
            if (dsc_ich_valid_out !== dsc_predict_valid_in)
                $fatal(1, "tx=%0d valid 不一致", tx);
            if (dsc_ich_select_out !== expected_select) begin
                mismatches++;
                $display("ICH_REPLAY_MISMATCH tx=%0d expected=%0b actual=%0b bits=%0d/%0d log=%0d/%0d cost=%0d/%0d prev_ich=%0b",
                    tx, expected_select, dsc_ich_select_out,
                    dut.i_bits_p_mode, dut.i_bits_ich_mode,
                    dut.i_log_err_predict_mode, dut.i_log_err_ich_mode,
                    dut.i_predict_mode_cost, dut.i_ich_mode_cost, dut.i_prev_ich);
                $display("ICH_REPLAY_ERROR pred=%0d/%0d/%0d ich=%0d/%0d/%0d adj=%0d/%0d/%0d residual=%0d/%0d/%0d",
                    dut.i_max_error_predict_mode[0], dut.i_max_error_predict_mode[1], dut.i_max_error_predict_mode[2],
                    dut.i_max_error_ich_mode[0], dut.i_max_error_ich_mode[1], dut.i_max_error_ich_mode[2],
                    dut.i_adj_predicted_size[0], dut.i_adj_predicted_size[1], dut.i_adj_predicted_size[2],
                    dsc_residual_size_in[0], dsc_residual_size_in[1], dsc_residual_size_in[2]);
                $display("ICH_REPLAY_HISTORY prev=%012x/%012x/%012x predict=%012x/%012x/%012x ich=%012x/%012x/%012x",
                    dut.i_prev_group_in[0], dut.i_prev_group_in[1], dut.i_prev_group_in[2],
                    dsc_predict_group_in[0], dsc_predict_group_in[1], dsc_predict_group_in[2],
                    dsc_ich_pixel_in[0], dsc_ich_pixel_in[1], dsc_ich_pixel_in[2]);
            end
            @(posedge dsc_clk);
            @(negedge dsc_clk);
            dsc_group_valid_in = 1'b0;
            dsc_predict_valid_in = 1'b0;
        end

        $display("ICH_REPLAY vector=%s transactions=%0d mismatches=%0d",
            vector_file, vector_count, mismatches);
        if (mismatches != 0)
            $fatal(1, "ICH decision replay 与官方期望不一致");
        $finish;
    end
endmodule
