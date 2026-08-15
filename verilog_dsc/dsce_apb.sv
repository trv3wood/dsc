// ------------------------------------------------------------------------------------------------
//     COPYRIGHT © 2015-2022, TRILINEAR TECHNOLOGIES, INC.
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
//     DESCRIPTION : Host interface for the DSC encoder core based on the AMBA 4 APB
//                   interface.  Includes wait states for PPS SRAM access.
// ------------------------------------------------------------------------------------------------

// ----------------------------------------------
//  includes
// ----------------------------------------------
import dsce_defs_pkg::*;
import dsce_regdefs_pkg::*;


// ----------------------------------------------
//  module declaration
// ----------------------------------------------
module dsce_apb
#(
    parameter int  pSPC = 4,                                    // number of slice processors (must be a power of 2)
    parameter int  pMAX_SLICE_LINE_SIZE = 4096,                 // maximum reference line size
    parameter int  pINCLUDE_BLOCK_PREDICTION = 1                // includes support for block prediction
)
(
    // apb-4 interface
    input  logic                    apb_clk,                    // APB bus clock
    input  logic                    apb_reset_n,                // APB domain reset
    input  logic                    apb_select,                 // select
    input  logic                    apb_enable,                 // enable
    input  logic                    apb_write,                  // write enable
    input  logic [3:0]              apb_strobe,                 // byte write strobe
    input  logic [2:0]              apb_protect,                // access protection fields
    input  logic [11:0]             apb_addr,                   // address
    input  logic [31:0]             apb_wdata,                  // write data
    output logic                    apb_ready,                  // ready output
    output logic                    apb_slave_error,            // slave programming error
    output logic [31:0]             apb_rdata,                  // read data

    // PPS access interface
    output logic                    apb_pps_write,              // write to the PPS SRAM
    output logic [6:0]              apb_pps_index,              // SRAM write index
    output logic [7:0]              apb_pps_wdata,              // SRAM write data
    output logic                    apb_pps_commit,             // commit changes
    input  logic [7:0]              apb_pps_rdata,              // SRAM read data

    // internal register assignments and control signals
    output tDSCE_CONFIG             cfg_dsc_encoder,            // general encoder configuration
    input  tDSCE_CONTROL_STATUS     cfg_dsc_encoder_status,     // encoder operating status
    output tDSCE_INTERRUPT_CONFIG   cfg_dsc_interrupt,          // interrupt config
    input  tDSCE_INTERRUPT_STATUS   cfg_dsc_interrupt_status,   // interrupt status
    output tDSCE_TIMERS_CONFIG      cfg_dsc_timers_config,      // timers config
    input  tDSCE_TIMERS_STATUS      cfg_dsc_timers_status,      // timers status
    output logic                    apb_soft_reset              // core soft reset
);
    // ------------------------------------------------------------------------------------------------------------
    //                                          internal definitions
    // ------------------------------------------------------------------------------------------------------------

    // ---------------------------------------------
    //  APB management signals
    // ---------------------------------------------
    logic           i_apb_write;                    // apb write enable
    logic [3:0]     i_apb_strobe;                   // apb byte write strobes
    logic [11:0]    i_apb_address;                  // registered apb address
    logic [31:0]    i_apb_wdata;                    // registered write data
    logic           i_apb_read;                     // apb read enable
    logic [1:0]     i_ready_count;                  // number of cycles to deassert ready


    // ----------------------------------------------
    //  constants (localparam)
    // ----------------------------------------------
    localparam logic [15:0] kCORE_ID_CODE       = 16'h0031;
    localparam logic [15:0] kCORE_REVISION_CODE = 16'h0205;

    // ------------------------------------------------------------------------------------------------------------
    //                                          processes
    // ------------------------------------------------------------------------------------------------------------

    // ---------------------------------------------------------------------
    //  combinatorial logic
    // ---------------------------------------------------------------------
    always_comb begin : SigMap
        i_apb_read = apb_select & ~apb_write;
    end : SigMap


    // ---------------------------------------------------------------------------
    //  A read transaction occurs when the address is valid and the core is
    //  selected.  A write occurs when the write signal is high, the enable is
    //  high and the address is valid.  Writes are buffered to reduce the
    //  fanout on the write data lines.
    // ---------------------------------------------------------------------------
    always_ff@(posedge apb_clk or negedge apb_reset_n) begin : APBInterface
        if (apb_reset_n == 1'b0) begin
            apb_rdata <= 32'h0000_0000;
            apb_ready <= 1'b1;
            apb_slave_error <= 1'b0;
            apb_pps_write <= 1'b0;
            apb_pps_commit <= 1'b0;
            apb_pps_wdata <= 8'h00;
            apb_pps_index <= 7'h00;

            cfg_dsc_encoder <= kDSCE_CONFIG_INIT;
            cfg_dsc_encoder.slice_processor_count <= pSPC[3:0];
            cfg_dsc_interrupt <= kDSCE_INTERRUPT_CONFIG_INIT;
            cfg_dsc_timers_config <= kDSCE_TIMERS_CONFIG_INIT;

            i_apb_address <= 12'h000;
            i_apb_wdata <= 32'h0000_0000;
            i_apb_write <= 1'b0;
            i_apb_strobe <= 4'h0;
            i_ready_count <= 2'b00;

        end else begin
            // local sampling, qualified for power reduction
            if (apb_select == 1'b1) begin
                i_apb_address <= apb_addr;
                i_apb_wdata <= apb_wdata;
            end // if

            // posted writes to reduce wdata bus loading
            if ((apb_enable == 1'b1 && apb_select == 1'b1) && (apb_write == 1'b1 && apb_ready == 1'b1)) begin
                i_apb_write <= 1'b1;
                i_apb_strobe <= apb_strobe;
            end else begin
                i_apb_write <= 1'b0;
                i_apb_strobe <= 4'h0;
            end // if

            // wait state assertion and error flags
            apb_slave_error <= 1'b0;

            if (i_ready_count == 2'd0) begin
                apb_ready <= 1'b1;

                // allow a pipelined write to complete before reading
                if (i_apb_write == 1'b1 && i_apb_read == 1'b1 && i_apb_address == apb_addr) begin
                    apb_ready <= 1'b0;
                    i_ready_count <= 2'd1;
                end else if (((i_apb_read == 1'b1 && apb_enable == 1'b0) || ((apb_enable == 1'b1 && apb_select == 1'b1) && (apb_write == 1'b1 && apb_ready == 1'b1))) && apb_addr == kDSCE_PPS_TABLE_DATA) begin
                    apb_ready <= 1'b0;
                    i_ready_count <= 2'd2;
                end // if
            end else begin
                if (i_ready_count == 2'd1) begin
                    apb_ready <= 1'b1;
                end // if
                i_ready_count <= i_ready_count - 2'd1;
            end // if

            // PPS table index
            if (i_apb_write == 1'b1 && i_apb_address == kDSCE_PPS_TABLE_ENTRY && i_apb_strobe[0] == 1'b1) begin
                apb_pps_index <= i_apb_wdata[6:0];
            end else if (apb_pps_write == 1'b1 || ((i_apb_read == 1'b1 && apb_enable == 1'b1) && (apb_ready == 1'b1 && apb_addr == kDSCE_PPS_TABLE_DATA))) begin
                apb_pps_index <= apb_pps_index + 7'd1;
            end // if

            // default signal states
            apb_pps_write <= 1'b0;
            apb_pps_commit <= 1'b0;
            cfg_dsc_interrupt.clear <= 1'b0;
            cfg_dsc_interrupt.clear_frame_count <= 1'b0;

            // write interface
            if (i_apb_write == 1'b1) begin
                // addresses are embedded here
                case (i_apb_address)
                    // ----------------------------------------------------
                    //   Basic fields
                    // ----------------------------------------------------
                    kDSCE_ENCODER_COMMAND:  begin
                        if (i_apb_strobe[0] == 1'b1)  cfg_dsc_encoder.encode_command <= tDSCE_ENCODER_COMMAND'(i_apb_wdata[3:0]);
                        if (i_apb_strobe[0] == 1'b1)  cfg_dsc_encoder.encode_command_update <= ~cfg_dsc_encoder.encode_command_update;
                    end // kDSCE_ENCODER_COMMAND

                    kDSCE_ENCODER_ACTIVE:  ;
                    kDSCE_PIXELS_PER_CYCLE:       if (i_apb_strobe[0] == 1'b1)  cfg_dsc_encoder.pixels_per_cycle <= i_apb_wdata[2:0];
                    kDSCE_LOCK_TO_INPUT_VSYNC:    if (i_apb_strobe[0] == 1'b1)  cfg_dsc_encoder.follow_vsync <= i_apb_wdata[0];
                    kDSCE_ENCODER_TIMEOUT_COUNT:  if (i_apb_strobe[0] == 1'b1)  cfg_dsc_encoder.timeout_count <= i_apb_wdata[7:0];
                    kDSCE_RESERVED_014:  ;
                    kDSCE_RESERVED_018:  ;
                    kDSCE_RESERVED_01C:  ;
                    kDSCE_ENCODED_FRAME_COUNT:    if (i_apb_strobe[0] == 1'b1)  cfg_dsc_interrupt.clear_frame_count <= i_apb_wdata[0];
                    kDSCE_FORCE_ENABLE:           if (i_apb_strobe[0] == 1'b1)  cfg_dsc_encoder.force_enable <= i_apb_wdata[0];
                    kDSCE_QP_OVERRIDE:  begin
                        if (i_apb_strobe[1] == 1'b1)  cfg_dsc_encoder.qp_override_enable <= i_apb_wdata[8];
                        if (i_apb_strobe[0] == 1'b1)  cfg_dsc_encoder.qp_override <= i_apb_wdata[4:0];
                    end // kDSCE_QP_OVERRIDE
                    kDSCE_USEC_CLOCK_DIVIDER:  begin
                        if (i_apb_strobe[1] == 1'b1) cfg_dsc_encoder.clock_divider[9:8] <= i_apb_wdata[9:8];
                        if (i_apb_strobe[0] == 1'b1) cfg_dsc_encoder.clock_divider[7:0] <= i_apb_wdata[7:0];
                    end // kDSCE_USEC_CLOCK_DIVIDER
                    kDSCE_OUTPUT_MODE:            if (i_apb_strobe[0] == 1'b1) cfg_dsc_encoder.output_mode <= i_apb_wdata[2:0];
                    kDSCE_HOST_TIMER:  begin
                        if (i_apb_strobe[3] == 1'b1) begin
                            cfg_dsc_timers_config.timer_enable <= i_apb_wdata[31];
                            cfg_dsc_timers_config.autoreload <= i_apb_wdata[30];
                            cfg_dsc_timers_config.interrupt_enable <= i_apb_wdata[29];
                        end // if
                        if (i_apb_strobe[2] == 1'b1) cfg_dsc_timers_config.reload_value[23:16] <= i_apb_wdata[23:16];
                        if (i_apb_strobe[1] == 1'b1) cfg_dsc_timers_config.reload_value[15:8] <= i_apb_wdata[15:8];
                        if (i_apb_strobe[0] == 1'b1) cfg_dsc_timers_config.reload_value[7:0] <= i_apb_wdata[7:0];
                    end // kDSCE_HOST_TIMER

                    // ----------------------------------------------------
                    //  slice control registers
                    // ----------------------------------------------------
                    kDSCE_SLICE_WIDTH_ALIGNMENT:  if (i_apb_strobe[0] == 1'b1)  cfg_dsc_encoder.slice_width_alignment <= i_apb_wdata[2:0];
                    kDSCE_SLICES_PER_LINE:        if (i_apb_strobe[0] == 1'b1)  cfg_dsc_encoder.slices_per_line <= i_apb_wdata[4:0];
                    kDSCE_SLICES_PER_PROCESSOR:   if (i_apb_strobe[0] == 1'b1)  cfg_dsc_encoder.slices_per_processor <= i_apb_wdata[7:0];
                    kDSCE_SLICE_PROCESSOR_COUNT:  if (i_apb_strobe[0] == 1'b1)  cfg_dsc_encoder.slice_processor_count <= i_apb_wdata[3:0];
                    kDSCE_SLICE_BUFFER_DEPTH:     begin
                        if (i_apb_strobe[1] == 1'b1) cfg_dsc_encoder.slice_buffer_depth[13:8] <= i_apb_wdata[13:8];
                        if (i_apb_strobe[0] == 1'b1) cfg_dsc_encoder.slice_buffer_depth[7:0] <= i_apb_wdata[7:0];
                    end // kDSCE_SLICE_BUFFER_DEPTH

                    // ----------------------------------------------------
                    //   rate control set up
                    // ----------------------------------------------------
                    kDSCE_MAX_BITS_PER_GROUP:  if (i_apb_strobe[0] == 1'b1)  cfg_dsc_encoder.max_bits_per_group <= i_apb_wdata[7:0];
                    kDSCE_TRAILING_BITS_FLAG:  if (i_apb_strobe[0] == 1'b1)  cfg_dsc_encoder.chunk_trailing_bits_flag <= i_apb_wdata[0];
                    kDSCE_CHUNK_SIZE: begin
                        if (i_apb_strobe[1] == 1'b1) cfg_dsc_encoder.chunk_size[11:8] <= i_apb_wdata[11:8];
                        if (i_apb_strobe[0] == 1'b1) cfg_dsc_encoder.chunk_size[7:0] <= i_apb_wdata[7:0];
                    end // kDSCE_CHUNK_SIZE

                    // ----------------------------------------------------
                    //   interrupt controller
                    // ----------------------------------------------------
                    kDSCE_INTERRUPT_ENABLE:       if (i_apb_strobe[0] == 1'b1)  cfg_dsc_interrupt.enable <= i_apb_wdata[6:0];
                    kDSCE_INTERRUPT_CAUSE:  ;
                    kDSCE_INTERRUPT_STATE:  ;
                    kDSCE_FRAME_INTERRUPT_COUNT:  if (i_apb_strobe[0] == 1'b1)  cfg_dsc_interrupt.int_frame_count <= i_apb_wdata[7:0];

                    // ----------------------------------------------------
                    //   PPS SRAM table
                    // ----------------------------------------------------
                    kDSCE_PPS_TABLE_DATA:  begin
                        if (i_apb_strobe[0] == 1'b1) begin
                            apb_pps_write <= 1'b1;
                            apb_pps_wdata <= i_apb_wdata[7:0];
                        end // if
                    end // kDSCE_PPS_TABLE_DATA
                    kDSCE_PPS_TABLE_ENTRY:  ;         // table write index
                    kDSCE_PPS_TABLE_COMMIT:       if (i_apb_strobe[0] == 1'b1)  apb_pps_commit <= i_apb_wdata[0];

                    // ----------------------------------------------------
                    //   Capabilities and core ID and revision level
                    // ----------------------------------------------------
                    kDSCE_CORE_FEATURES:  ;                      // read only
                    kDSCE_CORE_REVISION:  ;                      // read only

                    default:  ;
                endcase
            end // if


            // read interface
            if (i_apb_read == 1'b1) begin
                // default value
                apb_rdata <= 32'h00000000;

                // addresses are embedded here
                case (apb_addr)
                    // ----------------------------------------------------
                    //   Basic Configuration Fields
                    // ----------------------------------------------------
                    kDSCE_ENCODER_COMMAND:        apb_rdata[3:0] <= cfg_dsc_encoder.encode_command;
                    kDSCE_ENCODER_ACTIVE:         apb_rdata[0]   <= cfg_dsc_encoder_status.encoder_active;
                    kDSCE_PIXELS_PER_CYCLE:       apb_rdata[2:0] <= cfg_dsc_encoder.pixels_per_cycle;
                    kDSCE_LOCK_TO_INPUT_VSYNC:    apb_rdata[0]   <= cfg_dsc_encoder.follow_vsync;
                    kDSCE_ENCODER_TIMEOUT_COUNT:  apb_rdata[7:0] <= cfg_dsc_encoder.timeout_count;
                    kDSCE_RESERVED_014:           ;
                    kDSCE_RESERVED_018:           ;
                    kDSCE_RESERVED_01C:           ;
                    kDSCE_ENCODED_FRAME_COUNT:    apb_rdata[7:0] <= cfg_dsc_interrupt_status.encoded_frame_count;
                    kDSCE_FORCE_ENABLE:           apb_rdata[0]   <= cfg_dsc_encoder.force_enable;
                    kDSCE_QP_OVERRIDE:            apb_rdata[8:0] <= {cfg_dsc_encoder.qp_override_enable, 3'b000, cfg_dsc_encoder.qp_override};
                    kDSCE_USEC_CLOCK_DIVIDER:     apb_rdata[9:0] <= cfg_dsc_encoder.clock_divider;
                    kDSCE_OUTPUT_MODE:            apb_rdata[2:0] <= cfg_dsc_encoder.output_mode;
                    kDSCE_HOST_TIMER:             apb_rdata      <= {cfg_dsc_timers_config.timer_enable, cfg_dsc_timers_config.autoreload, cfg_dsc_timers_config.interrupt_enable, 5'b00000, cfg_dsc_timers_status.timer_value};

                    // slice control registers
                    kDSCE_SLICE_WIDTH_ALIGNMENT:  apb_rdata[2:0]  <= cfg_dsc_encoder.slice_width_alignment;
                    kDSCE_SLICES_PER_LINE:        apb_rdata[4:0]  <= cfg_dsc_encoder.slices_per_line;
                    kDSCE_SLICES_PER_PROCESSOR:   apb_rdata[7:0]  <= cfg_dsc_encoder.slices_per_processor;
                    kDSCE_SLICE_PROCESSOR_COUNT:  apb_rdata[3:0]  <= cfg_dsc_encoder.slice_processor_count;
                    kDSCE_SLICE_BUFFER_DEPTH:     apb_rdata[13:0] <= cfg_dsc_encoder.slice_buffer_depth;

                    // ----------------------------------------------------
                    //   rate control set up
                    // ----------------------------------------------------
                    kDSCE_MAX_BITS_PER_GROUP:  apb_rdata[7:0]  <= cfg_dsc_encoder.max_bits_per_group;
                    kDSCE_TRAILING_BITS_FLAG:  apb_rdata[0]    <= cfg_dsc_encoder.chunk_trailing_bits_flag;
                    kDSCE_CHUNK_SIZE:          apb_rdata[11:0] <= cfg_dsc_encoder.chunk_size;

                    // ----------------------------------------------------
                    //   interrupt controller
                    // ----------------------------------------------------
                    kDSCE_INTERRUPT_ENABLE:  begin
                        apb_rdata[6:0] <= cfg_dsc_interrupt.enable;
                        cfg_dsc_interrupt.clear <= 1'b1;
                    end // kDSCE_INTERRUPT_ENABLE
                    kDSCE_INTERRUPT_CAUSE:        apb_rdata[6:0] <= cfg_dsc_interrupt_status.cause;
                    kDSCE_INTERRUPT_STATE:        apb_rdata[6:0] <= cfg_dsc_interrupt_status.state;
                    kDSCE_FRAME_INTERRUPT_COUNT:  apb_rdata[7:0] <= cfg_dsc_interrupt.int_frame_count;

                    // ----------------------------------------------------
                    //   PPS SRAM table
                    // ----------------------------------------------------
                    kDSCE_PPS_TABLE_DATA:         apb_rdata[7:0] <= apb_pps_rdata;
                    kDSCE_PPS_TABLE_ENTRY:        apb_rdata[6:0] <= apb_pps_index;
                    kDSCE_PPS_TABLE_COMMIT:  ;     // table commit

                    // ----------------------------------------------------
                    //   Core ID and revision level
                    // ----------------------------------------------------
                    kDSCE_CORE_FEATURES:  begin
                        apb_rdata[31:16] <= pMAX_SLICE_LINE_SIZE[15:0];
                        apb_rdata[8]     <= pINCLUDE_BLOCK_PREDICTION[0];
                        apb_rdata[3:0]   <= pSPC[3:0];
                    end // kDSCE_CORE_FEATURES
                    kDSCE_CORE_REVISION:          apb_rdata[31:0] <= {kCORE_ID_CODE, kCORE_REVISION_CODE};

                    // default for synthesis only
                    default:  begin
                        apb_rdata <= 32'h00000000;
                    end // default
                endcase
            end // if

        end // if
    end : APBInterface


    // ---------------------------------------------------------------------------
    //   special case signals
    // ---------------------------------------------------------------------------
    always_ff@(posedge apb_clk or negedge apb_reset_n) begin : SpecialCase
        if (apb_reset_n == 1'b0) begin
            apb_soft_reset <= 1'b0;

        end else begin

            // soft reset command
            if (i_apb_write == 1'b1 && i_apb_address == kDSCE_ENCODER_COMMAND) begin
                apb_soft_reset <= (i_apb_wdata[3:0] == eENCODER_COMMAND_RESET_ALL) ? 1'b1 : 1'b0;
            end // if

        end // if
    end : SpecialCase


endmodule : dsce_apb

