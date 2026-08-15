// ------------------------------------------------------------------------------------------------
//     COPYRIGHT © 2021-2023, TRILINEAR TECHNOLOGIES, INC.
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
//     DESCRIPTION : Bypass buffer for operation in a MIPI, DP or HDMI data path.
// ------------------------------------------------------------------------------------------------

// ----------------------------------------------
//  includes
// ----------------------------------------------
import dsce_defs_pkg::*;
import dsce_regdefs_pkg::*;


// ----------------------------------------------
//  entity declaration
// ----------------------------------------------
module dsce_bypass
(
    // clock and control interface
    input  logic                    axi_clk,                // AXI input and output clock
    input  logic                    axi_reset_n,            // AXI domain reset
    input  logic                    cfg_bypass_enable,      // enable bypass mode
    input  logic [3:0]              cfg_bits_per_component, // source bpc
    input  logic [2:0]              cfg_output_mode,        // programmed output mode

    // encoder output data path
    input  logic                    axi_tframe_mux,         // frame flag
    input  logic                    axi_tline_mux,          // end of line flag
    input  logic                    axi_tvalid_mux,         // valid data
    output logic                    axi_tready_mux,         // ready from the output stages
    input  logic [63:0]             axi_tdata_mux,          // muxword output

    // input bypass path
    input  logic                    axi_tvalid_in,          // stream data valid
    output logic                    axi_tready_in,          // encoder ready to receive stream data
    input  logic                    axi_tline_in,           // start of line indicator
    input  logic                    axi_tframe_in,          // start of frame indicator
    input  logic [191:0]            axi_tdata_in,           // encoded stream input

    // streaming output data path
    output logic                    axi_tframe_out,         // frame flag
    output logic                    axi_tline_out,          // end of line flag
    output logic                    axi_tvalid_out,         // valid data
    input  logic                    axi_tready_out,         // ready from the output stages
    output logic [191:0]            axi_tdata_out           // muxword input (1 from each slice processor)
);

    // ------------------------------------------------------------------------------------------------------------
    //                                          internal definitions
    // ------------------------------------------------------------------------------------------------------------

    // ----- input mux ----- //
    logic                           i_tvalid_in;
    logic                           i_tline_in;
    logic                           i_tframe_in;
    logic [191:0]                   i_tdata_in;
    logic [1:0]                     i_tready_in;
    logic [1:0]                     i_axi_bypass_enable;
    logic                           i_axi_soft_reset;
    logic                           i_tframe_reg;

    // ----- word assember ----- //
    logic [191:0]                   i_assembled_word;
    logic [1:0]                     i_muxword_count, i_max_muxword_count;


    // ----- rate buffer ----- //
    localparam int kRATE_BUFFER_DEPTH = 32;
    localparam int kRATE_BUFFER_ABITS = $clog2(kRATE_BUFFER_DEPTH);

    logic [191:0]                   i_rate_buffer[kRATE_BUFFER_DEPTH-1:0];
    logic [kRATE_BUFFER_ABITS-1:0]  i_rate_buffer_wptr, i_rate_buffer_wptr_plus_1;
    logic [kRATE_BUFFER_ABITS-1:0]  i_rate_buffer_rptr, i_rate_buffer_rptr_plus_1;
    logic                           i_rate_buffer_we;
    logic                           i_rate_buffer_re;
    logic                           i_rate_buffer_empty;
    logic [191:0]                   i_rate_buffer_rdata;


    // ----- output controller ----- //
    enum {
        eDS_EMPTY,
        eDS_INIT_READ,
        eDS_INIT_OUT,
        eDS_RUNNING,
        eDS_TRANSFER_LAST
    } i_data_state;

    logic                           i_tframe_pending;
    logic                           i_tline_pending;
    logic                           i_data_path_init;
    logic [4:0]                     i_output_word_count, i_max_output_word_count;
    logic [4:0]                     i_output_word_count_increment;
    logic                           i_rate_word_complete;
    logic [191:0]                   i_rate_word_out, i_rate_word_mask;


    // ------------------------------------------------------------------------------------------------------------
    //                                          internal processes
    // ------------------------------------------------------------------------------------------------------------

    // -------------------------------------------------------
    //  combinatorial signals
    // -------------------------------------------------------
    always_comb begin : SigMap
        axi_tready_in = i_tready_in[1];
        axi_tready_mux = i_tready_in[0];
        i_axi_soft_reset = (i_axi_bypass_enable[1] != i_axi_bypass_enable[0]) ? 1'b1 : 1'b0;

        i_max_muxword_count = (cfg_bits_per_component == 4'd8 || cfg_bits_per_component == 4'd10) ? 2'd3 : 2'd2;

        case (cfg_output_mode)
            kDSCE_OUTPUT_8_BIT:     begin  i_max_output_word_count = 5'd23;  i_output_word_count_increment = 5'd1;   i_rate_word_mask = {{184{1'b0}}, {  8{1'b1}}};     end
            kDSCE_OUTPUT_16_BIT:    begin  i_max_output_word_count = 5'd22;  i_output_word_count_increment = 5'd2;   i_rate_word_mask = {{176{1'b0}}, { 16{1'b1}}};     end
            kDSCE_OUTPUT_24_BIT:    begin  i_max_output_word_count = 5'd21;  i_output_word_count_increment = 5'd3;   i_rate_word_mask = {{168{1'b0}}, { 24{1'b1}}};     end
            kDSCE_OUTPUT_32_BIT:    begin  i_max_output_word_count = 5'd20;  i_output_word_count_increment = 5'd4;   i_rate_word_mask = {{160{1'b0}}, { 32{1'b1}}};     end
            kDSCE_OUTPUT_48_BIT:    begin  i_max_output_word_count = 5'd18;  i_output_word_count_increment = 5'd6;   i_rate_word_mask = {{144{1'b0}}, { 48{1'b1}}};     end
            kDSCE_OUTPUT_64_BIT:    begin  i_max_output_word_count = 5'd16;  i_output_word_count_increment = 5'd8;   i_rate_word_mask = {{128{1'b0}}, { 64{1'b1}}};     end
            kDSCE_OUTPUT_96_BIT:    begin  i_max_output_word_count = 5'd12;  i_output_word_count_increment = 5'd12;  i_rate_word_mask = {{ 96{1'b0}}, { 96{1'b1}}};     end
            default:                begin  i_max_output_word_count = 5'd0;   i_output_word_count_increment = 5'd24;  i_rate_word_mask = {192{1'b1}};     end
        endcase

        i_rate_word_complete = (i_output_word_count == i_max_output_word_count) ? 1'b1 : 1'b0;
        i_rate_buffer_wptr_plus_1 = i_rate_buffer_wptr + kDSCE_ONE[kRATE_BUFFER_ABITS-1:0];
        i_rate_buffer_rptr_plus_1 = i_rate_buffer_rptr + kDSCE_ONE[kRATE_BUFFER_ABITS-1:0];
        i_rate_buffer_empty = (i_rate_buffer_wptr == i_rate_buffer_rptr && i_tready_in != 2'b00) ? 1'b1 : 1'b0;
        i_rate_buffer_re = (i_data_path_init == 1'b1) || ((axi_tready_out == 1'b1 && axi_tvalid_out == 1'b1) && 
                                                          (i_output_word_count == i_max_output_word_count && i_rate_buffer_empty == 1'b0) && 
                                                          (i_data_state != eDS_TRANSFER_LAST)) ? 1'b1 : 1'b0;

        i_rate_word_out = i_rate_buffer_rdata >> {i_output_word_count, 3'b000};

    end : SigMap


    // -------------------------------------------------------
    //  Input select mux
    // -------------------------------------------------------
    always_comb begin : InputMux
        if (cfg_bypass_enable == 1'b1) begin
            i_tvalid_in = axi_tvalid_in;
            i_tframe_in = axi_tframe_in;
            i_tline_in  = axi_tline_in;
            i_tdata_in  = axi_tdata_in;
        end else begin
            i_tvalid_in = axi_tvalid_mux;
            i_tframe_in = axi_tframe_mux;
            i_tline_in  = axi_tline_mux;
            i_tdata_in  = {128'd0, axi_tdata_mux};
        end // if
    end : InputMux


    // -------------------------------------------------------
    //  Data assembly to maximum size and buffer
    // -------------------------------------------------------
    always_ff @(posedge axi_clk or negedge axi_reset_n) begin : DataAssembly
        if (axi_reset_n == 1'b0) begin
            i_assembled_word <= 192'd0;
            i_muxword_count <= 2'd0;
            i_tready_in <= 2'b11;
            i_rate_buffer_we <= 1'b0;
            i_rate_buffer_wptr <= '{default: 1'b0};
            i_rate_buffer_rptr <= '{default: 1'b0};
            i_rate_buffer_rdata <= '{default: 1'b0};

        end else begin

            // defaults
            i_rate_buffer_we <= 1'b0;

            // ----- word assembler ----- //
            if (cfg_bypass_enable == 1'b1) begin
                if (i_tready_in != 2'b00 && i_tvalid_in == 1'b1) begin
                    i_assembled_word <= i_tdata_in;
                    i_rate_buffer_we <= 1'b1;
                end // if
                i_muxword_count <= 2'd0;
            end else begin
                if (i_tready_in != 2'b00 && i_tvalid_in == 1'b1) begin
                    if (i_max_muxword_count == 2'd3) begin
                        i_assembled_word <= {i_tdata_in[47:0], i_assembled_word[191:48]};
                    end else begin
                        i_assembled_word <= {i_tdata_in[63:0], i_assembled_word[191:64]};
                    end // if

                    if (i_muxword_count == i_max_muxword_count) begin
                        i_rate_buffer_we <= 1'b1;
                        i_muxword_count <= 2'd0;
                    end else begin
                        i_muxword_count <= i_muxword_count + 2'd1;
                    end // if
                end // if
            end // if

            // ----- rate buffer write ----- //
            if (i_rate_buffer_we == 1'b1) begin
                i_rate_buffer[i_rate_buffer_wptr] <= i_assembled_word;
            end // if

            if (i_axi_soft_reset == 1'b1) begin
                i_rate_buffer_wptr <= '{default: 1'b0};
            end else if (i_rate_buffer_we == 1'b1) begin
                i_rate_buffer_wptr <= i_rate_buffer_wptr_plus_1;
            end // if

            // ----- rate buffer read ----- //
            if (i_axi_soft_reset == 1'b1) begin
                i_rate_buffer_rptr <= '{default: 1'b0};
            end else if (i_rate_buffer_re == 1'b1) begin
                i_rate_buffer_rptr <= i_rate_buffer_rptr_plus_1;
            end // if

            // ----- ready output per source ----- //
            if (i_axi_soft_reset == 1'b1) begin
                i_tready_in <= {i_axi_bypass_enable[0], ~i_axi_bypass_enable[0]};
            end else begin
                if (i_tready_in != 2'b00) begin
                    if (i_rate_buffer_we == 1'b1 && i_rate_buffer_wptr_plus_1 == i_rate_buffer_rptr) begin
                        i_tready_in <= 2'b00;
                    end // if
                end else begin
                    if (i_rate_buffer_re == 1'b1) begin
                        i_tready_in <= {i_axi_bypass_enable[0], ~i_axi_bypass_enable[0]};
                    end // if
                end // if
            end // if

            // ----- rate buffer synchronous read ----- //
            if (i_rate_buffer_re == 1'b1) begin
                i_rate_buffer_rdata <= i_rate_buffer[i_rate_buffer_rptr];
            end // if

        end // if
    end : DataAssembly


    // -------------------------------------------------------
    //  Bypass register output
    // -------------------------------------------------------
    always_ff @(posedge axi_clk or negedge axi_reset_n) begin : BypassMuxLogic
        if (axi_reset_n == 1'b0) begin
            axi_tframe_out <= 1'b0;
            axi_tline_out <= 1'b0;
            axi_tvalid_out <= 1'b0;
            axi_tdata_out <= 192'd0;

            i_tframe_reg <= 1'b0;
            i_data_state <= eDS_EMPTY;
            i_tframe_pending <= 1'b0;
            i_tline_pending <= 1'b0;
            i_output_word_count <= 5'd0;
            i_data_path_init <= 1'b0;

        end else begin

            // edge detect of frame in
            i_tframe_reg <= i_tframe_in;

            // control signal staging
            if (i_data_state == eDS_EMPTY) begin
                axi_tframe_out <= i_tframe_in | i_tframe_pending;
                axi_tline_out <= i_tline_in | i_tline_pending;
                i_tframe_pending <= 1'b0;
                i_tline_pending <= 1'b0;
            end else begin
                i_tframe_pending <= i_tframe_in;
                i_tline_pending <= i_tline_in;
            end // if

            // output transfer count
            if ((i_tframe_in == 1'b1 && i_tframe_reg == 1'b0) || i_data_state == eDS_EMPTY) begin
                i_output_word_count <= 5'd0;
            end else begin
                if ((i_data_state == eDS_RUNNING && axi_tvalid_out == 1'b0) || (axi_tready_out == 1'b1 && axi_tvalid_out == 1'b1)) begin
                    if (i_output_word_count == i_max_output_word_count) begin
                        i_output_word_count <= 5'd0;
                    end else begin
                        i_output_word_count <= i_output_word_count + i_output_word_count_increment;
                    end // if
                end // if
            end // if

            // state based operation using ready_out as the state
            i_data_path_init <= 1'b0;

            if (i_tframe_in == 1'b1 && i_tframe_reg == 1'b0) begin
                axi_tvalid_out <= 1'b0;
                axi_tdata_out <= '{default: 1'b0};
                i_data_state <= eDS_EMPTY;
            end else begin
                case (i_data_state)
                    eDS_EMPTY:  begin
                        axi_tvalid_out <= 1'b0;

                        if (i_rate_buffer_empty == 1'b0) begin
                            i_data_state <= eDS_INIT_READ;
                            i_data_path_init <= 1'b1;
                        end // if
                    end // eDS_EMPTY

                    eDS_INIT_READ:  begin
                        axi_tvalid_out <= 1'b0;

                        if (cfg_bypass_enable == 1'b1) begin
                            i_data_path_init <= 1'b1;
                            i_data_state <= eDS_INIT_OUT;
                        end else begin
                            i_data_state <= eDS_RUNNING;
                        end // if
                    end // eDS_INIT_READ

                    eDS_INIT_OUT:  begin
                        axi_tvalid_out <= 1'b1;
                        axi_tdata_out <= i_rate_word_out & i_rate_word_mask;
                        i_data_state <= eDS_RUNNING;
                    end // eDS_INIT_OUT

                    eDS_RUNNING:  begin
                        if (cfg_bypass_enable == 1'b0 && axi_tvalid_out == 1'b0) begin
                            axi_tvalid_out <= 1'b1;
                            axi_tdata_out <= i_rate_word_out & i_rate_word_mask;
                        end else if (axi_tvalid_out == 1'b1 && axi_tready_out == 1'b1) begin
                            axi_tdata_out <= i_rate_word_out & i_rate_word_mask;

                            if (i_rate_word_complete == 1'b1 && i_rate_buffer_empty == 1'b1) begin
                                axi_tvalid_out <= 1'b1;
                                i_data_state <= eDS_TRANSFER_LAST;
                            end // if
                        end // if
                    end // eDS_RUNNING

                    eDS_TRANSFER_LAST:  begin
                        axi_tvalid_out <= 1'b1;

                        if (axi_tready_out == 1'b1) begin
                            axi_tvalid_out <= 1'b0;
                            i_data_state <= eDS_EMPTY;
                        end // if
                    end // eDS_TRANSFER_LAST

                    default:  begin
                        axi_tvalid_out <= 1'b0;
                        i_data_state <= eDS_EMPTY;
                        i_data_path_init <= 1'b0;
                    end // default
                endcase
            end // if

        end // if
    end : BypassMuxLogic


    // ------------------------------------------------------------------------------------------------------------
    //                                             sync stages
    // ------------------------------------------------------------------------------------------------------------
    gprim_sync2_stage  sync_bypass_inst (.sync_clk (axi_clk), .reset_n (axi_reset_n), .async_in (cfg_bypass_enable), .sync_out(i_axi_bypass_enable));

endmodule : dsce_bypass

