`timescale 1ns/1ps

import dsce_defs_pkg::*;

// 验证连续 slice 边界不会破坏仍在 flatness 流水中的行末事务。
module tb_dsc_flatness_slice_boundary;
    localparam int pGROUPS_PER_LINE = 32;
    localparam int pLINES_PER_SLICE = 2;
    localparam int pSLICES = 2;
    localparam int pTOTAL_GROUPS = pGROUPS_PER_LINE * pLINES_PER_SLICE * pSLICES;

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

    tDSC_PIXEL expected_group [pTOTAL_GROUPS][2:0];
    int output_count = 0;

    always #5 dsc_clk = ~dsc_clk;

    dsce_flatness dut (.*);

    function automatic tDSC_PIXEL make_pixel(input int group_index, input int lane);
        tDSC_PIXEL pixel;
        pixel.y = 16'(group_index * 3 + lane);
        pixel.co = 16'h4000 + 16'(group_index * 3 + lane);
        pixel.cg = 16'h8000 + 16'(group_index * 3 + lane);
        return pixel;
    endfunction

    task automatic drive_group(input int group_index);
        @(negedge dsc_clk);
        dsc_source_valid_in = 1'b1;
        dsc_source_last_in = group_index % pGROUPS_PER_LINE == pGROUPS_PER_LINE - 1;
        for (int lane = 0; lane < 3; lane++) begin
            dsc_source_group_in[lane] = make_pixel(group_index, lane);
            expected_group[group_index][lane] = make_pixel(group_index, lane);
        end
        @(negedge dsc_clk);
        dsc_source_valid_in = 1'b0;
        dsc_source_last_in = 1'b0;
        repeat (3) @(negedge dsc_clk);
    endtask

    always @(posedge dsc_clk) begin
        #1;
        if (dsc_group_valid_out) begin
            if (output_count >= pTOTAL_GROUPS)
                $fatal(1, "flatness 输出多余事务");
            for (int lane = 0; lane < 3; lane++) begin
                if (dsc_group_out[lane] !== expected_group[output_count][lane])
                    $fatal(1,
                        "group 顺序错误: tx=%0d lane=%0d expected=%012x actual=%012x",
                        output_count, lane, expected_group[output_count][lane], dsc_group_out[lane]);
            end
            if (dsc_group_last_out !==
                (output_count % pGROUPS_PER_LINE == pGROUPS_PER_LINE - 1))
                $fatal(1, "last 错位: tx=%0d actual=%0b", output_count, dsc_group_last_out);
            output_count++;
        end
    end

    initial begin
        dsc_source_group_in = '{default: kDSC_PIXEL_INIT};
        expected_group = '{default: '{default: kDSC_PIXEL_INIT}};

        repeat (4) @(negedge dsc_clk);
        dsc_reset_n = 1'b1;
        cfg_pps.dsc_version_minor = 4'd2;
        cfg_pps.bits_per_component = 4'd8;
        cfg_pps.convert_rgb = 1'b1;
        cfg_pps.flatness_min_qp = 5'd3;
        cfg_pps.flatness_max_qp = 5'd12;
        dsc_pps_update = 1'b1;
        @(negedge dsc_clk);
        dsc_pps_update = 1'b0;

        for (int slice_index = 0; slice_index < pSLICES; slice_index++) begin
            dsc_start_of_slice = 1'b1;
            @(negedge dsc_clk);
            dsc_start_of_slice = 1'b0;
            for (int line_index = 0; line_index < pLINES_PER_SLICE; line_index++) begin
                for (int group_index = 0; group_index < pGROUPS_PER_LINE; group_index++) begin
                    drive_group((slice_index * pLINES_PER_SLICE + line_index) *
                        pGROUPS_PER_LINE + group_index);
                end
                // 普通行等待 flatness 排空；仅在 slice 边界保持连续输入，
                // 精确覆盖 slice_buffer 先发 start、末组仍在下游 flush 的场景。
                if (line_index != pLINES_PER_SLICE - 1)
                    wait (output_count ==
                        (slice_index * pLINES_PER_SLICE + line_index + 1) * pGROUPS_PER_LINE);
            end
        end

        repeat (300) @(negedge dsc_clk);
        if (output_count != pTOTAL_GROUPS)
            $fatal(1, "flatness slice boundary 超时，只输出 %0d/%0d groups",
                output_count, pTOTAL_GROUPS);
        $display("PASS: flatness slice boundary，共 %0d groups", output_count);
        $finish;
    end
endmodule
