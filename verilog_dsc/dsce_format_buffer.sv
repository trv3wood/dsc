// ------------------------------------------------------------------------------------------------
//     COPYRIGHT © 2015-2022, TRILINEAR TECHNOLOGIES, INC.
//     CONFIDENTIAL AND PROPRIETARY
//
//     THE SOURCE CODE CONTAINED HEREIN IS PROVIDED ON AN "AS IS" BASIS.
//     TRILINEAR TECHNOLOGIES, INC. DISCLAIMS ANY AND ALL WARRANTIES,
//     WHETHER EXPRESS, IMPLIED, OR STATUTORY, INCLUDING ANY IMPLIED
//     WARRANTIES OF MERCHANTABILITY OR OF FITNESS FOR A PARTICULAR PURPOSE.
//     IN NO EVENT SHALL TRILINEAR TECHNOLOGIES, INC. BE LIABLE FOR ANY
//     INCIDENTAL, PUNITIVE, OR CONSEQUENTIAL DAMAGES OF ANY KIND WHATSOEVER
//     ARISING FROM THE USE OF THIS SOURCE CODE.
//
//     THIS DISCLAIMER OF WARRANTY EXTENDS TO THE USER OF THIS SOURCE CODE
//     AND USER'S CUSTOMERS, EMPLOYEES, AGENTS, TRANSFEREES, SUCCESSORS,
//     AND ASSIGNS.
//
//     THIS IS NOT A GRANT OF PATENT RIGHTS
// ------------------------------------------------------------------------------------------------
//     DESCRIPTION : DSC encoder output format buffer and flow control.
// ------------------------------------------------------------------------------------------------

// ----------------------------------------------
//  includes
// ----------------------------------------------
import dsce_defs_pkg::*;


