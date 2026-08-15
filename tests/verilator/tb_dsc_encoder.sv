`timescale 1ns/1ps

module tb_dsc_encoder;
    localparam int kSPC = 4;

    logic         apb_clk = 1'b0;
    logic         dsc_clk = 1'b0;
    logic         axi_clk = 1'b0;
    logic         async_reset_n = 1'b0;
    logic         async_test_mode = 1'b0;
    logic         apb_select = 1'b0;
    logic         apb_enable = 1'b0;
    logic         apb_write = 1'b0;
    logic [3:0]   apb_strobe = 4'h0;
    logic [2:0]   apb_protect = 3'h0;
    logic [11:0]  apb_addr = 12'h000;
    logic [31:0]  apb_wdata = 32'h0000_0000;
    logic         apb_ready;
    logic         apb_slave_error;
    logic         apb_int;
    logic [31:0]  apb_rdata;
    logic         axi_tvalid_in = 1'b0;
    logic         axi_tready_in;
    logic         axi_tline_in = 1'b0;
    logic         axi_tframe_in = 1'b0;
    logic [191:0] axi_tdata_in = 192'h0;
    logic         axi_tvalid_out;
    logic         axi_tready_out = 1'b0;
    logic         axi_tline_out;
    logic         axi_tframe_out;
    logic [191:0] axi_tdata_out;
    logic [11:0]  bist_sram_in [kSPC*4+1:0];
    logic [11:0]  bist_sram_out [kSPC*4+1:0];

    always #5 apb_clk = ~apb_clk;
    always #5 axi_clk = ~axi_clk;
    always #5 dsc_clk = ~dsc_clk;

    dsc_encoder #(
        .pSLICE_PROCESSOR_COUNT(kSPC),
        .pDEBUG_MESSAGES(0)
    ) dut (.*);

    task automatic apb_write32(input logic [11:0] address, input logic [31:0] data);
        @(negedge apb_clk);
        apb_select = 1'b1;
        apb_enable = 1'b0;
        apb_write = 1'b1;
        apb_strobe = 4'hf;
        apb_addr = address;
        apb_wdata = data;
        @(negedge apb_clk);
        apb_enable = 1'b1;
        do @(posedge apb_clk); while (!apb_ready);
        @(negedge apb_clk);
        apb_select = 1'b0;
        apb_enable = 1'b0;
        apb_write = 1'b0;
        apb_strobe = 4'h0;
    endtask

    task automatic apb_read32(input logic [11:0] address, output logic [31:0] data);
        @(negedge apb_clk);
        apb_select = 1'b1;
        apb_enable = 1'b0;
        apb_write = 1'b0;
        apb_addr = address;
        @(negedge apb_clk);
        apb_enable = 1'b1;
        do @(posedge apb_clk); while (!apb_ready);
        #1 data = apb_rdata;
        @(negedge apb_clk);
        apb_select = 1'b0;
        apb_enable = 1'b0;
    endtask

    initial begin : TestSequence
        logic [31:0] read_data;
        logic [191:0] expected_data;
        int timeout;

        for (int index = 0; index < kSPC*4+2; index++)
            bist_sram_in[index] = 12'h000;

        repeat (5) @(posedge apb_clk);
        async_reset_n = 1'b1;
        repeat (20) @(posedge apb_clk);

        apb_read32(12'h008, read_data);
        assert (read_data[2:0] == 3'd4)
            else $fatal(1, "复位后 pixels_per_cycle 错误：%08x", read_data);

        apb_read32(12'h0f8, read_data);
        assert (read_data == 32'h1000_0104)
            else $fatal(1, "核心特性寄存器错误：%08x", read_data);

        apb_write32(12'h030, 32'h0000_0007);
        apb_read32(12'h030, read_data);
        assert (read_data[2:0] == 3'd7)
            else $fatal(1, "APB 写后读回错误：%08x", read_data);
        assert (!apb_slave_error) else $fatal(1, "APB 返回 slave error");

        // 编码器默认关闭，因此输入应通过 192-bit bypass 数据通路。
        repeat (5) @(posedge axi_clk);
        timeout = 0;
        while (!axi_tready_in && timeout < 50) begin
            @(posedge axi_clk);
            timeout++;
        end
        assert (axi_tready_in) else $fatal(1, "bypass 输入未就绪");

        expected_data = 192'h0123456789abcdef_fedcba9876543210_1122334455667788;
        @(negedge axi_clk);
        axi_tdata_in = expected_data;
        axi_tvalid_in = 1'b1;
        @(posedge axi_clk);
        while (!axi_tready_in) @(posedge axi_clk);
        @(negedge axi_clk);
        axi_tvalid_in = 1'b0;
        axi_tdata_in = 192'h0;

        timeout = 0;
        while (!axi_tvalid_out && timeout < 50) begin
            @(posedge axi_clk);
            timeout++;
        end
        assert (axi_tvalid_out) else $fatal(1, "bypass 未产生输出");
        assert (axi_tdata_out == expected_data)
            else $fatal(1, "bypass 数据不匹配：%048x", axi_tdata_out);

        // ready 拉低时，valid 和数据必须保持稳定。
        repeat (3) begin
            @(posedge axi_clk);
            assert (axi_tvalid_out && axi_tdata_out == expected_data)
                else $fatal(1, "backpressure 期间输出未保持");
        end
        @(negedge axi_clk);
        axi_tready_out = 1'b1;
        @(posedge axi_clk);
        @(negedge axi_clk);
        axi_tready_out = 1'b0;

        $display("PASS: reset, APB and 192-bit bypass checks completed");
        $finish;
    end

    initial begin
        #10000 $fatal(1, "测试超时");
    end
endmodule
