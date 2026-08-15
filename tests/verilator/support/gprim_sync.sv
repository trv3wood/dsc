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
    output logic sync_out
);
    logic sync_meta;

    always_ff @(posedge sync_clk or negedge reset_n) begin
        if (!reset_n) begin
            sync_meta <= 1'b0;
            sync_out  <= 1'b0;
        end else begin
            sync_meta <= async_in;
            sync_out  <= sync_meta;
        end
    end
endmodule
