import dsce_defs_pkg::*;

module flatness_window_formal(
    input logic         clk,
    input logic [143:0] pixels_0,
    input logic [143:0] pixels_1,
    input logic [143:0] pixels_2
);
    logic reset_n = 1'b0;
    logic [2:0] step = 3'd0;
    logic past_valid = 1'b0;

    tDSC_PIXEL group_0 [2:0];
    tDSC_PIXEL group_1 [2:0];
    tDSC_PIXEL group_2 [2:0];
    tDSC_PIXEL input_group [2:0];
    tDSC_PIXEL output_group [2:0];
    tDSC_PIXEL output_diff [2:1];
    logic input_valid;
    logic output_valid;

    for (genvar px = 0; px < 3; px++) begin : PixelMap
        assign group_0[px] = pixels_0[px*48 +: 48];
        assign group_1[px] = pixels_1[px*48 +: 48];
        assign group_2[px] = pixels_2[px*48 +: 48];
    end

    always_comb begin
        input_valid = reset_n && step < 3;
        case (step)
            3'd0: input_group = group_0;
            3'd1: input_group = group_1;
            default: input_group = group_2;
        endcase
    end

    dsce_flat_check dut (
        .dsc_clk             (clk),
        .dsc_reset_n         (reset_n),
        .dsc_start_of_slice  (1'b0),
        .dsc_group_valid_in  (input_valid),
        .dsc_group_last_in   (1'b0),
        .dsc_group_in        (input_group),
        .dsc_group_valid_out (output_valid),
        .dsc_group_last_out  (),
        .dsc_group_out       (output_group),
        .dsc_check_diff_out  (output_diff)
    );

    function automatic logic [15:0] min2(input logic [15:0] a, b);
        return a < b ? a : b;
    endfunction

    function automatic logic [15:0] max2(input logic [15:0] a, b);
        return a > b ? a : b;
    endfunction

    function automatic logic [15:0] min3(input logic [15:0] a, b, c);
        return min2(min2(a, b), c);
    endfunction

    function automatic logic [15:0] max3(input logic [15:0] a, b, c);
        return max2(max2(a, b), c);
    endfunction

    always_ff @(posedge clk) begin
        past_valid <= 1'b1;
        if (past_valid) begin
            assume (pixels_0 == $past(pixels_0));
            assume (pixels_1 == $past(pixels_1));
            assume (pixels_2 == $past(pixels_2));
        end

        reset_n <= 1'b1;
        if (reset_n && step < 3)
            step <= step + 1'b1;

        if (output_valid) begin
            // hPos 指向候选 group 末像素；Check 1 再包含下一完整 group。
            assert (output_diff[1].y ==
                    max2(group_0[2].y, max3(group_1[0].y, group_1[1].y, group_1[2].y)) -
                    min2(group_0[2].y, min3(group_1[0].y, group_1[1].y, group_1[2].y)));
            assert (output_diff[1].co ==
                    max2(group_0[2].co, max3(group_1[0].co, group_1[1].co, group_1[2].co)) -
                    min2(group_0[2].co, min3(group_1[0].co, group_1[1].co, group_1[2].co)));
            assert (output_diff[1].cg ==
                    max2(group_0[2].cg, max3(group_1[0].cg, group_1[1].cg, group_1[2].cg)) -
                    min2(group_0[2].cg, min3(group_1[0].cg, group_1[1].cg, group_1[2].cg)));

            // Check 2 覆盖后续两个完整 group。
            assert (output_diff[2].y ==
                    max2(max3(group_1[0].y, group_1[1].y, group_1[2].y), max3(group_2[0].y, group_2[1].y, group_2[2].y)) -
                    min2(min3(group_1[0].y, group_1[1].y, group_1[2].y), min3(group_2[0].y, group_2[1].y, group_2[2].y)));
            assert (output_diff[2].co ==
                    max2(max3(group_1[0].co, group_1[1].co, group_1[2].co), max3(group_2[0].co, group_2[1].co, group_2[2].co)) -
                    min2(min3(group_1[0].co, group_1[1].co, group_1[2].co), min3(group_2[0].co, group_2[1].co, group_2[2].co)));
            assert (output_diff[2].cg ==
                    max2(max3(group_1[0].cg, group_1[1].cg, group_1[2].cg), max3(group_2[0].cg, group_2[1].cg, group_2[2].cg)) -
                    min2(min3(group_1[0].cg, group_1[1].cg, group_1[2].cg), min3(group_2[0].cg, group_2[1].cg, group_2[2].cg)));
        end
    end
endmodule
