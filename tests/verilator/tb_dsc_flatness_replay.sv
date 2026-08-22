`timescale 1ns/1ps

import dsce_defs_pkg::*;

module tb_dsc_flatness_replay;
    localparam int pGROUPS_PER_LINE = 32;
    localparam int pLINES = 108;
    localparam int pTOTAL_GROUPS = pLINES * pGROUPS_PER_LINE;

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
    logic [47:0] expected_check_1 [0:3455];
    logic [47:0] expected_check_2 [0:3455];
    int output_index = 0;
    int check_index = 0;
    int errors = 0;
    int group_errors = 0;
    int valid_period = 3;

    always #5 dsc_clk = ~dsc_clk;

    dsce_flatness dut (.*);

    task automatic drive_group(input int group_index);
        @(negedge dsc_clk);
        dsc_source_valid_in = 1'b1;
        dsc_source_last_in = group_index % pGROUPS_PER_LINE == pGROUPS_PER_LINE - 1;
        for (int lane = 0; lane < 3; lane++)
            dsc_source_group_in[lane] = pixel_words[group_index][lane * 48 +: 48];
        @(negedge dsc_clk);
        dsc_source_valid_in = 1'b0;
        dsc_source_last_in = 1'b0;
        repeat (valid_period - 1) @(negedge dsc_clk);
    endtask

    always @(negedge dsc_clk) begin
        if (output_index < pTOTAL_GROUPS)
            dsc_primary_qp = qp_words[output_index];
    end

    always @(posedge dsc_clk) begin
        #1;
        if (dut.i_group_valid_check) begin
            if (dut.i_group_check_diff[1] !== expected_check_1[check_index] ||
                dut.i_group_check_diff[2] !== expected_check_2[check_index]) begin
                $display("CHECK_MISMATCH group=%0d expected=%012x/%012x actual=%012x/%012x",
                    check_index, expected_check_1[check_index], expected_check_2[check_index],
                    dut.i_group_check_diff[1], dut.i_group_check_diff[2]);
                $fatal(1, "flat_check 首个边界差异");
            end
            check_index++;
        end
        if (dsc_group_valid_out) begin
            if (output_index < 5 || (output_index < 40 &&
                (output_index >= 28 || dsc_group_last_out)))
                $display("FLAT_OUT group=%0d last=%0b flags=%02x", output_index,
                         dsc_group_last_out, dsc_vlc_flat_flags_out);
            for (int lane = 0; lane < 3; lane++) begin
                if (dsc_group_out[lane] !== pixel_words[output_index][lane * 48 +: 48]) begin
                    if (group_errors < 8)
                        $display("GROUP_MISMATCH group=%0d lane=%0d expected=%012x actual=%012x",
                            output_index, lane,
                            pixel_words[output_index][lane * 48 +: 48],
                            dsc_group_out[lane]);
                    group_errors++;
                end
            end
            if (dsc_vlc_flat_flags_out !== expected_flags[output_index]) begin
                $display("FLAT_MISMATCH group=%0d qp=%0d expected=%02x actual=%02x",
                    output_index, dsc_primary_qp, expected_flags[output_index],
                    dsc_vlc_flat_flags_out);
                errors++;
            end
            if (dsc_group_last_out !== (output_index % pGROUPS_PER_LINE == pGROUPS_PER_LINE - 1)) begin
                $display("LAST_MISMATCH group=%0d actual=%0b", output_index, dsc_group_last_out);
                errors++;
            end
            output_index++;
        end
    end

    initial begin
        void'($value$plusargs("VALID_PERIOD=%d", valid_period));
        if (valid_period < 1)
            $fatal(1, "VALID_PERIOD 必须大于 0");
        $readmemh("tests/verilator/generated/flatness_pixels.hex", pixel_words);
        $readmemh("tests/verilator/generated/flatness_qp.hex", qp_words);
        $readmemh("tests/verilator/generated/flatness_expected.hex", expected_flags);
        $readmemh("tests/verilator/generated/flatness_check1.hex", expected_check_1);
        $readmemh("tests/verilator/generated/flatness_check2.hex", expected_check_2);
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

        for (int line_index = 0; line_index < pLINES; line_index++) begin
            for (int group_index = 0; group_index < pGROUPS_PER_LINE; group_index++)
                drive_group(line_index * pGROUPS_PER_LINE + group_index);
            wait (output_index == (line_index + 1) * pGROUPS_PER_LINE);
        end
        @(negedge dsc_clk);
        dsc_source_valid_in = 1'b0;
        dsc_source_last_in = 1'b0;

        repeat (100) @(negedge dsc_clk);
        if (output_index != pTOTAL_GROUPS)
            $fatal(1, "flatness replay 超时，只输出 %0d/%0d groups", output_index, pTOTAL_GROUPS);
        if (errors != 0 || group_errors != 0)
            $fatal(1, "flatness replay 失败，flags=%0d groups=%0d", errors, group_errors);
        $display("PASS: flatness replay 逐事务比对通过，共 %0d groups", output_index);
        $finish;
    end
endmodule
