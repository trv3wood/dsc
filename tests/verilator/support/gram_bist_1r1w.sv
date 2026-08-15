// 仿真用同步读、同步写双端口 RAM；BIST 端口仅保持接口兼容。
module gram_bist_1r1w #(
    parameter int pRW_CHECK     = 0,
    parameter int pADDRESS_BITS = 8,
    parameter int pDATA_BITS    = 8
) (
    input  logic                     clk_r,
    input  logic                     en_r,
    input  logic [pADDRESS_BITS-1:0] addr_r,
    output logic [pDATA_BITS-1:0]    data_r,
    input  logic                     clk_w,
    input  logic [pADDRESS_BITS-1:0] addr_w,
    input  logic                     we_w,
    input  logic [pDATA_BITS-1:0]    data_w,
    input  logic [11:0]              bist_in,
    output logic [11:0]              bist_out
);
    logic [pDATA_BITS-1:0] memory [0:(1 << pADDRESS_BITS)-1];

    always_ff @(posedge clk_w) begin
        if (we_w)
            memory[addr_w] <= data_w;
    end

    always_ff @(posedge clk_r) begin
        if (en_r)
            data_r <= memory[addr_r];
    end

    always_comb begin
        bist_out = 12'h000;
    end

    // 防止未使用兼容参数和端口被误认为功能逻辑。
    logic unused;
    always_comb unused = ^{pRW_CHECK, bist_in};
endmodule
