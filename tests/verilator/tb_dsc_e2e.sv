`timescale 1ns/1ps

module tb_dsc_e2e;
    localparam int kSPC = 1;
    localparam int kWIDTH = 96;
    localparam int kHEIGHT = 108;
    localparam int kINPUT_BEATS = kWIDTH * kHEIGHT / 4;
    localparam int kPAYLOAD_BYTES = kWIDTH * kHEIGHT * 12 / 8;

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

    logic [7:0]   pps [0:127];
    logic [191:0] input_beats [0:kINPUT_BEATS-1];
    logic [7:0]   expected_payload [0:kPAYLOAD_BYTES-1];
    int           output_count = 0;
    int           mismatch_count = 0;
    int           mux_output_count = 0;
    int           mux_mismatch_count = 0;
    int           mux_valid_count = 0;
    int           excess_output_count = 0;
    int           accepted_input_count = 0;
    int           partition_valid_count = 0;
    int           csc_valid_count = 0;
    int           slice_group_count = 0;
    int           flatness_valid_count = 0;
    int           predict_valid_count = 0;
    int           muxword_count = 0;
    int           write_ready_count = 0;
    int           dsc_write_ready_count = 0;
    int           dsc_pps_update_count = 0;

    always #5 apb_clk = ~apb_clk;
    always #4 axi_clk = ~axi_clk;
    always #3 dsc_clk = ~dsc_clk;

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

    task automatic pulse_frame;
        @(negedge axi_clk);
        axi_tframe_in = 1'b1;
        repeat (2) @(negedge axi_clk);
        axi_tframe_in = 1'b0;
    endtask

    // 8bpc 编码核心原生生成 48-bit muxword，首次对拍避免跨字宽重打包。
    always @(posedge axi_clk) begin : Scoreboard
        if (async_reset_n && axi_tvalid_out && axi_tready_out) begin
            if (output_count < 24)
                $display("TOP[%0d]=%012x", output_count/6, axi_tdata_out[47:0]);
            for (int byte_index = 0; byte_index < 6; byte_index++) begin
                if (output_count < kPAYLOAD_BYTES) begin
                    if (axi_tdata_out[byte_index*8 +: 8] !== expected_payload[output_count]) begin
                        if (mismatch_count < 8)
                            $display("MISMATCH byte=%0d expected=%02x actual=%02x word=%048x",
                                     output_count, expected_payload[output_count],
                                     axi_tdata_out[byte_index*8 +: 8], axi_tdata_out);
                        mismatch_count++;
                    end
                end else begin
                    excess_output_count++;
                end
                output_count++;
            end
        end
    end

    // bypass 前的 slice mux 是编码器原生 48-bit 码字流，用它区分编码错误和输出重打包错误。
    always @(posedge axi_clk) begin : MuxScoreboard
        if (async_reset_n && dut.dsce_engine_inst.i_axi_tvalid_mux) begin
            if (mux_valid_count < 12)
                $display("MUX_VALID[%0d] ready=%0b data=%012x bypass_ready=%b",
                         mux_valid_count, dut.dsce_engine_inst.i_axi_tready_mux,
                         dut.dsce_engine_inst.i_axi_tdata_mux[47:0],
                         dut.dsce_engine_inst.dsce_bypass_inst.i_tready_in);
            mux_valid_count++;
        end
        if (async_reset_n && dut.dsce_engine_inst.i_axi_tvalid_mux &&
            dut.dsce_engine_inst.i_axi_tready_mux) begin
            if (mux_output_count < 24)
                $display("MUX[%0d]=%012x", mux_output_count/6,
                         dut.dsce_engine_inst.i_axi_tdata_mux[47:0]);
            for (int byte_index = 0; byte_index < 6; byte_index++) begin
                if (mux_output_count < kPAYLOAD_BYTES &&
                    dut.dsce_engine_inst.i_axi_tdata_mux[byte_index*8 +: 8] !==
                    expected_payload[mux_output_count]) begin
                    if (mux_mismatch_count < 8)
                        $display("MUX_MISMATCH byte=%0d expected=%02x actual=%02x",
                                 mux_output_count, expected_payload[mux_output_count],
                                 dut.dsce_engine_inst.i_axi_tdata_mux[byte_index*8 +: 8]);
                    mux_mismatch_count++;
                end
                mux_output_count++;
            end
        end
    end

    always @(posedge axi_clk) begin : AXIStageCounters
        if (axi_tvalid_in && axi_tready_in)
            accepted_input_count++;
        if (dut.dsce_engine_inst.i_valid_part[0])
            partition_valid_count++;
        if (dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_valid_csc)
            csc_valid_count++;
        if (dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_slice_buffer_inst.i_axi_write_ready)
            write_ready_count++;
    end

    always @(posedge dsc_clk) begin : DSCStageCounters
        if (dut.dsc_pps_update)
            dsc_pps_update_count++;
        if (dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_slice_buffer_inst.i_dsc_write_ready)
            dsc_write_ready_count++;
        if (dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_valid_slb)
            slice_group_count++;
        if (dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_valid_fd)
            flatness_valid_count++;
        if (dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_valid_pd)
            predict_valid_count++;
        if (dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.i_muxword_valid_sb)
            muxword_count++;
    end

    initial begin : TestSequence
        int beat_index;
        int timeout;

        $readmemh("tests/verilator/generated/pps.hex", pps);
        $readmemh("tests/verilator/generated/pixels.hex", input_beats);
        $readmemh("tests/verilator/generated/expected_payload.hex", expected_payload);
        for (int index = 0; index < kSPC*4+2; index++)
            bist_sram_in[index] = 12'h000;

        repeat (8) @(posedge apb_clk);
        async_reset_n = 1'b1;
        repeat (20) @(posedge apb_clk);

        // 配置单 slice processor、4 pixel/cycle 和原生 48-bit 输出。
        apb_write32(12'h008, 32'd4);
        apb_write32(12'h030, 32'd4);
        apb_write32(12'h044, 32'd1);
        apb_write32(12'h048, 32'd1);
        apb_write32(12'h04c, 32'd1);
        apb_write32(12'h050, 32'd0);
        apb_write32(12'h060, 32'd48);
        apb_write32(12'h064, 32'd0);
        apb_write32(12'h068, 32'd144);

        // PPS RAM 初始写 bank 0，commit 后交给 AXI 域读取。
        apb_write32(12'h104, 32'd0);
        for (int index = 0; index < 128; index++)
            apb_write32(12'h100, pps[index]);
        apb_write32(12'h108, 32'd1);

        // frame 边沿触发 PPS 从 SRAM 传输到编码域。
        pulse_frame();
        repeat (180) @(posedge axi_clk);
        assert (dut.cfg_pps.pic_width == kWIDTH)
            else $fatal(1, "PPS pic_width 未加载：%0d", dut.cfg_pps.pic_width);
        assert (dut.cfg_pps.pic_height == kHEIGHT)
            else $fatal(1, "PPS pic_height 未加载：%0d", dut.cfg_pps.pic_height);
        assert (dut.cfg_pps.chunk_size == 16'd144)
            else $fatal(1, "PPS chunk_size 未加载：%0d", dut.cfg_pps.chunk_size);

        // force_enable 避免依赖外部持续 VSYNC，再启动连续运行模式。
        apb_write32(12'h024, 32'd1);
        apb_write32(12'h000, 32'd4);
        timeout = 0;
        while (!dut.axi_encoder_enable && timeout < 200) begin
            @(posedge axi_clk);
            timeout++;
        end
        assert (dut.axi_encoder_enable) else $fatal(1, "编码器未启动");

        beat_index = 0;
        for (int line = 0; line < kHEIGHT; line++) begin
            // tline 是独立的行起始指示周期，RTL 在该周期清零 pack 状态。
            @(negedge axi_clk);
            axi_tline_in = 1'b1;
            axi_tvalid_in = 1'b0;
            @(negedge axi_clk);
            axi_tline_in = 1'b0;

            for (int column_beat = 0; column_beat < kWIDTH/4; column_beat++) begin
                axi_tdata_in = input_beats[beat_index];
                axi_tvalid_in = 1'b1;
                do @(posedge axi_clk); while (!axi_tready_in);
                @(negedge axi_clk);
                beat_index++;
            end
            axi_tvalid_in = 1'b0;
            axi_tdata_in = 192'h0;
        end

        timeout = 0;
        while (mux_output_count < kPAYLOAD_BYTES && timeout < 200000) begin
            @(posedge axi_clk);
            timeout++;
        end
        if (mux_output_count < kPAYLOAD_BYTES) begin
            $display("PIPELINE input=%0d partition=%0d csc=%0d groups=%0d flat=%0d predict=%0d muxwords=%0d",
                     accepted_input_count, partition_valid_count, csc_valid_count,
                     slice_group_count, flatness_valid_count, predict_valid_count, muxword_count);
            $display("CDC write_ready_cycles=%0d dsc_ready_cycles=%0d pps_update_cycles=%0d",
                     write_ready_count, dsc_write_ready_count, dsc_pps_update_count);
            $display("STATE axi_enable=%0b dsc_enable=%0b overflow=%0b slb_waddr=%0d slb_raddr=%0d read_state=%0d pipe_state=%0d width=%0d height=%0d fmt_waddr=%0d fmt_raddr=%0d",
                     dut.axi_encoder_enable, dut.dsc_encoder_enable,
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_slice_buffer_overflow,
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_slice_buffer_inst.i_axi_waddr,
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_slice_buffer_inst.i_dsc_raddr,
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_slice_buffer_inst.i_read_state,
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_slice_buffer_inst.i_pipeline_state,
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_slice_buffer_inst.i_dsc_slice_width,
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_slice_buffer_inst.i_dsc_slice_height,
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_dsc_waddr,
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_axi_raddr);
            $fatal(1, "输出超时：mux_got=%0d expected=%0d", mux_output_count, kPAYLOAD_BYTES);
        end
        repeat (20) @(posedge axi_clk);
        $display("RESULT mux_bytes=%0d mux_mismatches=%0d top_bytes=%0d top_mismatches=%0d excess=%0d",
                 mux_output_count, mux_mismatch_count, output_count, mismatch_count,
                 excess_output_count);
        if (mux_mismatch_count != 0 || mismatch_count != 0 ||
            output_count != kPAYLOAD_BYTES || excess_output_count != 0)
            $fatal(1, "端到端 payload 不匹配");

        $display("PASS: RTL payload matches C model (%0d bytes)", output_count);
        $finish;
    end

    initial begin
        #5000000 $fatal(1, "全局测试超时");
    end
endmodule
