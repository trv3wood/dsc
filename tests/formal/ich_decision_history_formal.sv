// SPDX-License-Identifier: MIT

import dsce_defs_pkg::*;

module ich_decision_history_formal(
    input logic dsc_clk
);
    logic dsc_reset_n = 1'b0;
    logic past_valid = 1'b0;
    (* anyseq *) logic [3:0] cfg_bits_per_component;
    (* anyseq *) logic cfg_convert_rgb;
    (* anyseq *) logic [3:0] cfg_dsc_version_minor;
    (* anyseq *) logic [2:0] cfg_slice_alignment;
    (* anyseq *) logic dsc_start_of_slice;
    (* anyseq *) logic dsc_group_valid_in;
    (* anyseq *) logic dsc_group_last_in;
    (* anyseq *) tDSC_PIXEL dsc_group_in [2:0];
    (* anyseq *) logic dsc_ich_next_is_very_flat;
    (* anyseq *) logic [4:0] dsc_vlc_size_in [2:0];
    (* anyseq *) tDSC_QLEVEL dsc_qlevel_y_in;
    (* anyseq *) tDSC_QLEVEL dsc_qlevel_c_in;
    (* anyseq *) logic dsc_force_mpp_in;
    (* anyseq *) logic dsc_predict_valid_in;
    (* anyseq *) tDSC_PIXEL dsc_predict_group_in [2:0];
    (* anyseq *) logic [4:0] dsc_residual_size_in [2:0];
    (* anyseq *) logic [2:0] dsc_ich_hit;
    (* anyseq *) tDSC_ICH_INDEX dsc_ich_index_in [2:0];
    (* anyseq *) tDSC_PIXEL dsc_ich_pixel_in [2:0];

    logic dsc_ich_valid_out;
    logic dsc_ich_select_out;
    tDSC_ICH_INDEX dsc_ich_index_out [2:0];
    tDSC_PIXEL dsc_ich_group_out [2:0];

    dsce_ich_decision dut (.*);

    always_ff @(posedge dsc_clk) begin
        past_valid <= 1'b1;
        dsc_reset_n <= 1'b1;

        // 避免把两个不同事务接口的 valid 关系留成无意义的环境自由度。
        assume (dsc_group_valid_in == dsc_predict_valid_in);
        assume (!dsc_start_of_slice || !dsc_group_valid_in);

        if (past_valid && $past(dsc_reset_n)) begin
            if ($past(dsc_start_of_slice)) begin
                for (int px = 0; px < 3; px++)
                    assert (dut.i_prev_group_in[px] == kDSC_PIXEL_INIT);
                for (int cp = 0; cp < 2; cp++) begin
                    assert (dut.i_qlevel[cp] == kDSC_QLEVEL_ZERO);
                    assert (dut.i_prev_qlevel[cp] == kDSC_QLEVEL_ZERO);
                end
                assert (!dut.i_prev_ich);
                assert (!dut.i_prev_group_last);
            end else if (!$past(dsc_group_valid_in)) begin
                // 空泡输入可以任意抖动，但所有事务历史必须保持不变。
                assert (dut.i_prev_group_in == $past(dut.i_prev_group_in));
                assert (dut.i_qlevel == $past(dut.i_qlevel));
                assert (dut.i_prev_qlevel == $past(dut.i_prev_qlevel));
                assert (dut.i_prev_ich == $past(dut.i_prev_ich));
                assert (dut.i_prev_group_last == $past(dut.i_prev_group_last));
                assert (dut.i_predicted_size == $past(dut.i_predicted_size));
            end
        end
    end
endmodule
