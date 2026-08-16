`timescale 1ns/1ps

import dsce_defs_pkg::*;

module tb_dsc_flatness_replay;
    localparam int pGROUPS_PER_LINE = 32;
    localparam int pREPLAY_LINE = 1;
    localparam int pBASE = pREPLAY_LINE * pGROUPS_PER_LINE;

    logic dsc_clk = 1'b0;
    logic dsc_reset_n = 1'b0;
    logic dsc_pps_update = 1'b0;
    tDSC_PPS cfg_pps = kDSC_PPS_INIT;
    logic [4:0] cfg_rc_range_max_qp_14 = 5'd15;
    tDSC_QLEVEL dsc_primary_qp = 5'd0;
    logic dsc_start_of_slice = 1'b0;
    logic dsc_source_valid_in = 1'b0;
    logic dsc_source_last_in = 1'b0;
    tDSC_PIXEL dsc_source_group_in [2:0];
    logic dsc_group_valid_out;
    logic dsc_group_last_out;
    tDSC_PIXEL dsc_group_out [2:0];
    tDSC_FLAT_FLAGS dsc_vlc_flat_flags_out;
    logic dsc_ich_next_is_very_flat;

    logic [143:0] pixel_words [0:3455];
    logic [4:0] qp_words [0:3455];
    logic [7:0] expected_flags [0:3455];
    int output_index = 0;
    int errors = 0;

    always #5 dsc_clk = ~dsc_clk;

    dsce_flatness dut (.*);

    task automatic drive_group(input int group_index);
        @(negedge dsc_clk);
        dsc_source_valid_in = 1'b1;
        dsc_source_last_in = group_index == pGROUPS_PER_LINE - 1;
        for (int lane = 0; lane < 3; lane++)
            dsc_source_group_in[lane] = pixel_words[pBASE + group_index][lane * 48 +: 48];
        @(negedge dsc_clk);
        dsc_source_valid_in = 1'b0;
        dsc_source_last_in = 1'b0;
        // 顶层 decision 路径每三个处理周期送一组，保留真实 valid 相位。
        repeat (2) @(negedge dsc_clk);
    endtask

    always @(negedge dsc_clk) begin
        if (output_index < pGROUPS_PER_LINE)
            dsc_primary_qp = qp_words[pBASE + output_index];
    end

    always @(posedge dsc_clk) begin
        #1;
        if (dsc_group_valid_out) begin
            if (dsc_vlc_flat_flags_out !== expected_flags[pBASE + output_index]) begin
                $display("FLAT_MISMATCH group=%0d qp=%0d expected=%02x actual=%02x",
                    output_index, dsc_primary_qp, expected_flags[pBASE + output_index],
                    dsc_vlc_flat_flags_out);
                errors++;
            end
            if (dsc_group_last_out !== (output_index == pGROUPS_PER_LINE - 1)) begin
                $display("LAST_MISMATCH group=%0d actual=%0b", output_index, dsc_group_last_out);
                errors++;
            end
            output_index++;
        end
    end

    initial begin
        $readmemh("tests/verilator/generated/flatness_pixels.hex", pixel_words);
        $readmemh("tests/verilator/generated/flatness_qp.hex", qp_words);
        $readmemh("tests/verilator/generated/flatness_expected.hex", expected_flags);
        dsc_source_group_in = '{default: kDSC_PIXEL_INIT};

        repeat (4) @(negedge dsc_clk);
        dsc_reset_n = 1'b1;
        cfg_pps.dsc_version_minor = 4'd2;
        cfg_pps.bits_per_component = 4'd8;
        cfg_pps.convert_rgb = 1'b1;
        cfg_pps.flatness_min_qp = 5'd3;
        cfg_pps.flatness_max_qp = 5'd12;
        dsc_pps_update = 1'b1;
        dsc_start_of_slice = 1'b1;
        @(negedge dsc_clk);
        dsc_pps_update = 1'b0;
        dsc_start_of_slice = 1'b0;

        for (int group_index = 0; group_index < pGROUPS_PER_LINE; group_index++)
            drive_group(group_index);
        @(negedge dsc_clk);
        dsc_source_valid_in = 1'b0;
        dsc_source_last_in = 1'b0;

        repeat (100) begin
            @(negedge dsc_clk);
            if (output_index == pGROUPS_PER_LINE) begin
                if (errors == 0)
                    $display("PASS: flatness replay 逐事务比对通过，共 %0d groups", output_index);
                else
                    $fatal(1, "flatness replay 失败，共 %0d 处差异", errors);
                $finish;
            end
        end
        $fatal(1, "flatness replay 超时，只输出 %0d/%0d groups", output_index, pGROUPS_PER_LINE);
    end
endmodule
