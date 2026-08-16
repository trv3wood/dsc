// ------------------------------------------------------------------------------------------------
//     COPYRIGHT © 2023, TRILINEAR TECHNOLOGIES, INC.
//     CONFIDENTIAL AND PROPRIETARY
// ------------------------------------------------------------------------------------------------
//     DESCRIPTION : Calculate the two original-pixel flatness windows for each group.
// ------------------------------------------------------------------------------------------------

import dsce_defs_pkg::*;

module dsce_flat_check
(
    input   logic           dsc_clk,
    input   logic           dsc_reset_n,
    input   logic           dsc_start_of_slice,
    input   logic           dsc_group_valid_in,
    input   logic           dsc_group_last_in,
    input   tDSC_PIXEL      dsc_group_in [2:0],
    output  logic           dsc_group_valid_out,
    output  logic           dsc_group_last_out,
    output  tDSC_PIXEL      dsc_group_out [2:0],
    output  tDSC_PIXEL      dsc_check_diff_out [2:1]
);

    tDSC_PIXEL i_group_0 [2:0];
    tDSC_PIXEL i_group_1 [2:0];
    logic [1:0] i_group_valid;
    logic [1:0] i_flush_count;
    tDSC_PIXEL i_pad_pixel;
    tDSC_PIXEL i_new_group [2:0];
    logic i_accept_group;

    always_comb begin : InputMap
        i_accept_group = dsc_group_valid_in || i_flush_count != 0;
        i_new_group = dsc_group_valid_in ? dsc_group_in : '{default: i_pad_pixel};
    end : InputMap

    always_ff @(posedge dsc_clk or negedge dsc_reset_n) begin : FlatnessWindows
        if (!dsc_reset_n) begin
            i_group_0 <= '{default: kDSC_PIXEL_INIT};
            i_group_1 <= '{default: kDSC_PIXEL_INIT};
            i_group_valid <= 2'b00;
            i_flush_count <= 2'd0;
            i_pad_pixel <= kDSC_PIXEL_INIT;
            dsc_group_valid_out <= 1'b0;
            dsc_group_last_out <= 1'b0;

            dsc_group_out <= '{default: kDSC_PIXEL_INIT};
            dsc_check_diff_out <= '{default: kDSC_PIXEL_INIT};
        end else begin
            dsc_group_valid_out <= 1'b0;
            dsc_group_last_out <= 1'b0;

            if (dsc_start_of_slice) begin
                i_group_valid <= 2'b00;
                i_flush_count <= 2'd0;
            end else if (i_accept_group) begin
                if (!i_group_valid[0]) begin
                    i_group_0 <= i_new_group;
                    i_group_valid[0] <= 1'b1;
                end else if (!i_group_valid[1]) begin
                    i_group_1 <= i_new_group;
                    i_group_valid[1] <= 1'b1;
                end else begin
                    tDSC_PIXEL check_min;
                    tDSC_PIXEL check_max;

                    // Check 1 对应 C model 的 [hPos, hPos+3]：
                    // 当前目标组的末像素，加上下一个完整 group。
                    check_min.y = dsce_min_2(i_group_0[2].y,
                        dsce_min_3(i_group_1[0].y, i_group_1[1].y, i_group_1[2].y));
                    check_min.co = dsce_min_2(i_group_0[2].co,
                        dsce_min_3(i_group_1[0].co, i_group_1[1].co, i_group_1[2].co));
                    check_min.cg = dsce_min_2(i_group_0[2].cg,
                        dsce_min_3(i_group_1[0].cg, i_group_1[1].cg, i_group_1[2].cg));
                    check_max.y = dsce_max_2(i_group_0[2].y,
                        dsce_max_3(i_group_1[0].y, i_group_1[1].y, i_group_1[2].y));
                    check_max.co = dsce_max_2(i_group_0[2].co,
                        dsce_max_3(i_group_1[0].co, i_group_1[1].co, i_group_1[2].co));
                    check_max.cg = dsce_max_2(i_group_0[2].cg,
                        dsce_max_3(i_group_1[0].cg, i_group_1[1].cg, i_group_1[2].cg));
                    dsc_check_diff_out[1] <= check_max - check_min;

                    // Check 2 对应 [hPos+1, hPos+6]：后续两个完整 group。
                    check_min.y = dsce_min_2(
                        dsce_min_3(i_group_1[0].y, i_group_1[1].y, i_group_1[2].y),
                        dsce_min_3(i_new_group[0].y, i_new_group[1].y, i_new_group[2].y));
                    check_min.co = dsce_min_2(
                        dsce_min_3(i_group_1[0].co, i_group_1[1].co, i_group_1[2].co),
                        dsce_min_3(i_new_group[0].co, i_new_group[1].co, i_new_group[2].co));
                    check_min.cg = dsce_min_2(
                        dsce_min_3(i_group_1[0].cg, i_group_1[1].cg, i_group_1[2].cg),
                        dsce_min_3(i_new_group[0].cg, i_new_group[1].cg, i_new_group[2].cg));
                    check_max.y = dsce_max_2(
                        dsce_max_3(i_group_1[0].y, i_group_1[1].y, i_group_1[2].y),
                        dsce_max_3(i_new_group[0].y, i_new_group[1].y, i_new_group[2].y));
                    check_max.co = dsce_max_2(
                        dsce_max_3(i_group_1[0].co, i_group_1[1].co, i_group_1[2].co),
                        dsce_max_3(i_new_group[0].co, i_new_group[1].co, i_new_group[2].co));
                    check_max.cg = dsce_max_2(
                        dsce_max_3(i_group_1[0].cg, i_group_1[1].cg, i_group_1[2].cg),
                        dsce_max_3(i_new_group[0].cg, i_new_group[1].cg, i_new_group[2].cg));
                    dsc_check_diff_out[2] <= check_max - check_min;

                    dsc_group_valid_out <= 1'b1;
                    dsc_group_last_out <= i_flush_count == 2'd1;
                    dsc_group_out <= i_group_0;
                    i_group_0 <= i_group_1;
                    i_group_1 <= i_new_group;
                end

                if (dsc_group_valid_in && dsc_group_last_in) begin
                    i_pad_pixel <= dsc_group_in[2];
                    i_flush_count <= 2'd2;
                end else if (!dsc_group_valid_in && i_flush_count != 0) begin
                    i_flush_count <= i_flush_count - 1'b1;
                    if (i_flush_count == 2'd1)
                        i_group_valid <= 2'b00;
                end
            end
        end
    end : FlatnessWindows

endmodule : dsce_flat_check
