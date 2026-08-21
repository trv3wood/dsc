// ------------------------------------------------------------------------------------------------
//     COPYRIGHT © 2022-2023, TRILINEAR TECHNOLOGIES, INC.
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
module dsce_stream_fifo
(
    // clock and control interface
    input  logic                    dsc_clk,                    // DSC processing clock
    input  logic                    dsc_reset_n,                // DSC domain reset

    // input path from muxword builder
    input  logic                    dsc_start_of_slice,         // start of slice flag
    input  logic                    dsc_muxword_valid_in,       // MUX word valid input
    input  logic                    dsc_muxword_last_in,        // MUX word last flag input
    input  logic [63:0]             dsc_muxword_in,             // MUX word

    // syntax size input from VLC
    input  logic                    dsc_unit_size_valid_in,     // coded unit size valid in
    input  logic                    dsc_unit_size_last_in,      // coded unit size last in
    input  logic [5:0]              dsc_coded_unit_size_in,     // coded unit size in

    // output to the stream builder
    output logic                    dsc_coded_size_valid_out,   // unit size valid output
    input  logic                    dsc_coded_size_ready_out,   // unit size ready output
    output logic                    dsc_coded_size_last_out,    // unit size valid output
    output logic [5:0]              dsc_coded_size_out,         // unit size output

    output logic                    dsc_muxword_valid_out,      // output muxword is valid
    input  logic                    dsc_muxword_ready_out,      // output muxword ready
    output logic                    dsc_muxword_last_out,       // last muxword in a chunk
    output logic [63:0]             dsc_muxword_out             // muxword output
);

    // ------------------------------------------------------------------------------------------------------------
    //                                          internal definitions
    // ------------------------------------------------------------------------------------------------------------
    localparam int kMUXWORD_BUFFER_SIZE = 32;  //16;
    localparam int kSYNTAX_BUFFER_SIZE  = 128; //64;
    localparam int kMUXWORD_PTR_HIGH    = $clog2(kMUXWORD_BUFFER_SIZE)-1;
    localparam int kSYNTAX_PTR_HIGH     = $clog2(kSYNTAX_BUFFER_SIZE)-1;

    // ----- buffer signals ----- //
    logic [63:0]                    i_muxword_buffer [kMUXWORD_BUFFER_SIZE-1:0];
    logic [kMUXWORD_PTR_HIGH:0]     i_muxword_write_ptr, i_muxword_write_ptr_plus_1;
    logic [kMUXWORD_PTR_HIGH:0]     i_muxword_read_ptr, i_muxword_read_ptr_plus_1;
    logic                           i_muxword_full;
    logic                           i_muxword_read;

    logic [5:0]                     i_syntax_buffer [kSYNTAX_BUFFER_SIZE-1:0];
    logic [kSYNTAX_PTR_HIGH:0]      i_syntax_write_ptr, i_syntax_write_ptr_plus_1;
    logic [kSYNTAX_PTR_HIGH:0]      i_syntax_read_ptr, i_syntax_read_ptr_plus_1;
    logic                           i_syntax_full;

    // ------------------------------------------------------------------------------------------------------------
    //                                             processes
    // ------------------------------------------------------------------------------------------------------------

    // signal assignments
    always_comb begin : SignalMap
        i_syntax_read_ptr_plus_1 = i_syntax_read_ptr + kDSCE_ONE[kSYNTAX_PTR_HIGH-1:0];
        i_syntax_write_ptr_plus_1 = i_syntax_write_ptr + kDSCE_ONE[kSYNTAX_PTR_HIGH-1:0];
        i_muxword_read_ptr_plus_1 = i_muxword_read_ptr + kDSCE_ONE[kMUXWORD_PTR_HIGH:0];
        i_muxword_write_ptr_plus_1 = i_muxword_write_ptr + kDSCE_ONE[kMUXWORD_PTR_HIGH:0];

        i_muxword_read = (dsc_muxword_valid_out == 1'b1 && dsc_muxword_ready_out == 1'b1 && i_muxword_write_ptr != i_muxword_read_ptr) ||
                         (dsc_muxword_valid_out == 1'b0 && i_muxword_write_ptr != i_muxword_read_ptr) ? 1'b1 : 1'b0;
    end : SignalMap


    // ------------------------------------------------------
    //   muxword and syntax size buffers
    // ------------------------------------------------------
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : FlowControlBuffers
        if (dsc_reset_n == 1'b0) begin
            i_muxword_buffer <= '{default: 64'd0};
            i_muxword_write_ptr <= '{default: 1'b0};
            i_muxword_full <= 1'b0;
            i_syntax_buffer <= '{default: 5'd0};
            i_syntax_write_ptr <= '{default: 1'b0};
            i_syntax_full <= 1'b0;

        end else begin

            // ----- muxword buffer ----- //
            if (dsc_muxword_valid_in == 1'b1) begin
                i_muxword_buffer[i_muxword_write_ptr] <= dsc_muxword_in;
            end // if

            if (dsc_start_of_slice == 1'b1) begin
                i_muxword_write_ptr <= '{default: 1'b0};
            end else if (dsc_muxword_valid_in == 1'b1) begin
                if (dsc_muxword_last_in == 1'b1) begin
                    i_muxword_write_ptr <= '{default: 1'b0};
                end else begin
                    i_muxword_write_ptr <= i_muxword_write_ptr_plus_1;
                end // if
            end // if

            // ----- syntax buffer ----- //
            // valid 与 payload 属于同一接受事务，不能延迟 valid 后读取 live data。
            if (dsc_unit_size_valid_in == 1'b1) begin
                i_syntax_buffer[i_syntax_write_ptr] <= dsc_coded_unit_size_in;
            end // if

            if (dsc_start_of_slice == 1'b1) begin
                i_syntax_write_ptr <= '{default: 1'b0};
            end else if (dsc_unit_size_valid_in == 1'b1) begin
                i_syntax_write_ptr <= i_syntax_write_ptr_plus_1;
            end // if

            // ----- overflow logic ----- //
            if (dsc_start_of_slice == 1'b1) begin
                i_syntax_full <= 1'b0;
                i_muxword_full <= 1'b0;
            end else begin
                // muxword
                if (dsc_muxword_valid_in == 1'b1) begin
                    if (i_muxword_write_ptr_plus_1 == i_muxword_read_ptr && i_muxword_read == 1'b0) begin
                        i_muxword_full <= 1'b1;
                    end // if
                end else if (i_muxword_read == 1'b1) begin
                    i_muxword_full <= 1'b0;
                end // if

                // syntax
                if (dsc_unit_size_valid_in == 1'b1) begin
                    if (i_syntax_write_ptr_plus_1 == i_syntax_read_ptr && (dsc_coded_size_valid_out == 1'b0 || dsc_coded_size_ready_out == 1'b0) ) begin
                        i_syntax_full <= 1'b1;
                    end // if
                end else if (dsc_coded_size_valid_out == 1'b1 && dsc_coded_size_ready_out == 1'b1) begin
                    i_syntax_full <= 1'b0;
                end // if
            end // if

            // ----- error checking assertion ----- //
            if (dsc_unit_size_valid_in == 1'b1 && i_syntax_full == 1'b1 &&
                !(dsc_coded_size_valid_out == 1'b1 && dsc_coded_size_ready_out == 1'b1)) begin
                $display("SYNTAX_FIFO_OVERFLOW write=%0d read=%0d next=%0d out_valid=%0b out_ready=%0b in_valid=%0b",
                         i_syntax_write_ptr, i_syntax_read_ptr,
                         i_syntax_write_ptr_plus_1, dsc_coded_size_valid_out,
                         dsc_coded_size_ready_out, dsc_unit_size_valid_in);
            end
            // FIFO 满时若本拍消费者取走旧条目，写端可安全复用该槽位。
            assert (dsc_unit_size_valid_in == 1'b0 || i_syntax_full == 1'b0 ||
                    (dsc_coded_size_valid_out == 1'b1 && dsc_coded_size_ready_out == 1'b1))
                else $error("Syntax FIFO overflow");
            assert (dsc_muxword_valid_in == 1'b0 || i_muxword_full == 1'b0 ||
                    i_muxword_read == 1'b1)
                else $error("Muxword FIFO overflow");
            // muxword FIFO 写不越过读指针:写满阈值(write+1==read 且本拍无读)即为
            // full,读观察在写之前,故写使能时指针必不相等、不会单拍越过。
            assert (dsc_muxword_valid_in == 1'b0 || i_muxword_full == 1'b0)
                else $error("Muxword FIFO write-into-full");
        end // if
    end : FlowControlBuffers


    // ------------------------------------------------------
    //   output tracking counters and state machine
    // ------------------------------------------------------
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : OutputManager
        if (dsc_reset_n == 1'b0) begin
            dsc_muxword_valid_out <= 1'b0;
            dsc_muxword_last_out <= 1'b0;
            dsc_muxword_out <= '{default: 1'b0};
            dsc_coded_size_valid_out <= 1'b0;
            dsc_coded_size_out <= 6'd0;

            i_muxword_read_ptr <= '{default: 1'b0};
            i_syntax_read_ptr <= '{default: 1'b0};

        end else begin

            // ----- valid/ready out, coded size ----- //
            if (dsc_coded_size_valid_out == 1'b0) begin
                if (i_syntax_write_ptr != i_syntax_read_ptr || i_syntax_full == 1'b1) begin
                    dsc_coded_size_valid_out <= 1'b1;
                    dsc_coded_size_out <= i_syntax_buffer[i_syntax_read_ptr];
                end // if
            end else begin
                // read_ptr 指向当前输出项，write_ptr 指向下一空槽。
                // 消费后 read_ptr_plus_1 追上 write_ptr 才表示 FIFO 变空；原实现用
                // read_ptr == write_ptr，会把空 FIFO 继续保持 valid 并多消费一项。
                // 同拍有新写入时 write_ptr 也会前进，输出应继续保持有效。
                if (dsc_coded_size_ready_out == 1'b1 &&
                    i_syntax_read_ptr_plus_1 == i_syntax_write_ptr &&
                    i_syntax_full == 1'b0 && dsc_unit_size_valid_in == 1'b0) begin
                    dsc_coded_size_valid_out <= 1'b0;
                end // if
                dsc_coded_size_out <= i_syntax_buffer[i_syntax_read_ptr];
            end // if

            if (dsc_start_of_slice == 1'b1) begin
                i_syntax_read_ptr <= '{default: 1'b0};
            end else if (dsc_coded_size_valid_out == 1'b1 && dsc_coded_size_ready_out == 1'b1) begin
                i_syntax_read_ptr <= i_syntax_read_ptr_plus_1;
            end // if

            // ----- valid/ready out, muxword size ----- //
            if (dsc_muxword_valid_out == 1'b0) begin
                if (i_muxword_write_ptr != i_muxword_read_ptr || i_muxword_full == 1'b1) begin
                    dsc_muxword_valid_out <= 1'b1;
                    dsc_muxword_out <= i_muxword_buffer[i_muxword_read_ptr];
                end // if
            end else begin
                if (dsc_muxword_ready_out == 1'b1) begin
                    if (i_muxword_read_ptr == i_muxword_write_ptr && i_muxword_full == 1'b0)
                        dsc_muxword_valid_out <= 1'b0;
                    dsc_muxword_out <= i_muxword_buffer[i_muxword_read_ptr];
                end // if
            end // if

            if (dsc_start_of_slice == 1'b1) begin
                i_muxword_read_ptr <= '{default: 1'b0};
            end else if (i_muxword_read == 1'b1) begin
                i_muxword_read_ptr <= i_muxword_read_ptr_plus_1;
            end // if

        end // if
    end : OutputManager

endmodule : dsce_stream_fifo