// ----------------------------------------------
//  entity declaration
// ----------------------------------------------
module dsce_format_buffer
(
    // clock and control interface
    input  logic                    dsc_clk,                // DSC processing clock
    input  logic                    dsc_reset_n,            // DSC domain reset
    input  logic                    dsc_pps_update,         // update pps parameters flag
    input  tDSC_PPS                 cfg_pps,                // parameter set output array
    input  tDSCE_CONFIG             cfg_dsc_encoder,        // encoder configuration

    // input path from muxword builder
    input  logic                    dsc_start_of_frame,     // start of frame flag
    input  logic                    dsc_start_of_slice,     // start of slice flag
    input  logic                    dsc_muxword_valid_in,   // MUX word valid from stream builder
    input  logic [63:0]             dsc_muxword_in,         // MUX word input

    // output to the slice mux
    input  logic                    axi_clk,                // AXI domain clock
    input  logic                    axi_reset_n,            // AXI domain reset
    output logic                    axi_last_out,           // last data output flag
    output logic                    axi_tvalid_out,         // data ready flag output
    input  logic                    axi_tready_out,         // data accept ready from the slice mux
    output logic [63:0]             axi_muxword_out,        // mux word for inclusion in the slice stream

    // memory BIST interface
    input  logic [11:0]             bist_sram_in,           // BIST input, 1 SRAM
    output logic [11:0]             bist_sram_out           // BIST output, 1 SRAM
);

    // ------------------------------------------------------------------------------------------------------------
    //                                          internal definitions
    // ------------------------------------------------------------------------------------------------------------

    // ----- local settings ----- //
    logic [3:0]                     i_bits_per_component;

    // ----- fifo write management ----- //
    logic [7:0]                     i_dsc_waddr, i_dsc_waddr_gc;
    logic                           i_dsc_fifo_we;
    logic [63:0]                    i_dsc_fifo_wdata;
    logic                           i_dsc_frame_toggle;
    logic [15:0]                    i_dsc_write_count;
    logic [15:0]                    i_dsc_target_words;

    // ----- fifo read management ----- //
    enum {  kRS_XMIT_DELAY,
            kRS_DATA_INIT,
            kRS_DATA_READY,
            kRS_DATA_LAST,
            kRS_DATA_PAD
    } i_read_state;

    logic [7:0]                     i_axi_raddr, i_axi_waddr, i_axi_waddr_gc, i_axi_raddr_p1;
    logic [63:0]                    i_axi_muxword;
    logic                           i_axi_ren;
    logic                           i_axi_read_init;
    logic [1:0]                     i_axi_frame_toggle;
    logic                           i_axi_start_of_frame;
    logic [15:0]                    i_axi_write_count;
    logic [15:0]                    i_axi_target_words;
    logic [15:0]                    i_axi_out_count;
    logic [15:0]                    i_axi_write_count_prev;
    logic [6:0]                     i_axi_write_stable;
    logic                           i_axi_write_idle;

    // ----- initial delay counters ----- //
    logic [9:0]                     i_initial_xmit_delay;
    logic [9:0]                     i_xmit_delay_counter;
    logic                           i_dsc_xmit_okay;
    logic                           i_axi_xmit_okay;

    // ----- multi-slice chunk interleave ----- //
    // 每输出一个 chunk（=该 slice 每行的字数）后打 last 交回 slice_mux 轮询；
    // 仅当 slices_per_line>1 时启用，单 slice 路径与原实现完全一致。
    logic [15:0]                    i_axi_slice_height;
    logic [15:0]                    i_axi_chunk_words;
    logic                           i_axi_chunk_boundary;
    logic                           i_axi_multi_slice;
    logic                           i_axi_pause_chunk;


    // --------------------------------------------------------------------------
    //  binary to gray code converter
    // --------------------------------------------------------------------------
    function automatic logic [7:0] dsce_binary_to_gray_code_8 (
        input logic [7:0] a
    );
        dsce_binary_to_gray_code_8 = (a >> 1) ^ a;
    endfunction : dsce_binary_to_gray_code_8


    // --------------------------------------------------------------------------
    //  gray code to binary converter
    // --------------------------------------------------------------------------
    function automatic logic [7:0] dsce_gray_code_to_binary_8 (
        input logic [7:0] a
    );
        for (int xx = 0; xx < 8; xx++)  dsce_gray_code_to_binary_8[xx] = ^(a >> xx);
    endfunction : dsce_gray_code_to_binary_8


    // ------------------------------------------------------------------------------------------------------------
    //                                             processes
    // ------------------------------------------------------------------------------------------------------------

    // signal assignments
    always_comb begin : SignalMap
        // 零填充阶段直接输出全零 muxword，不读取 RAM。
        axi_muxword_out = (i_read_state == kRS_DATA_PAD) ? 64'd0 : i_axi_muxword;

        i_axi_waddr = dsce_gray_code_to_binary_8(i_axi_waddr_gc);
        i_axi_ren = (i_axi_read_init == 1'b1 || (axi_tvalid_out == 1'b1 && axi_tready_out == 1'b1 && i_read_state == kRS_DATA_READY)) ? 1'b1 : 1'b0;
        i_axi_raddr_p1 = i_axi_raddr + 8'd1;
        i_axi_start_of_frame = (i_axi_frame_toggle[1] != i_axi_frame_toggle[0]) ? 1'b1 : 1'b0;

        // 多 slice：每 chunk 的字数 = target_words / slice_height（每 slice 每行）。
        i_axi_multi_slice = (cfg_dsc_encoder.slices_per_line > 5'd1);
        i_axi_chunk_words = (i_axi_multi_slice && i_axi_slice_height != 16'd0) ?
                            (i_axi_target_words / i_axi_slice_height) : 16'd0;
        i_axi_chunk_boundary = (i_axi_chunk_words != 16'd0 && i_read_state == kRS_DATA_READY) &&
                               ((i_axi_out_count + 16'd1) % i_axi_chunk_words == 16'd0);

        // last 组合输出：仅多 slice 时生效，与 chunk 最后一个数据 word 的传输同拍；
        // slice 数据读尽（kRS_DATA_LAST 握手）同样拉高。单 slice 时恒 0，行为与原始一致。
        axi_last_out = i_axi_multi_slice &&
                       ((i_read_state == kRS_DATA_LAST && axi_tready_out == 1'b1) ||
                        (i_axi_chunk_boundary && i_axi_ren == 1'b1));
    end : SignalMap


    // ------------------------------------------------------
    //   input staging for width selection
    // ------------------------------------------------------
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : InputStaging
        if (dsc_reset_n == 1'b0) begin
            i_initial_xmit_delay <= 10'd0;
            i_bits_per_component <= 4'h0;
            i_xmit_delay_counter <= 10'd0;
            i_dsc_xmit_okay <= 1'b0;
            i_dsc_frame_toggle <= 1'b0;

        end else begin

            // parameter staging
            if (dsc_pps_update == 1'b1) i_initial_xmit_delay <= cfg_pps.initial_xmit_delay;
            if (dsc_pps_update == 1'b1) i_bits_per_component <= cfg_pps.bits_per_component;
            if (dsc_start_of_frame == 1'b1) i_dsc_frame_toggle <= ~i_dsc_frame_toggle;

            if (dsc_pps_update == 1'b1) begin
                i_xmit_delay_counter <= cfg_pps.initial_xmit_delay;
            end else if (i_xmit_delay_counter != 10'd0) begin
                i_xmit_delay_counter <= i_xmit_delay_counter - 10'd1;
            end // if

            if (dsc_start_of_slice == 1'b1) begin
                i_dsc_xmit_okay <= 1'b0;
            end else if (i_xmit_delay_counter == 10'd1) begin
                i_dsc_xmit_okay <= 1'b1;
            end // if

        end // if
    end : InputStaging


    // ------------------------------------------------------
    //   write buffering
    // ------------------------------------------------------
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : WriteManagement
        if (dsc_reset_n == 1'b0) begin
            i_dsc_fifo_we <= 1'b0;
            i_dsc_fifo_wdata <= 64'd0;
            i_dsc_waddr <= 8'h00;
            i_dsc_waddr_gc <= 8'h00;
            i_dsc_write_count <= 16'd0;
            i_dsc_target_words <= 16'd0;

        end else begin

            // write data path
            i_dsc_fifo_we <= dsc_muxword_valid_in;
            i_dsc_fifo_wdata <= (i_bits_per_component < 4'd12) ? {16'h0000, dsc_muxword_in[47:0]} : dsc_muxword_in;

            // 目标总字数 = chunk_size * slice_height 字节换算成 muxword 数
            if (dsc_pps_update == 1'b1) begin
                i_dsc_target_words <= (cfg_pps.chunk_size * cfg_pps.slice_height) /
                                      ((i_bits_per_component < 4'd12) ? 16'd6 : 16'd8);
            end

            // write address tracking
            if (dsc_start_of_frame == 1'b1) begin
                i_dsc_waddr <= '{default: 1'b0};
                i_dsc_write_count <= 16'd0;
            end else if (i_dsc_fifo_we == 1'b1) begin
                i_dsc_waddr <= i_dsc_waddr + 8'd1;
                i_dsc_waddr_gc <= dsce_binary_to_gray_code_8(i_dsc_waddr + 8'd1);
                i_dsc_write_count <= i_dsc_write_count + 16'd1;
            end // if

        end // if
    end : WriteManagement


    // ------------------------------------------------------
    //   AXI reads
    // ------------------------------------------------------
    always_ff@(posedge axi_clk or negedge axi_reset_n) begin : AXIRead
        if (axi_reset_n == 1'b0) begin
            axi_tvalid_out <= 1'b0;

            i_read_state <= kRS_XMIT_DELAY;
            i_axi_read_init <= 1'b0;
            i_axi_raddr <= 8'h00;
            i_axi_out_count <= 16'd0;
            i_axi_pause_chunk <= 1'b0;

        end else begin

            // read data staging
            i_axi_read_init <= 1'b0;

            if (i_axi_start_of_frame == 1'b1) begin
                i_read_state <= kRS_XMIT_DELAY;
                axi_tvalid_out <= 1'b0;
                i_axi_out_count <= 16'd0;
                i_axi_pause_chunk <= 1'b0;
            end else begin
                case (i_read_state)
                    kRS_XMIT_DELAY:  begin
                        axi_tvalid_out <= 1'b0;
                        if (i_axi_raddr != i_axi_waddr) begin
                            i_read_state <= kRS_DATA_INIT;
                            i_axi_read_init <= 1'b1;
                        end else if (i_axi_write_idle == 1'b1 && i_axi_write_count != 16'd0 &&
                                     i_axi_out_count < i_axi_target_words &&
                                     i_axi_pause_chunk == 1'b0) begin
                            // 数据已读尽、编码器已停止写（写计数稳定）且未达到目标长度：零填充。
                            // chunk 边界暂停期间禁止误入 PAD（编码器写下一 chunk 前可能短暂停写）。
                            i_read_state <= kRS_DATA_PAD;
                        end // if
                    end // kRS_XMIT_DELAY

                    kRS_DATA_INIT:  begin
                        axi_tvalid_out <= 1'b1;
                        i_axi_pause_chunk <= 1'b0;   // 已重新获得数据，恢复普通读进
                        if (i_axi_ren == 1'b1 && i_axi_raddr_p1 == i_axi_waddr) begin
                            i_read_state <= kRS_DATA_LAST;
                        end else if (i_axi_ren == 1'b1 && i_axi_chunk_boundary) begin
                            i_axi_pause_chunk <= 1'b1;
                            i_read_state <= kRS_XMIT_DELAY;
                        end else begin
                            i_read_state <= kRS_DATA_READY;
                        end // if
                    end // kRS_DATA_INIT

                    kRS_DATA_READY:  begin
                        axi_tvalid_out <= 1'b1;
                        if (i_axi_ren == 1'b1 && i_axi_raddr_p1 == i_axi_waddr) begin
                            i_read_state <= kRS_DATA_LAST;
                        end else if (i_axi_ren == 1'b1 && i_axi_chunk_boundary) begin
                            i_axi_pause_chunk <= 1'b1;
                            i_read_state <= kRS_XMIT_DELAY;
                        end // if
                    end // kRS_DATA_READY

                    kRS_DATA_LAST:  begin
                        axi_tvalid_out <= 1'b1;
                        if (axi_tready_out == 1'b1) begin
                            axi_tvalid_out <= 1'b0;
                            i_read_state <= kRS_XMIT_DELAY;
                        end // if
                    end // kRS_DATA_LAST

                    kRS_DATA_PAD:  begin
                        axi_tvalid_out <= 1'b1;
                        if (axi_tready_out == 1'b1) begin
                            if (i_axi_out_count + 16'd1 >= i_axi_target_words) begin
                                axi_tvalid_out <= 1'b0;
                                i_read_state <= kRS_XMIT_DELAY;
                            end
                        end // if
                    end // kRS_DATA_PAD

                    default:  begin
                        i_read_state <= kRS_XMIT_DELAY;
                        axi_tvalid_out <= 1'b0;
                        i_axi_read_init <= 1'b0;
                    end // default
                endcase
            end // if


            // read address management
            if (i_axi_start_of_frame == 1'b1) begin
                i_axi_raddr <= '{default: 1'b0};
            end else if (i_axi_ren == 1'b1) begin
                i_axi_raddr <= i_axi_raddr_p1;
            end // if

            // 输出字数统计（数据 + 零填充）
            if (i_axi_start_of_frame == 1'b1) begin
                i_axi_out_count <= 16'd0;
            end else if (axi_tvalid_out == 1'b1 && axi_tready_out == 1'b1) begin
                i_axi_out_count <= i_axi_out_count + 16'd1;
            end // if
        end // if
    end : AXIRead


    // ------------------------------------------------------------------------------------------------------------
    //                                             buffer instance
    // ------------------------------------------------------------------------------------------------------------

    // sync stages
    generate for (genvar wx = 0; wx < 8; wx = wx + 1) begin : gen_waddr
        gprim_sync_stage  sync_waddr_inst (.sync_clk (axi_clk), .reset_n(axi_reset_n), .async_in (i_dsc_waddr_gc[wx]), .sync_out(i_axi_waddr_gc[wx]));
    end endgenerate
    gprim_sync_stage  sync_xmit_inst  (.sync_clk (axi_clk), .reset_n (axi_reset_n), .async_in (i_dsc_xmit_okay), .sync_out(i_axi_xmit_okay));
    gprim_sync2_stage sync_frame_inst (.sync_clk (axi_clk), .reset_n (axi_reset_n), .async_in (i_dsc_frame_toggle), .sync_out(i_axi_frame_toggle));

    // 目标总字数在 pps_update 后静止，跨时钟域同步到 AXI 读域。
    generate for (genvar tw = 0; tw < 16; tw = tw + 1) begin : gen_target
        gprim_sync_stage  sync_target_inst (.sync_clk (axi_clk), .reset_n(axi_reset_n), .async_in (i_dsc_target_words[tw]), .sync_out(i_axi_target_words[tw]));
    end endgenerate
    // 写字数用于判断编码器是否已停止写。
    generate for (genvar wc = 0; wc < 16; wc = wc + 1) begin : gen_wcount
        gprim_sync_stage  sync_wcount_inst (.sync_clk (axi_clk), .reset_n(axi_reset_n), .async_in (i_dsc_write_count[wc]), .sync_out(i_axi_write_count[wc]));
    end endgenerate

    // slice_height 同步到 AXI 读域，用于计算每 chunk 的 muxword 字数。
    generate for (genvar sh = 0; sh < 16; sh = sh + 1) begin : gen_sh
        gprim_sync_stage  sync_sh_inst   (.sync_clk (axi_clk), .reset_n(axi_reset_n), .async_in (cfg_pps.slice_height[sh]), .sync_out(i_axi_slice_height[sh]));
    end endgenerate

    // 检测 AXI 域中写计数是否持续稳定（编码器停止写）。要求连续 64 拍不变，
    // 以避免行切换等短暂停顿误判为编码完成。
    always_ff@(posedge axi_clk or negedge axi_reset_n) begin : WriteIdleDetect
        if (axi_reset_n == 1'b0) begin
            i_axi_write_count_prev <= 16'd0;
            i_axi_write_stable <= 7'd0;
            i_axi_write_idle <= 1'b0;
        end else if (i_axi_start_of_frame == 1'b1) begin
            i_axi_write_count_prev <= 16'd0;
            i_axi_write_stable <= 7'd0;
            i_axi_write_idle <= 1'b0;
        end else begin
            if (i_axi_write_count == i_axi_write_count_prev) begin
                if (i_axi_write_stable != 7'd63)
                    i_axi_write_stable <= i_axi_write_stable + 7'd1;
            end else begin
                i_axi_write_stable <= 7'd0;
            end
            i_axi_write_count_prev <= i_axi_write_count;
            i_axi_write_idle <= (i_axi_write_stable == 7'd63);
        end // if
    end : WriteIdleDetect


    gram_bist_1r1w
    # (
        .pADDRESS_BITS (8),
        .pDATA_BITS    (64)
    ) format_buffer_inst
    (
        // port a, read port
        .clk_r          (axi_clk),
        .en_r           (i_axi_ren),
        .addr_r         (i_axi_raddr),
        .data_r         (i_axi_muxword),
        // port b, write port
        .clk_w          (dsc_clk),
        .addr_w         (i_dsc_waddr),
        .we_w           (i_dsc_fifo_we),
        .data_w         (i_dsc_fifo_wdata),
        // bist interface
        .bist_in        (bist_sram_in),
        .bist_out       (bist_sram_out)
    );

endmodule : dsce_format_buffer

