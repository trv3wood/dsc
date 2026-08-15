// 仿真用时钟域同步器模型；不描述亚稳态，只保留寄存器级延迟。
module gprim_sync_stage (
    input  logic sync_clk,
    input  logic reset_n,
    input  logic async_in,
    output logic sync_out
);
    always_ff @(posedge sync_clk or negedge reset_n) begin
        if (!reset_n)
            sync_out <= 1'b0;
        else
            sync_out <= async_in;
    end
endmodule


module gprim_sync2_stage (
    input  logic sync_clk,
    input  logic reset_n,
    input  logic async_in,
    output logic [1:0] sync_out
);
    always_ff @(posedge sync_clk or negedge reset_n) begin
        if (!reset_n)
            sync_out <= 2'b00;
        else
            // 原工程把 bit 0 当作当前采样值，bit 1 当作延迟值；两位异或检测边沿。
            sync_out <= {sync_out[0], async_in};
    end
endmodule
