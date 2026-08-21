import dsce_defs_pkg::*;

// 检查 syntax FIFO 的输入 valid 与 payload 是否属于同一接受事务。
module stream_fifo_acceptance_formal(
    input logic clk
);

    logic       reset_n = 1'b0;
    logic [2:0] step = 3'd0;
    logic       input_valid;
    logic [5:0] input_data;
    logic       output_valid;
    logic [5:0] output_data;

    always_comb begin
        input_valid = reset_n && step == 3'd1;
        // 接受拍之后故意改变 live payload，验证 DUT 不会晚一拍误采样。
        input_data = step == 3'd1 ? 6'h15 : 6'h2a;
    end

    dsce_stream_fifo dut (
        .dsc_clk                  (clk),
        .dsc_reset_n              (reset_n),
        .dsc_start_of_slice       (1'b0),
        .dsc_muxword_valid_in     (1'b0),
        .dsc_muxword_last_in      (1'b0),
        .dsc_muxword_in           (64'd0),
        .dsc_unit_size_valid_in   (input_valid),
        .dsc_unit_size_last_in    (1'b0),
        .dsc_coded_unit_size_in   (input_data),
        .dsc_coded_size_valid_out (output_valid),
        .dsc_coded_size_ready_out (1'b0),
        .dsc_coded_size_last_out  (),
        .dsc_coded_size_out       (output_data),
        .dsc_muxword_valid_out    (),
        .dsc_muxword_ready_out    (1'b0),
        .dsc_muxword_last_out     (),
        .dsc_muxword_out          ()
    );

    always_ff @(posedge clk) begin
        reset_n <= 1'b1;
        if (reset_n && step != 3'd7)
            step <= step + 1'b1;

        if (output_valid)
            assert (output_data == 6'h15);

        cover (output_valid);
    end
endmodule
