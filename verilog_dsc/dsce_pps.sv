// ------------------------------------------------------------------------------------------------
//     COPYRIGHT © 2015-2021, TRILINEAR TECHNOLOGIES, INC.
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
//     DESCRIPTION : Picture parameter set management using the APB host interface.
// ------------------------------------------------------------------------------------------------

// ----------------------------------------------
//  includes
// ----------------------------------------------
import dsce_defs_pkg::*;


// ----------------------------------------------
//  module declaration
// ----------------------------------------------
module dsce_pps
(
    // apb clock domain
    input  logic        apb_clk,                        // APB bus clock
    input  logic        apb_reset_n,                    // domain reset

    // read/write interface from the APB host
    input  logic        apb_pps_write,                  // write to the PPS SRAM
    input  logic [6:0]  apb_pps_index,                  // SRAM write index
    input  logic [7:0]  apb_pps_wdata,                  // SRAM write data
    input  logic        apb_pps_commit,                 // commit changes
    output logic [7:0]  apb_pps_rdata,                  // SRAM read data

    // encode engine interface
    input  logic        axi_clk,                        // AXI bus clock
    input  logic        axi_reset_n,                    // engine reset
    input  logic        axi_pps_refresh,                // refresh toggle flag
    output logic        axi_pps_refresh_complete,       // refresh complete handshake
    output tDSC_PPS     cfg_pps,                        // parameter set output array
    output tDSC_RCPS    cfg_rcps,                       // rate control parameter set

    // BIST interface
    input  logic [11:0] bist_sram_in [1:0],             // bist vector input
    output logic [11:0] bist_sram_out [1:0]             // bist vector output
);
    // ------------------------------------------------------------------------------------------------------------
    //                                          internal definitions
    // ------------------------------------------------------------------------------------------------------------

    // copy SRAM to PPS logic
    enum {
        pDTS_IDLE,
        pDTS_TRANSFER,
        pDTS_COMPLETE
    } i_transfer_state;

    logic [7:0]         i_transfer_addr;
    logic               i_transfer_enable;
    logic               i_update_pps;
    logic [6:0]         i_update_addr;
    logic [7:0]         i_update_rdata;
    logic [1:0]         i_sync_commit;

    logic [127:0][7:0]   i_pps;

    // APB path to SRAM buffers
    logic [7:0]         i_apb_addr;
    logic               i_write_enable;
    logic [7:0]         i_write_data;
    logic [7:0]         i_read_data;
    logic               i_read_enable;
    logic               i_commit_toggle;

    int gx;

    // ------------------------------------------------------------------------------------------------------------
    //                                          process assignments
    // ------------------------------------------------------------------------------------------------------------

    // --------------------------------------------------------------------------
    //  signal mapping
    // --------------------------------------------------------------------------
    always_comb begin : SigMap
        // picture parameter set map (byte swap for intel byte ordering)
        cfg_pps.dsc_version_major = i_pps[0][7:4];
        cfg_pps.dsc_version_minor = i_pps[0][3:0];
        cfg_pps.pps_identifier = i_pps[1];
        cfg_pps.bits_per_component = i_pps[3][7:4];
        cfg_pps.linebuf_depth = i_pps[3][3:0];
        cfg_pps.block_pred_enable = i_pps[4][5];
        cfg_pps.convert_rgb = i_pps[4][4];
        cfg_pps.simple_422 = i_pps[4][3];
        cfg_pps.vbr_enable = i_pps[4][2];
        cfg_pps.bits_per_pixel = {i_pps[4][1:0], i_pps[5][7:0]};
        cfg_pps.pic_height = {i_pps[6], i_pps[7]};
        cfg_pps.pic_width = {i_pps[8], i_pps[9]};
        cfg_pps.slice_height = {i_pps[10], i_pps[11]};
        cfg_pps.slice_width = {i_pps[12], i_pps[13]};
        cfg_pps.chunk_size = {i_pps[14], i_pps[15]};
        cfg_pps.initial_xmit_delay = {i_pps[16][1:0], i_pps[17][7:0]};
        cfg_pps.initial_dec_delay = {i_pps[18], i_pps[19]};
        cfg_pps.initial_scale_value = i_pps[21][5:0];
        cfg_pps.scale_increment_interval = {i_pps[22], i_pps[23]};
        cfg_pps.scale_decrement_interval = {i_pps[24][3:0], i_pps[25][7:0]};
        cfg_pps.first_line_bpg_offset = i_pps[27][4:0];
        cfg_pps.nfl_bpg_offset = {i_pps[28], i_pps[29]};
        cfg_pps.slice_bpg_offset = {i_pps[30], i_pps[31]};
        cfg_pps.initial_offset = {i_pps[32], i_pps[33]};
        cfg_pps.final_offset = {i_pps[34], i_pps[35]};
        cfg_pps.flatness_min_qp = i_pps[36][4:0];
        cfg_pps.flatness_max_qp = i_pps[37][4:0];
        cfg_pps.native_420 = i_pps[88][1];
        cfg_pps.native_422 = i_pps[88][0];
        cfg_pps.second_line_bpg_offset = i_pps[89][4:0];
        cfg_pps.nsl_bpg_offset = {i_pps[90], i_pps[91]};
        cfg_pps.second_line_offset_adj = {i_pps[92], i_pps[93]};

        // rate control parameter set
        cfg_rcps.rc_model_size = {i_pps[38], i_pps[39]};
        cfg_rcps.rc_edge_factor = i_pps[40][3:0];
        cfg_rcps.rc_quant_incr_limit0 = i_pps[41][4:0];
        cfg_rcps.rc_quant_incr_limit1 = i_pps[42][4:0];
        cfg_rcps.rc_tgt_offset_hi = i_pps[43][7:4];
        cfg_rcps.rc_tgt_offset_lo = i_pps[43][3:0];
        cfg_rcps.rc_buf_thresh = i_pps[57:44];

        // tie offs
        cfg_rcps.rc_reserved_0 = 4'h0;
        cfg_rcps.rc_reserved_1 = 3'h0;
        cfg_rcps.rc_reserved_2 = 3'h0;

        // unrolled loop since verilog is incapable of understanding constant range expressions with a loop variable
        for (gx = 0; gx < 15; gx++) cfg_rcps.rc_range_parameters[gx] = {i_pps[58+gx*2], i_pps[59+gx*2]};
    end : SigMap


    // --------------------------------------------------------------------------
    //  input controller
    // --------------------------------------------------------------------------
    always_ff@(posedge apb_clk or negedge apb_reset_n) begin : PPSInterface
        if (apb_reset_n == 1'b0) begin
            apb_pps_rdata <= 8'h00;

            i_apb_addr <= 8'h00;
            i_write_enable <= 1'b0;
            i_write_data <= 8'h00;
            i_commit_toggle <= 1'b0;
            i_read_enable <= 1'b0;

        end else begin

            // local buffers for the write path
            i_apb_addr[6:0] <= apb_pps_index;
            i_read_enable <= !apb_pps_write;

            if (apb_pps_write == 1'b1) begin
                i_write_enable <= 1'b1;
                i_write_data <= apb_pps_wdata;
            end else begin
                i_write_enable <= 1'b0;
            end // if

            // local buffer for the read path
            apb_pps_rdata <= i_read_data;

            // toggle commit to the AXI side
            if (apb_pps_commit == 1'b1) begin
                i_apb_addr[7] <= ~i_apb_addr[7];
                i_commit_toggle <= ~i_commit_toggle;
            end // if

        end // if
    end : PPSInterface

    // --------------------------------------------------------------------------
    //  parameter set update controller
    // --------------------------------------------------------------------------
    always_ff@(posedge axi_clk or negedge axi_reset_n) begin : PPSUpdate
        if (axi_reset_n == 1'b0) begin
            axi_pps_refresh_complete <= 1'b0;

            i_transfer_state <= pDTS_IDLE;
            i_transfer_addr <= 8'h80;
            i_transfer_enable <= 1'b0;
            i_update_addr <= 7'h00;
            i_update_pps <= 1'b0;
            i_pps <= '{default: 8'h00};

        end else begin

            // ---------------------------------------------------
            //  current PPS tracking
            // ---------------------------------------------------
            if (i_sync_commit[1] != i_sync_commit[0]) begin
                i_transfer_addr[7] <= ~i_transfer_addr[7];
            end // if

            // ---------------------------------------------------
            //  PPS transfer state machine
            // ---------------------------------------------------
            // default states
            axi_pps_refresh_complete <= 1'b0;
            i_transfer_enable <= 1'b0;

            // accept the flag for updates
            if (axi_pps_refresh == 1'b1) begin
                i_transfer_state <= pDTS_TRANSFER;
                i_transfer_addr[6:0] <= 7'h00;
                i_transfer_enable <= 1'b1;
            end else begin
                case (i_transfer_state)
                    // idle state when waiting for update request
                    pDTS_IDLE:  begin
                        i_transfer_state <= pDTS_IDLE;
                        i_transfer_addr[6:0] <= 7'h00;
                    end // pDTS_IDLE

                    // transfer state
                    pDTS_TRANSFER:  begin
                        if (i_transfer_addr[6:0] == 7'd88)  begin
                            i_transfer_state <= pDTS_COMPLETE;
                            i_transfer_enable <= 1'b0;
                        end else begin
                            i_transfer_enable <= 1'b1;
                        end // if

                        i_transfer_addr[6:0] <= i_transfer_addr[6:0] + 7'd1;
                    end // pDTS_TRANSFER

                    // set the complete flag
                    pDTS_COMPLETE:  begin
                        axi_pps_refresh_complete <= 1'b1;
                        i_transfer_state <= pDTS_IDLE;
                    end // pDTS_COMPLETE

                    // for synthesis only
                    default:  begin
                        i_transfer_state <= pDTS_IDLE;
                        i_transfer_addr[6:0] <= 7'h00;
                    end // default
                endcase
            end // if

            // ---------------------------------------------------
            //  PPS capture logic
            // ---------------------------------------------------
            i_update_pps <= i_transfer_enable;
            i_update_addr <= i_transfer_addr[6:0];
            if (i_update_pps == 1'b1) begin
                i_pps[i_update_addr] <= i_update_rdata;
            end // if

        end // if
    end : PPSUpdate

    // --------------------------------------------------------------------------
    //  PPS SRAM
    // --------------------------------------------------------------------------
    gram_bist_1r1w
    # (
        .pRW_CHECK     (1),
        .pADDRESS_BITS (8),
        .pDATA_BITS    (8)
    ) pps_host_sram_inst
    (
        // port a, read port
        .clk_r    (apb_clk),
        .en_r     (i_read_enable),
        .addr_r   (i_apb_addr),
        .data_r   (i_read_data),
        // port b, write port
        .clk_w    (apb_clk),
        .addr_w   (i_apb_addr),
        .we_w     (i_write_enable),
        .data_w   (i_write_data),
        // bist interface
        .bist_in  (bist_sram_in[1]),
        .bist_out (bist_sram_out[1])
    );

    gram_bist_1r1w
    # (
        .pRW_CHECK     (1),
        .pADDRESS_BITS (8),
        .pDATA_BITS    (8)
    ) pps_engine_sram_inst
    (
        // port a, read port
        .clk_r    (axi_clk),
        .en_r     (i_transfer_enable),
        .addr_r   (i_transfer_addr),
        .data_r   (i_update_rdata),
        // port b, write port
        .clk_w    (apb_clk),
        .addr_w   (i_apb_addr),
        .we_w     (i_write_enable),
        .data_w   (i_write_data),
        // bist interface
        .bist_in  (bist_sram_in[0]),
        .bist_out (bist_sram_out[0])
    );

    // --------------------------------------------------------------------------
    //  sync stages
    // --------------------------------------------------------------------------
    gprim_sync2_stage  sync_update_inst (.sync_clk (axi_clk), .reset_n (axi_reset_n), .async_in(i_commit_toggle), .sync_out(i_sync_commit));

endmodule : dsce_pps

