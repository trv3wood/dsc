// ------------------------------------------------------------------------------------------------
//     COPYRIGHT © 2016-2023, TRILINEAR TECHNOLOGIES, INC.
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
//     DESCRIPTION : Input buffering for the slice processor.  Will hold a segment of the
//                   maximum line size.  The buffer is configured to hold 2 lines
//                   which allows for improved performance at the expense of SRAM area.
// ------------------------------------------------------------------------------------------------

// ----------------------------------------------
//  includes
// ----------------------------------------------
import dsce_defs_pkg::*;


// ----------------------------------------------
//  entity declaration
// ----------------------------------------------
module dsce_slice_buffer
#(
    parameter int           pMAX_SLICE_LINE_SIZE = 4096      // maximum supported line size for this slice processor
)
(
    // clock and control interface
    input  logic                axi_clk,                // AXI input and output clock
    input  logic                axi_reset_n,            // AXI domain reset
    output logic                axi_overflow,           // overflow flag (clear on init)
    input  logic [13:0]         cfg_ready_depth,        // slice buffer ready depth (times 4)
    input  tDSC_PPS             cfg_pps,                // parameter set output array

    // streaming input data path
    input  logic                axi_tvalid_in,          // valid data in
    output logic                axi_tready_in,          // slice buffer ready
    input  logic                axi_tlast_in,           // last pixel
    input  tDSC_PIXEL           axi_tdata_in [3:0],     // streaming input

    // internal data path for encoding
    input  logic                dsc_clk,                // encoding clock
    input  logic                dsc_reset_n,            // encoder domain reset
    input  logic                dsc_pps_update,         // update pps parameters flag

    // output path (not AXI4-S compliant)
    output logic                dsc_start_of_slice,     // start of slice flag
    output logic                dsc_valid_out,          // valid data out
    output logic                dsc_last_out,           // last flag out
    output tDSC_PIXEL           dsc_data_out [2:0],     // group data out

    // memory BIST interface
    input  logic [11:0]         bist_sram_in,           // BIST input, 1 SRAM
    output logic [11:0]         bist_sram_out           // BIST output, 1 SRAM
);

    // ------------------------------------------------------------------------------------------------------------
    //                                          internal definitions
    // ------------------------------------------------------------------------------------------------------------

    localparam pSB_ADDR_BITS = $clog2(pMAX_SLICE_LINE_SIZE);

    // ----- write side signals ----- //
    logic                       i_axi_we;
    logic [pSB_ADDR_BITS-1:0]   i_axi_waddr;
    logic [191:0]               i_axi_wdata;
    logic                       i_axi_wlast;
    logic                       i_axi_write_ready;

    // ----- read side signals ----- //
    logic                       i_dsc_write_ready;
    logic [pSB_ADDR_BITS-1:0]   i_dsc_raddr, i_dsc_raddr_plus_1;
    logic                       i_dsc_ren;
    logic [191:0]               i_rdata;
    tDSC_PIXEL                  i_dsc_rdata [3:0];

    tDSC_PIXEL                  i_pixel_staging [1:0];
    logic [15:0]                i_dsc_slice_width;
    logic [15:0]                i_dsc_slice_height;
    logic                       i_pps_update;
    logic [15:0]                i_read_count, i_read_count_minus_3;
    logic                       i_read_last_word_flag;
    logic [15:0]                i_line_count;
    logic                       i_first_group_of_slice;
    tDSC_PIXEL                  i_midrange_pixel;

    logic [1:0]                 i_read_state;
    tDSC_PIXEL                  i_data_out [2:0];

    enum {
        eDPS_BUFFER_EMPTY,
        eDPS_REFILL_DELAY,
        eDPS_P0,
        eDPS_P1,
        eDPS_P2,
        eDPS_P3
    }                           i_pipeline_state;


    // ------------------------------------------------------------------------------------------------------------
    //                                             processes
    // ------------------------------------------------------------------------------------------------------------

    // signal mapping
    always_comb begin : SignalMap
        // comb signals
        i_dsc_raddr_plus_1 = i_dsc_raddr + kDSCE_ONE[pSB_ADDR_BITS-1:0];
        i_dsc_rdata = '{i_rdata[191:144], i_rdata[143:96], i_rdata[95:48], i_rdata[47:0]};

        // partial read data path
        case (i_read_state)
            2'b00:   i_data_out = i_dsc_rdata[2:0];
            2'b01:   i_data_out = '{i_dsc_rdata[1], i_dsc_rdata[0], i_pixel_staging[0]};
            2'b10:   i_data_out = '{i_dsc_rdata[0], i_pixel_staging[1], i_pixel_staging[0]};
            2'b11:   i_data_out = i_dsc_rdata[3:1];
            default: i_data_out = i_dsc_rdata[2:0];
        endcase

        i_read_count_minus_3 = i_read_count - 16'd3;
        i_read_last_word_flag = (i_read_count[15:2] == 14'd0) ? 1'b1 : 1'b0;
    end : SignalMap


    // --------------------------------------------------------------------------
    //   buffered write process and read output
    // --------------------------------------------------------------------------
    always_ff@(posedge axi_clk or negedge axi_reset_n) begin : WriteManager
        if (axi_reset_n == 1'b0) begin
            axi_overflow <= 1'b0;
            axi_tready_in <= 1'b0;

            i_axi_wdata <= '{default: 1'b0};
            i_axi_waddr <= '{default: 1'b0};
            i_axi_we <= 1'b0;
            i_axi_wlast <= 1'b0;
            i_axi_write_ready <= 1'b0;

        end else begin

            // ready flag input, stall only on error
            axi_tready_in <= ~axi_overflow;

            // local write buffering
            i_axi_we <= axi_tvalid_in;
            i_axi_wdata <= {axi_tdata_in[3], axi_tdata_in[2], axi_tdata_in[1], axi_tdata_in[0]};
            i_axi_wlast <= axi_tlast_in;

            // write address management
            if (i_axi_we == 1'b1) begin
                if (i_axi_wlast == 1'b1) begin
                    i_axi_waddr <= '{default: 1'b0};
                end else begin
                    i_axi_waddr <= i_axi_waddr + kDSCE_ONE[pSB_ADDR_BITS-1:0];
                end // if
            end // if

            // signal to the read side that processing can start
            if (i_axi_we == 1'b1) begin
                if (i_axi_wlast == 1'b1) begin
                    i_axi_write_ready <= 1'b0;
                end else if (i_axi_waddr >= cfg_ready_depth[pSB_ADDR_BITS-1:0]) begin
                    i_axi_write_ready <= 1'b1;
                end // if
            end // if

            // overflow detection
            if (i_axi_we == 1'b1 && i_axi_waddr == kDSCE_MAX_VALUE[pSB_ADDR_BITS-1:0])  begin
                axi_overflow <= 1'b1;
            end // if
        end // if
    end : WriteManager


    // --------------------------------------------------------------------------
    //   slice tracking and group padding
    // --------------------------------------------------------------------------
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : SliceTrack
        if (dsc_reset_n == 1'b0) begin
            i_dsc_slice_width <= 16'd0;
            i_dsc_slice_height <= 16'd0;
            i_pps_update <= 1'b0;
            i_read_count <= 16'd0;
            i_line_count <= 16'd0;
            i_midrange_pixel <= kDSC_PIXEL_INIT;
            i_first_group_of_slice <= 1'b0;

        end else begin

            // PPS local copies for timing
            i_pps_update <= dsc_pps_update;
            if (dsc_pps_update == 1'b1)  begin
                i_dsc_slice_width <= cfg_pps.slice_width;
                i_dsc_slice_height <= cfg_pps.slice_height;
            end // if

            // track the number of read pixels in a line
            if (i_pps_update == 1'b1) begin
                i_read_count <= i_dsc_slice_width;
            end else if (dsc_valid_out == 1'b1) begin
                if (dsc_last_out == 1'b1) begin
                    i_read_count <= i_dsc_slice_width;
                end else begin
                    i_read_count <= i_read_count_minus_3;
                end // if
            end // if

            // track the lines in a slice
            if (i_pps_update == 1'b1) begin
                i_line_count <= i_dsc_slice_height;
                i_first_group_of_slice <= 1'b1;
            end else if (dsc_valid_out == 1'b1) begin
                if (dsc_last_out == 1'b1 && i_line_count[15:1] == 15'd0) begin
                    i_line_count <= i_dsc_slice_height;
                    i_first_group_of_slice <= 1'b1;
                end else begin
                    i_line_count <= (dsc_last_out == 1'b1) ? i_line_count - 16'd1 : i_line_count;
                    i_first_group_of_slice <= 1'b0;
                end // if
            end // if

            // determine a midrange pixel for slice padding
            if (dsc_pps_update == 1'b1) begin
                case (cfg_pps.bits_per_component)
                    4'd0:    i_midrange_pixel <= '{y:16'h1000, co:16'h1000, cg:16'h1000};
                    4'd10:   i_midrange_pixel <= '{y:16'h0200, co:16'h0400, cg:16'h0400};
                    4'd12:   i_midrange_pixel <= '{y:16'h0800, co:16'h1000, cg:16'h1000};
                    4'd14:   i_midrange_pixel <= '{y:16'h2000, co:16'h4000, cg:16'h4000};
                    default: i_midrange_pixel <= '{y:16'h0080, co:16'h0100, cg:16'h0100};
                endcase
            end // if
        end // if
    end : SliceTrack


    // --------------------------------------------------------------------------
    //   read controller
    // --------------------------------------------------------------------------
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : ReadStage
        if (dsc_reset_n == 1'b0) begin
            dsc_start_of_slice <= 1'b0;
            dsc_valid_out <= 1'b0;
            dsc_last_out <= 1'b0;
            dsc_data_out <= '{default: kDSC_PIXEL_INIT};

            i_read_state <= 2'd0;
            i_dsc_raddr <= '{default: 1'b0};
            i_dsc_ren <= 1'b0;
            i_pixel_staging <= '{default: kDSC_PIXEL_INIT};
            i_pipeline_state <= eDPS_BUFFER_EMPTY;

        end else begin

            // the FIFO read address is advanced by the read enable
            if (dsc_valid_out == 1'b1 && dsc_last_out == 1'b1) begin
                i_dsc_raddr <= '{default: 1'b0};
            end else if (i_dsc_ren == 1'b1) begin
                i_dsc_raddr <= i_dsc_raddr_plus_1;
            end // if

            // default states
            dsc_valid_out <= 1'b0;
            dsc_last_out <= 1'b0;
            dsc_start_of_slice <= 1'b0;
            i_dsc_ren <= 1'b0;

            // buffer and pipeline management
            if (dsc_pps_update == 1'b1 || dsc_last_out == 1'b1) begin
                dsc_last_out <= 1'b0;
                i_pipeline_state <= eDPS_BUFFER_EMPTY;
                i_dsc_ren <= 1'b0;

            end else begin
                case (i_pipeline_state)
                    eDPS_BUFFER_EMPTY:  begin
                        if (i_dsc_write_ready == 1'b1) begin
                            i_dsc_ren <= 1'b1;
                            i_pipeline_state <= eDPS_REFILL_DELAY;

                            if (i_first_group_of_slice == 1'b1)  begin
                                dsc_start_of_slice <= 1'b1;
                            end // if
                        end // if
                    end // eDPS_BUFFER_EMPTY

                    eDPS_REFILL_DELAY:  begin
                        i_pipeline_state <= eDPS_P3;
                    end // eDPS_REFILL_DELAY

                    eDPS_P0:  i_pipeline_state <= eDPS_P1;
                    eDPS_P2:  i_pipeline_state <= eDPS_P3;

                    eDPS_P1:  begin
                        i_dsc_ren <= (i_read_state != 2'b11) ? 1'b1 : 1'b0;
                        i_pipeline_state <= eDPS_P2;
                    end // eDPS_P1

                    eDPS_P3:  begin
                        dsc_valid_out <= 1'b1;

                        if (i_read_last_word_flag == 1'b1) begin // && i_read_count[1:0] != 2'd3) begin
                            dsc_last_out <= 1'b1;
                            i_pipeline_state <= eDPS_BUFFER_EMPTY;
                        end else begin
                            dsc_last_out <= 1'b0;
                            i_pipeline_state <= eDPS_P0;
                        end // if

                        if (i_read_last_word_flag == 1'b1) begin
                            case (i_read_count[1:0])
                                2'b10:   dsc_data_out <= '{i_data_out[1], i_data_out[1], i_data_out[0]};
                                2'b01:   dsc_data_out <= '{i_data_out[0], i_data_out[0], i_data_out[0]};
                                default: dsc_data_out <= i_data_out;
                            endcase
                        end else begin
                            dsc_data_out <= i_data_out;
                        end // if
                    end // eDPS_P3

                    default:  begin
                        dsc_valid_out <= 1'b0;
                        dsc_data_out <= '{default: kDSC_PIXEL_INIT};
                        i_pipeline_state <= eDPS_P2;
                    end // default
                endcase
            end // if

            // stage based reading
            if (dsc_valid_out == 1'b1) begin
                i_pixel_staging <= (i_read_state == 2'b00) ? '{i_dsc_rdata[0], i_dsc_rdata[3]} : '{i_dsc_rdata[3], i_dsc_rdata[2]};
                i_read_state <= (dsc_last_out == 1'b1) ? 2'd0 : (i_read_state + 2'd1);
            end // if
        end // if
    end : ReadStage


    // ------------------------------------------------------------------------------------------------------------
    //                                 buffer memory and sync stages
    // ------------------------------------------------------------------------------------------------------------
    gram_bist_1r1w
    # (
        .pADDRESS_BITS  (pSB_ADDR_BITS),
        .pDATA_BITS     (192)
    ) input_buffer_inst
    (
        // port a, read port
        .clk_r          (dsc_clk),
        .en_r           (i_dsc_ren),
        .addr_r         (i_dsc_raddr),
        .data_r         (i_rdata),
        // port b, write port
        .clk_w          (axi_clk),
        .addr_w         (i_axi_waddr),
        .we_w           (i_axi_we),
        .data_w         (i_axi_wdata),
        // bist interface
        .bist_in        (bist_sram_in),
        .bist_out       (bist_sram_out)
    );

    gprim_sync_stage  sync_wrdy_inst (.sync_clk (dsc_clk), .reset_n (dsc_reset_n), .async_in (i_axi_write_ready), .sync_out(i_dsc_write_ready));

endmodule : dsce_slice_buffer

