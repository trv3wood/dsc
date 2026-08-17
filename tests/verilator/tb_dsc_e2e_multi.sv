// 多 slice / 多分辨率端到端对拍 testbench。
//
// 运行：verilator 构建后 `./obj_dir/Vtb_dsc_e2e_multi +case=<name>`
// 读取 tests/verilator/generated/<name>/ 下由 generate_golden.py 产出的向量
// （无 <name> 时读取 generated/），动态分配输入与期望 payload 数组。
//
// 以 axi_tdata_out（bypass 后 48-bit 原生）与 dsce_slice_mux 原生码流两路
// 逐字节比对 C model payload；多 slice 的交织顺序即 slice_mux 的轮询顺序，
// 若与 C 模型 chunk 交织不一致会在首个失配暴露。
`timescale 1ns/1ps

module tb_dsc_e2e_multi;
    localparam int kSPC = 4;                 // 顶层 pSLICE_PROCESSOR_COUNT
    localparam int kPIXELS_PER_CYCLE = 4;

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
    logic [31:0]  apb_wdata = 32'h0;
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
    logic         axi_tready_out = 1'b1;
    logic         axi_tline_out;
    logic         axi_tframe_out;
    logic [191:0] axi_tdata_out;
    logic [11:0]  bist_sram_in [kSPC*4+1:0];
    logic [11:0]  bist_sram_out [kSPC*4+1:0];

    // 来自 metadata 的参数
    int           width;
    int           height;
    int           slice_width;
    int           slice_height;
    int           slices_per_line;
    int           payload_bytes;
    int           beats;

    // 向量数组按上限静态分配（覆盖至 4K/DCI 4K；5K/8K 不做 RTL 仿真）。
    localparam int kMAX_BEATS   = 2_000_000;
    localparam int kMAX_PAYLOAD = 32_000_000;
    logic [191:0] input_beats [0:kMAX_BEATS-1];
    logic [7:0]   expected_payload [0:kMAX_PAYLOAD-1];
    logic [7:0]   pps [0:127];

    // 计数器/比较
    int  out_count = 0, top_mis = 0, top_excess = 0;
    int  mux_count = 0, mux_mis = 0;
    int  accepted_input = 0;
    int  done_topo = 0, done_mux = 0;

    always begin apb_clk <= ~apb_clk; #10; end
    always begin dsc_clk <= ~dsc_clk; #5;  end   // dsc 域 2x
    always begin axi_clk <= ~axi_clk; #10; end

    dsc_encoder dut (
        .apb_clk(apb_clk), .apb_select(apb_select), .apb_enable(apb_enable),
        .apb_write(apb_write), .apb_strobe(apb_strobe), .apb_protect(apb_protect),
        .apb_addr(apb_addr), .apb_wdata(apb_wdata), .apb_ready(apb_ready),
        .apb_slave_error(apb_slave_error), .apb_int(apb_int), .apb_rdata(apb_rdata),
        .dsc_clk(dsc_clk), .async_reset_n(async_reset_n), .async_test_mode(async_test_mode),
        .axi_clk(axi_clk), .axi_tvalid_in(axi_tvalid_in), .axi_tready_in(axi_tready_in),
        .axi_tline_in(axi_tline_in), .axi_tframe_in(axi_tframe_in), .axi_tdata_in(axi_tdata_in),
        .axi_tvalid_out(axi_tvalid_out), .axi_tready_out(axi_tready_out),
        .axi_tline_out(axi_tline_out), .axi_tframe_out(axi_tframe_out),
        .axi_tdata_out(axi_tdata_out),
        .bist_sram_in(bist_sram_in), .bist_sram_out(bist_sram_out)
    );

    task automatic apb_write32(input logic [11:0] address, input logic [31:0] data);
        @(negedge apb_clk);
        apb_select = 1'b1; apb_enable = 1'b0; apb_write = 1'b1;
        apb_strobe = 4'hf; apb_addr = address; apb_wdata = data;
        @(negedge apb_clk);
        apb_enable = 1'b1;
        do @(posedge apb_clk); while (!apb_ready);
        @(negedge apb_clk);
        apb_select = 1'b0; apb_enable = 1'b0; apb_write = 1'b0; apb_strobe = 4'h0;
    endtask

    task automatic pulse_frame;
        @(negedge axi_clk);
        axi_tframe_in = 1'b1;
        repeat (2) @(negedge axi_clk);
        axi_tframe_in = 1'b0;
    endtask

    always @(posedge axi_clk) begin : SliceDiag
        if (!async_reset_n) begin
            part_valid <= '{default: 0};
            mux_ready  <= '{default: 0};
            last_in    <= '{default: 0};
            select_chg <= 0;
            select_last <= 0;
        end else begin
            for (int g = 0; g < kSPC; g++) begin
                if (dut.dsce_engine_inst.dsce_partition_inst.axi_valid_out[g])
                    part_valid[g]++;
                if (dut.dsce_engine_inst.dsce_slice_mux_inst.axi_tready_in[g])
                    mux_ready[g]++;
                if (dut.dsce_engine_inst.i_axi_last[g])
                    last_in[g]++;
            end
            if (dut.dsce_engine_inst.dsce_slice_mux_inst.i_slice_select != select_last) begin
                select_chg <= select_chg + 1;
                select_last <= dut.dsce_engine_inst.dsce_slice_mux_inst.i_slice_select;
            end
        end
    end
    int part_valid [kSPC];
    int mux_ready  [kSPC];
    int last_in    [kSPC];
    int select_chg = 0;
    int select_last = 0;
    int new_frame_count = 0;

    always @(posedge axi_clk) begin : NewFrameWatch
        if (async_reset_n && dut.axi_new_frame) new_frame_count++;
    end

    int mux_last_ok = 0;
    always @(posedge axi_clk) begin : MuxLastOk
        if (async_reset_n &&
            dut.dsce_engine_inst.dsce_slice_mux_inst.i_valid_in &&
            dut.dsce_engine_inst.dsce_slice_mux_inst.i_ready_in &&
            dut.dsce_engine_inst.dsce_slice_mux_inst.i_last_in)
            mux_last_ok++;
    end

    // AXI 输出（bypass 后，每拍 6 bytes 位于低位 48 bit）逐字节比对。
    always @(posedge axi_clk) begin : TopScoreboard
        if (async_reset_n && axi_tvalid_out && axi_tready_out) begin
            for (int byte_index = 0; byte_index < 6; byte_index++) begin
                if (out_count < payload_bytes) begin
                    if (axi_tdata_out[byte_index*8 +: 8] !== expected_payload[out_count]) begin
                        if (top_mis < 8)
                            $display("TOP_MISMATCH byte=%0d expected=%02x actual=%02x",
                                     out_count, expected_payload[out_count],
                                     axi_tdata_out[byte_index*8 +: 8]);
                        top_mis++;
                    end
                end else begin
                    top_excess++;
                end
                out_count++;
            end
            if (out_count >= payload_bytes) done_topo = 1;
        end
    end

    // slice_mux 原生 48-bit 流逐字节比对。
    always @(posedge axi_clk) begin : MuxScoreboard
        if (async_reset_n && dut.dsce_engine_inst.i_axi_tvalid_mux &&
            dut.dsce_engine_inst.i_axi_tready_mux) begin
            for (int byte_index = 0; byte_index < 6; byte_index++) begin
                if (mux_count < payload_bytes) begin
                    if (dut.dsce_engine_inst.i_axi_tdata_mux[byte_index*8 +: 8] !==
                        expected_payload[mux_count]) begin
                        if (mux_mis < 8)
                            $display("MUX_MISMATCH byte=%0d expected=%02x actual=%02x",
                                     mux_count, expected_payload[mux_count],
                                     dut.dsce_engine_inst.i_axi_tdata_mux[byte_index*8 +: 8]);
                        mux_mis++;
                    end
                end
                mux_count++;
            end
            if (mux_count >= payload_bytes) done_mux = 1;
        end
    end

    always @(posedge axi_clk)
        if (async_reset_n && axi_tvalid_in && axi_tready_in) accepted_input++;

    // 以 <case> 名读取向量文件；空则使用 generated/。
    string  base_path;
    initial begin
        string case_name;
        int    fd;
        base_path = "tests/verilator/generated";
        if ($value$plusargs("case=%s", case_name) && case_name.len() > 0)
            base_path = {base_path, "/", case_name};

        fd = $fopen({base_path, "/metadata.txt"}, "r");
        if (fd == 0) $fatal(1, "无法打开 %s/metadata.txt", base_path);
        void'($fscanf(fd, "width=%d", width));
        void'($fscanf(fd, "height=%d", height));
        void'($fscanf(fd, "slice_width=%d", slice_width));
        void'($fscanf(fd, "slice_height=%d", slice_height));
        void'($fscanf(fd, "slices_per_line=%d", slices_per_line));
        void'($fscanf(fd, "beats=%d", beats));
        void'($fscanf(fd, "payload_bytes=%d", payload_bytes));
        $fclose(fd);

        if (beats > kMAX_BEATS || payload_bytes > kMAX_PAYLOAD)
            $fatal(1, "向量超静态数组上限：beats=%0d payload=%0d", beats, payload_bytes);
        $readmemh({base_path, "/pps.hex"}, pps);
        $readmemh({base_path, "/pixels.hex"}, input_beats);
        $readmemh({base_path, "/expected_payload.hex"}, expected_payload);

        $display("CASE=%0s %0dx%0d slice=%0dx%0d spl=%0d beats=%0d payload=%0dB",
                 case_name.len() ? case_name : "<default>",
                 width, height, slice_width, slice_height, slices_per_line,
                 beats, payload_bytes);
    end

    initial begin : TestSequence
        int beat_index, timeout;
        int nproc, slices_per_proc, chunk_size, total_slices;

        repeat (8) @(posedge apb_clk);
        async_reset_n = 1'b1;
        repeat (20) @(posedge apb_clk);
        for (int index = 0; index < kSPC*4+2; index++)
            bist_sram_in[index] = 12'h000;

        // 依据 slice 划分计算配置值
        nproc = (slices_per_line < kSPC) ? slices_per_line : kSPC;
        total_slices = slices_per_line * (height / slice_height);
        slices_per_proc = total_slices / nproc;
        chunk_size = slice_width * 12 / 8;

        apb_write32(12'h008, 32'd4);              // pixels per cycle
        apb_write32(12'h030, 32'd4);              // output mode（48-bit 原生）
        apb_write32(12'h040, 32'd7);              // slice width alignment
        apb_write32(12'h044, slices_per_line);    // slices per line
        apb_write32(12'h048, slices_per_proc);    // slices per processor
        apb_write32(12'h04c, nproc);              // slice processor count
        apb_write32(12'h050, 32'd0);
        apb_write32(12'h060, 32'd36);             // max bits per group
        apb_write32(12'h064, 32'd0);              // trailing bits flag
        apb_write32(12'h068, chunk_size);         // chunk size

        // PPS RAM 写入与 commit
        apb_write32(12'h104, 32'd0);
        repeat (2) @(posedge apb_clk);
        for (int index = 0; index < 128; index++)
            apb_write32(12'h100, pps[index]);
        repeat (2) @(posedge apb_clk);
        apb_write32(12'h108, 32'd1);

        pulse_frame();
        repeat (180) @(posedge axi_clk);
        assert (dut.cfg_pps.pic_width == width)
            else $fatal(1, "PPS pic_width=%0d expected %0d",
                        dut.cfg_pps.pic_width, width);
        assert (dut.cfg_pps.pic_height == height)
            else $fatal(1, "PPS pic_height=%0d expected %0d",
                        dut.cfg_pps.pic_height, height);
        assert (dut.cfg_pps.dsc_version_major == 4'd1 &&
                dut.cfg_pps.dsc_version_minor == 4'd2)
            else $fatal(1, "PPS DSC 版本 %0d.%0d 异常",
                        dut.cfg_pps.dsc_version_major, dut.cfg_pps.dsc_version_minor);

        // force_enable + 连续运行
        apb_write32(12'h024, 32'd1);              // force enable
        apb_write32(12'h000, 32'd4);              // start encoder
        timeout = 0;
        while (!dut.axi_encoder_enable && timeout < 200) begin
            @(posedge axi_clk);
            timeout++;
        end
        assert (dut.axi_encoder_enable) else $fatal(1, "编码器未启动");

        // 逐行送入像素；partition 对多 slice 轮换分配，tready 为全体 backpressure。
        beat_index = 0;
        for (int line = 0; line < height; line++) begin
            @(negedge axi_clk);
            axi_tline_in = 1'b1;
            axi_tvalid_in = 1'b0;
            @(negedge axi_clk);
            axi_tline_in = 1'b0;

            for (int column_beat = 0; column_beat < width/4; column_beat++) begin
                axi_tdata_in = input_beats[beat_index];
                axi_tvalid_in = 1'b1;
                do @(posedge axi_clk); while (!axi_tready_in);
                @(negedge axi_clk);
                beat_index++;
            end
            axi_tvalid_in = 1'b0;
            axi_tdata_in = 192'h0;

            // 单 slice 下等待本行 slice buffer 读完，避免下一行复用写地址覆盖未编码数据。
// 多 slice 由 partition 的 tready backpressure 自然流控，不做此等待。
            if (slices_per_line == 1) begin
                timeout = 0;
                while (!(dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_valid_slb &&
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_last_slb) &&
                       timeout < 20000) begin
                    @(posedge dsc_clk);
                    timeout++;
                end
                assert (timeout < 20000) else $fatal(1, "slice buffer 行读取超时：line=%0d", line);
            end
        end

        // 等待两路输出完成
        timeout = 0;
        while ((!done_topo || !done_mux || mux_count < payload_bytes) &&
               timeout < 2000000) begin
            @(posedge axi_clk);
            timeout++;
        end

        $display("RESULT accepted=%0d out=%0d top_mis=%0d top_excess=%0d mux=%0d mux_mis=%0d",
                 accepted_input, out_count, top_mis, top_excess, mux_count, mux_mis);
        $display("DIAG partition_v=%0d/%0d/%0d/%0d mux_ready=%0d/%0d/%0d/%0d last_in=%0d/%0d/%0d/%0d select_chg=%0d new_frame=%0d",
                 part_valid[0], part_valid[1], part_valid[2], part_valid[3],
                 mux_ready[0], mux_ready[1], mux_ready[2], mux_ready[3],
                 last_in[0], last_in[1], last_in[2], last_in[3],
                 select_chg, new_frame_count, mux_last_ok);
        $display("CFG spl=%0d spo=%0d spc=%0d chunk=%0d",
                 dut.cfg_dsc_encoder.slices_per_line,
                 dut.cfg_dsc_encoder.slices_per_processor,
                 dut.cfg_dsc_encoder.slice_processor_count,
                 dut.cfg_pps.chunk_size);
        if (mux_mis != 0 || top_mis != 0 || out_count != payload_bytes ||
            top_excess != 0 || mux_count != payload_bytes)
            $fatal(1, "端到端 payload 不匹配");
        $display("PASS: RTL payload matches C model (%0d bytes, %0d slices/frame)",
                 out_count, total_slices);
        $finish;
    end

    initial begin
        #200000000 $fatal(1, "全局测试超时");
    end

    initial begin
        $dumpfile("/tmp/dsc_tb_multi.vcd");
        $dumpvars(0, tb_dsc_e2e_multi);
    end
endmodule : tb_dsc_e2e_multi
