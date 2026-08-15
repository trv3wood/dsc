// ------------------------------------------------------------------------------------------------
//     COPYRIGHT © 2015-2023, TRILINEAR TECHNOLOGIES, INC.
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
//     DESCRIPTION : Line storage memory for the DSC Encoder core.  Includes the logic to
//                   reduce the accuracy of the stored pixels to match the accuracy of the
//                   attached decoder.
// ------------------------------------------------------------------------------------------------

// ----------------------------------------------
//  includes
// ----------------------------------------------
import dsce_defs_pkg::*;


// ----------------------------------------------
//  entity declaration
// ----------------------------------------------
module dsce_linemem
#(
    parameter int pMAX_SLICE_LINE_SIZE = 4096               // maximum slice line size
)
(
    // clock and control interface
    input  logic               dsc_clk,                     // DSC processing clock
    input  logic               dsc_reset_n,                 // DSC domain reset
    input  logic               dsc_pps_update,              // update pps parameters flag
    input  tDSC_PPS            cfg_pps,                     // parameter set output array
    input  logic               dsc_start_of_slice,          // start of a slice

    // line write interface
    input  logic               dsc_recon_valid_in,          // valid data in
    input  logic               dsc_recon_last_in,           // last group in a slice line
    input  tDSC_PIXEL          dsc_recon_in [2:0],          // reconstructed values

    // previous line read interface, timed to the output of the flatness block
    input  logic               dsc_input_valid_in,          // valid data in
    input  logic               dsc_input_last_in,           // last group in a line
    output tDSC_PIXEL          dsc_mmap_pixels_out [5:0],   // line out, mmap (left pixel = 0)
    output tDSC_PIXEL          dsc_ich_pixels_out [6:0],    // line out, ich (left pixel = 0)

    // memory BIST interface
    input  logic [11:0]        bist_sram_in,                // BIST input, 1 SRAM
    output logic [11:0]        bist_sram_out                // BIST output, 1 SRAM
);

    // ------------------------------------------------------------------------------------------------------------
    //                                          internal definitions
    // ------------------------------------------------------------------------------------------------------------

    // define the number of bits in the line buffer
    localparam int              kLINE_ADDR_BITS = $clog2(pMAX_SLICE_LINE_SIZE)-1;
    localparam int              kLINE_ADDR_MSB = kLINE_ADDR_BITS-1;

    // local parameter settings
    logic [4:0]                 i_linebuf_depth;
    logic [4:0]                 i_bits_per_component [1:0];
    logic [3:0]                 i_shift_y, i_shift_c;
    logic [15:0]                i_slice_width;

    // shifted input and staging for write
    logic [1:0]                 i_recon_valid;
    tDSC_PIXEL                  i_group_in [2:0];
    tDSC_PIXEL                  i_shift_group [2:0];
    logic [1:0]                 i_stage_valid;
    tDSC_PIXEL                  i_stage_group [2:0];
    logic [2:0]                 i_round_bit [2:0];

    // write controller
    enum {  eWS_WRITE_P0P1,
            eWS_WRITE_H2P0,
            eWS_WRITE_HOLD
    } i_write_state;

    logic                       i_write_enable;
    logic [95:0]                i_write_data;
    tDSC_PIXEL                  i_write_hold [1:0];

    logic [kLINE_ADDR_BITS-1:0] i_write_addr;
    logic [1:0]                 i_reset_write_address;

    // read controller
    enum {
        eRS_IDLE,
        eRS_INIT_LINE,
        eRS_FIRST_GROUP,
        eRS_READ_ONE_PAIR,
        eRS_READ_TWO_PAIR,
        eRS_ALMOST_LAST_1,
        eRS_LAST_GROUP_1,
        eRS_ALMOST_LAST_2,
        eRS_LAST_GROUP_2,
        eRS_LAST_GROUP_3,
        eRS_END_OF_LINE
    } i_read_state;

    logic [1:0]                 i_fill_read_enable;

    // buffer management
    logic [1:0]                 i_pipeline_phase;
    logic                       i_advance_read_buffer;
    logic                       i_load_buffer;
    tDSC_PIXEL                  i_ich_buffer [8:0];
    tDSC_PIXEL                  i_mmap_buffer [5:0];

    logic                       i_read_enable;
    logic [kLINE_ADDR_BITS-1:0] i_read_addr;
    logic [95:0]                i_read_data;
    tDSC_PIXEL                  i_adjusted_read_pixel [1:0];

    // slice position tracking
    logic                       i_start_of_slice_line;
    logic                       i_first_group_of_line;
    logic                       i_first_line_of_slice;
    logic [15:0]                i_slice_position;
    logic [2:0]                 i_end_of_slice_position_flag;


    // ------------------------------------------------------------------------------------------------------------
    //                                             tasks
    // ------------------------------------------------------------------------------------------------------------

    // ----------------------------------------------
    //  adjust the pixel colors for the depth of
    //  the line memory buffer.
    // ----------------------------------------------
    function automatic tDSC_PIXEL dsce_linemem_adjust (
        input tDSC_PIXEL   input_pixel,
        input logic [3:0]  shift_y,
        input logic [3:0]  shift_c
    );
        tDSC_PIXEL adjusted_pixel;

        adjusted_pixel.y  = input_pixel.y  << shift_y;
        adjusted_pixel.co = input_pixel.co << shift_c;
        adjusted_pixel.cg = input_pixel.cg << shift_c;

        return adjusted_pixel;
    endfunction : dsce_linemem_adjust


    // ------------------------------------------------------------------------------------------------------------
    //                                             processes
    // ------------------------------------------------------------------------------------------------------------

    // signal assignments
    always_comb begin : SignalMap
        // conditions for the start of a slice line
        i_start_of_slice_line = dsc_start_of_slice == 1'b1 || (dsc_recon_valid_in == 1'b1 && dsc_recon_last_in == 1'b1) ? 1'b1 : 1'b0;

        // group input adjusted for depth
        for (int sx = 0; sx < 3; sx++) begin : GroupReconLoop
            i_shift_group[sx].y  = i_group_in[sx].y  >> i_shift_y;
            i_shift_group[sx].co = i_group_in[sx].co >> i_shift_c;
            i_shift_group[sx].cg = i_group_in[sx].cg >> i_shift_c;

            i_round_bit[sx][0] = (i_shift_y == 4'd0) ? 1'b0 : i_group_in[sx].y[i_shift_y-4'd1];
            i_round_bit[sx][1] = (i_shift_c == 4'd0) ? 1'b0 : i_group_in[sx].co[i_shift_c-4'd1];
            i_round_bit[sx][2] = (i_shift_c == 4'd0) ? 1'b0 : i_group_in[sx].cg[i_shift_c-4'd1];
        end : GroupReconLoop

        // adjusted pixels from the read buffer
        i_adjusted_read_pixel[1] = dsce_linemem_adjust(tDSC_PIXEL'(i_read_data[95:48]), i_shift_y, i_shift_c);
        i_adjusted_read_pixel[0] = dsce_linemem_adjust(tDSC_PIXEL'(i_read_data[47:0]), i_shift_y, i_shift_c);

        // output map from the array (subset)
        dsc_mmap_pixels_out = i_mmap_buffer;
        dsc_ich_pixels_out = i_ich_buffer[6:0];

        // read enable for the SRAM
        i_read_enable = i_fill_read_enable[1];

        // detection of the end of the slice in the critical positions
        for (int px = 0; px < 3; px++) begin : PositionDetectLoop
            i_end_of_slice_position_flag[px] = ((i_slice_position + px[1:0]) == i_slice_width) ? 1'b1 : 1'b0;
        end : PositionDetectLoop

    end : SignalMap


    // -------------------------------------------------------
    //  local encoding parameters for timing/routing
    // -------------------------------------------------------
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : EncodeParameters
        if (dsc_reset_n == 1'b0) begin
            i_linebuf_depth <= 5'd0;
            i_bits_per_component <= '{default: 5'd0};
            i_shift_y <= 4'd0;
            i_shift_c <= 4'd0;
            i_slice_width <= 16'd0;

        end else begin

            // encode parameters
            if (dsc_pps_update == 1'b1) begin
                i_linebuf_depth <= (cfg_pps.linebuf_depth == 4'd0) ? 5'd16 : {1'b0, cfg_pps.linebuf_depth};

                if (cfg_pps.bits_per_component == 4'd0) begin
                    i_bits_per_component[kBPC_Y] <= 5'd16;
                    i_bits_per_component[kBPC_C] <= 5'd16;
                end else begin
                    i_bits_per_component[kBPC_Y] <= {1'b0, cfg_pps.bits_per_component};
                    i_bits_per_component[kBPC_C] <= {1'b0, cfg_pps.bits_per_component} + {4'h0, cfg_pps.convert_rgb};
                end // if

                i_slice_width <= cfg_pps.slice_width;
            end // if

            // shift constant local registers for timing
            i_shift_y <= (i_linebuf_depth > i_bits_per_component[kBPC_Y]) ? 4'd0 : (i_bits_per_component[kBPC_Y] - i_linebuf_depth);
            i_shift_c <= (i_linebuf_depth > i_bits_per_component[kBPC_C]) ? 4'd0 : (i_bits_per_component[kBPC_C] - i_linebuf_depth);

        end // if
    end : EncodeParameters


    // -------------------------------------------------------
    //  Reconstruction staging prior to the write to the
    //  line buffer.  The pipeline can be of arbitrary length
    //  since pixels are not required for an entire line
    //  period.  Recon required for decoder matching.
    // -------------------------------------------------------
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : WriteRecon
        if (dsc_reset_n == 1'b0) begin
            i_recon_valid <= 2'b00;
            i_group_in <= '{default: kDSC_PIXEL_INIT};
            i_stage_valid <= 2'b00;
            i_stage_group <= '{default: kDSC_PIXEL_INIT};

        end else begin

            // accept the values from the input interface
            if (dsc_recon_valid_in == 1'b1) begin
                i_recon_valid <= {dsc_recon_last_in, 1'b1};
                i_group_in <= dsc_recon_in;
            end else begin
                i_recon_valid <= 2'b00;
            end // if

            // write staging of recon data
            i_stage_valid <= i_recon_valid;
            for (int tx = 0; tx < 3; tx++) begin : StageGroupLoop
                if (i_recon_valid[0] == 1'b1) begin
                    i_stage_group[tx].y  <= i_shift_group[tx].y  + i_round_bit[tx][0];
                    i_stage_group[tx].co <= i_shift_group[tx].co + i_round_bit[tx][1];
                    i_stage_group[tx].cg <= i_shift_group[tx].cg + i_round_bit[tx][2];
                end // if
            end : StageGroupLoop

        end // if
    end : WriteRecon


    // -------------------------------------------------------
    //  Line memory write state machine.  Converts the 3
    //  pixel group into pairs for more efficient memory
    //  organization.
    // -------------------------------------------------------
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : WriteManager
        if (dsc_reset_n == 1'b0) begin
            i_write_state <= eWS_WRITE_P0P1;
            i_write_enable <= 1'b0;
            i_write_data <= '{default: kDSC_PIXEL_INIT};
            i_write_hold <= '{default: kDSC_PIXEL_INIT};

            i_write_addr <= '{default: 1'b0};
            i_reset_write_address <= 2'b00;

        end else begin

            // state based writes
            i_write_enable <= 1'b0;

            // force reset at the start of every slice
            if (dsc_start_of_slice == 1'b1) begin
                i_write_state <= eWS_WRITE_P0P1;
                i_write_enable <= 1'b0;

            end else begin

                case (i_write_state)
                    // write pixel 0, pixel 1, hold pixel 2
                    eWS_WRITE_P0P1:  begin
                        if (i_stage_valid[0] == 1'b1) begin
                            i_write_enable <= 1'b1;
                            i_write_data <= {i_stage_group[1], i_stage_group[0]};
                            i_write_hold <= '{kDSC_PIXEL_INIT, i_stage_group[2]};
                            i_write_state <= (i_stage_valid[1] == 1'b1) ? eWS_WRITE_HOLD : eWS_WRITE_H2P0;
                        end // if
                    end // eWS_WRITE_P0P1

                    // write hold pixel 2, pixel 0, hold pixels 1 and 2
                    eWS_WRITE_H2P0:  begin
                        if (i_stage_valid[0] == 1'b1) begin
                            i_write_enable <= 1'b1;
                            i_write_data <= {i_stage_group[0], i_write_hold[0]};
                            i_write_state <= eWS_WRITE_HOLD;
                            i_write_hold[1:0] <= i_stage_group[2:1];
                        end // if
                    end // eWS_WRITE_H2P0

                    // write hold pixels 1 and 2
                    eWS_WRITE_HOLD:  begin
                        i_write_enable <= 1'b1;
                        i_write_data <= {i_write_hold[1], i_write_hold[0]};
                        i_write_state <= eWS_WRITE_P0P1;
                    end // eWS_WRITE_HOLD

                    // default state for synthesis only
                    default:  begin
                        i_write_state <= eWS_WRITE_P0P1;
                        i_write_enable <= 1'b0;
                        i_write_data <= '{default: kDSC_PIXEL_INIT};
                        i_write_hold <= '{default: kDSC_PIXEL_INIT};
                    end // default
                endcase
            end // if


            // write address
            if (dsc_start_of_slice == 1'b1) begin
                i_write_addr <= '{default: 1'b0};
                i_reset_write_address <= 2'b00;

            end else begin
                if (i_stage_valid == 2'b11) begin
                    i_reset_write_address <= 2'b01;
                end else begin
                    i_reset_write_address <= {i_reset_write_address[0], 1'b0};
                end // if

                if (i_reset_write_address[1] == 1'b1) begin
                    i_write_addr[kLINE_ADDR_MSB-1:0] <= '{default: 1'b0};
                end else if (i_write_enable == 1'b1) begin
                    i_write_addr[kLINE_ADDR_MSB-1:0] <= i_write_addr[kLINE_ADDR_MSB-1:0] + kDSCE_ONE[kLINE_ADDR_MSB-1:0];
                end // if
            end // if

        end // if
    end : WriteManager


    // -------------------------------------------------------
    //  line memory read sequencer
    // -------------------------------------------------------
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : ReadLogic
        if (dsc_reset_n == 1'b0) begin
            i_read_state <= eRS_IDLE;
            i_fill_read_enable <= 2'b00;
            i_read_addr <= '{default: 1'b0};

        end else begin

            // default signal states
            i_fill_read_enable <= 2'b00;

            // read state machine
            if (i_start_of_slice_line == 1'b1) begin
                i_read_state <= eRS_INIT_LINE;
                i_fill_read_enable <= 2'b00;

            end else begin

                case (i_read_state)
                    //
                    //  the idle state is used after a reset or at the end of a slice
                    //
                    eRS_IDLE:  begin
                        i_fill_read_enable <= 2'b00;
                        i_read_state <= eRS_IDLE;
                    end // eRS_IDLE

                    //
                    //  line initialization state to prefill the output buffer before first group processing
                    //
                    eRS_INIT_LINE:  begin
                        if (i_read_addr[2:0] == 3'd4) begin
                            i_fill_read_enable <= 2'b00;
                            i_read_state <= eRS_FIRST_GROUP;
                        end else begin
                            i_fill_read_enable <= 2'b10;
                        end // if
                    end // eRS_INIT_LINE

                    //
                    // first group advances slightly differently from the others for ICH
                    //
                    eRS_FIRST_GROUP:  begin
                        if (i_advance_read_buffer == 1'b1) begin
                            i_read_state <= eRS_READ_ONE_PAIR;
                            i_fill_read_enable <= 2'b10;
                        end // if
                    end // eRS_FIRST_GROUP

                    //
                    // state to read an additional 1 pair from the buffer
                    //
                    eRS_READ_ONE_PAIR:  begin
                        if (i_advance_read_buffer == 1'b1) begin
                            case (i_end_of_slice_position_flag)
                                3'b001:  begin
                                    i_read_state <= eRS_LAST_GROUP_3;
                                    i_fill_read_enable <= 2'b00;
                                end // EOL, position 0

                                3'b010:  begin
                                    i_read_state <= eRS_ALMOST_LAST_1;
                                    i_fill_read_enable <= 2'b00;
                                end // EOL, position 1

                                3'b100:  begin
                                    i_read_state <= eRS_ALMOST_LAST_2;
                                    i_fill_read_enable <= 2'b00;
                                end // EOL, position 2

                                default:  begin
                                    i_read_state <= eRS_READ_TWO_PAIR;
                                    i_fill_read_enable <= 2'b10;
                                end // mid-slice
                            endcase
                        end else begin
                            i_fill_read_enable <= {i_fill_read_enable[0], 1'b0};
                        end // if
                    end // eRS_READ_ONE_PAIR

                    //
                    // state to read 2 additional pairs from the buffer
                    //
                    eRS_READ_TWO_PAIR:  begin
                        if (i_advance_read_buffer == 1'b1) begin
                            case (i_end_of_slice_position_flag)
                                3'b001:  begin
                                    i_read_state <= eRS_LAST_GROUP_3;
                                    i_fill_read_enable <= 2'b00;
                                end // EOL, position 0

                                3'b010:  begin
                                    i_read_state <= eRS_ALMOST_LAST_1;
                                    i_fill_read_enable <= 2'b10;
                                end // EOL, position 1

                                3'b100:  begin
                                    i_read_state <= eRS_ALMOST_LAST_2;
                                    i_fill_read_enable <= 2'b10;
                                end // EOL, position 2

                                default:  begin
                                    i_read_state <= eRS_READ_ONE_PAIR;
                                    i_fill_read_enable <= 2'b11;
                                end // mid-slice
                            endcase
                        end else begin
                            i_fill_read_enable <= {i_fill_read_enable[0], 1'b0};
                        end // if
                    end // eRS_READ_TWO_PAIR

                    //
                    // second to last group, last group has 1 pixel
                    //
                    eRS_ALMOST_LAST_1:  begin
                        if (i_advance_read_buffer == 1'b1) begin
                            i_read_state <= eRS_LAST_GROUP_1;
                        end // if
                    end // eRS_ALMOST_LAST_1

                    //
                    // last group, 1 pixel in the group
                    //
                    eRS_LAST_GROUP_1:  begin
                        if (i_advance_read_buffer == 1'b1) begin
                            i_read_state <= eRS_INIT_LINE;
                        end // if
                    end // eRS_LAST_GROUP_1

                    //
                    // second to last group, last group has 2 pixels
                    //
                    eRS_ALMOST_LAST_2:  begin
                        if (i_advance_read_buffer == 1'b1) begin
                            i_read_state <= eRS_LAST_GROUP_2;
                        end // if
                    end // eRS_ALMOST_LAST2

                    //
                    // last group, 2 pixels in the group
                    //
                    eRS_LAST_GROUP_2:  begin
                        if (i_advance_read_buffer == 1'b1) begin
                            i_read_state <= eRS_INIT_LINE;
                        end // if
                    end // eRS_LAST_GROUP_2

                    //
                    // last group, 3 pixels in the group
                    //
                    eRS_LAST_GROUP_3:  begin
                        if (i_advance_read_buffer == 1'b1) begin
                            i_read_state <= eRS_INIT_LINE;
                        end // if
                    end // eRS_LAST_GROUP_3

                    //
                    //  default state for synthesis-only
                    //
                    default:  begin
                        i_read_state <= eRS_IDLE;
                        i_fill_read_enable <= 2'b00;
                    end // default
                endcase
            end // if


            // read address manager
            if (i_start_of_slice_line == 1'b1) begin
                i_read_addr <= '{default: 1'b0};
            end else if (i_read_enable == 1'b1) begin
                i_read_addr <= i_read_addr + kDSCE_ONE[kLINE_ADDR_BITS-1:0];
            end // if

        end // if
    end : ReadLogic


    // -------------------------------------------------------
    //  output buffer memory (timing in NB30P96) - operates
    //  on the ICH buffer, MMAP is a subset
    // -------------------------------------------------------
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : BufferManager
        if (dsc_reset_n == 1'b0) begin
            i_ich_buffer <= '{default: kDSC_PIXEL_INIT};
            i_mmap_buffer <= '{default: kDSC_PIXEL_INIT};
            i_advance_read_buffer <= 1'b0;
            i_pipeline_phase <= 2'd0;
            i_load_buffer <= 1'b0;

        end else begin

            // signal the conditions to load the buffer
            if (i_fill_read_enable == 2'b11 || (i_fill_read_enable != 2'b00 && i_read_state == eRS_INIT_LINE)) begin
                i_load_buffer <= 1'b1;
            end else begin
                i_load_buffer <= 1'b0;
            end // if

            // create an advance buffer flag in phase S3
            if (dsc_input_valid_in == 1'b1 && dsc_input_last_in == 1'b0) begin
                i_pipeline_phase <= 2'd1;
            end else if (i_pipeline_phase != 2'd0) begin
                i_pipeline_phase <= i_pipeline_phase + 2'd1;
            end // if

            if (i_pipeline_phase == 2'd2) begin
                i_advance_read_buffer <= 1'b1;
            end else begin
                i_advance_read_buffer <= 1'b0;
            end // if

            //
            //  manage the ICH buffer contents based on 2 load signals
            //
            if (i_first_line_of_slice == 1'b1) begin
                i_ich_buffer <= '{default: kDSC_PIXEL_INIT};

            end else if (i_advance_read_buffer == 1'b1) begin
                case (i_read_state)
                    eRS_FIRST_GROUP:  begin
                        i_ich_buffer[8] <= i_adjusted_read_pixel[1];
                        i_ich_buffer[7] <= i_adjusted_read_pixel[0];
                        i_ich_buffer[6:0] <= i_ich_buffer[7:1];
                    end // eRS_FIRST_GROUP

                    eRS_READ_ONE_PAIR:  begin
                        case (i_end_of_slice_position_flag)
                            3'b001:  begin : Position_0_1P
                                i_ich_buffer[8] <= kDSC_PIXEL_INIT;
                                i_ich_buffer[7:0] <= i_ich_buffer[8:1];
                            end : Position_0_1P

                            3'b010:  begin : Position_1_1P
                                i_ich_buffer[8:7] <= '{default: kDSC_PIXEL_INIT};
                                i_ich_buffer[6:0] <= i_ich_buffer[8:2];
                            end : Position_1_1P

                            3'b100:  begin : Position_2_1P
                                i_ich_buffer[8] <= kDSC_PIXEL_INIT;
                                i_ich_buffer[7] <= i_adjusted_read_pixel[1];
                                i_ich_buffer[6] <= i_adjusted_read_pixel[0];
                                i_ich_buffer[5:0] <= i_ich_buffer[8:3];
                            end : Position_2_1P

                            default:  begin
                                i_ich_buffer[8] <= kDSC_PIXEL_INIT;
                                i_ich_buffer[7] <= i_adjusted_read_pixel[1];
                                i_ich_buffer[6] <= i_adjusted_read_pixel[0];
                                i_ich_buffer[5:0] <= i_ich_buffer[8:3];
                            end // default
                        endcase
                    end // eRS_READ_ONE_PAIR

                    eRS_READ_TWO_PAIR:  begin
                        case (i_end_of_slice_position_flag)
                            3'b001:  begin : Position_0_2P
                                i_ich_buffer[8] <= i_adjusted_read_pixel[1];
                                i_ich_buffer[7] <= i_adjusted_read_pixel[0];
                                i_ich_buffer[6:0] <= i_ich_buffer[7:1];
                            end : Position_0_2P

                            3'b010:  begin : Position_1_2P
                                i_ich_buffer[8] <= kDSC_PIXEL_INIT;
                                i_ich_buffer[7] <= i_adjusted_read_pixel[1];
                                i_ich_buffer[6] <= i_adjusted_read_pixel[0];
                                i_ich_buffer[5:0] <= i_ich_buffer[7:2];
                            end : Position_1_2P

                            3'b100:  begin : Position_2_2P
                                i_ich_buffer[8] <= kDSC_PIXEL_INIT;
                                i_ich_buffer[7] <= kDSC_PIXEL_INIT;
                                i_ich_buffer[6] <= i_adjusted_read_pixel[1];
                                i_ich_buffer[5] <= i_adjusted_read_pixel[0];
                                i_ich_buffer[4:0] <= i_ich_buffer[7:3];
                            end : Position_2_2P

                            default:  begin
                                i_ich_buffer[8] <= kDSC_PIXEL_INIT;
                                i_ich_buffer[7] <= kDSC_PIXEL_INIT;
                                i_ich_buffer[6] <= i_adjusted_read_pixel[1];
                                i_ich_buffer[5] <= i_adjusted_read_pixel[0];
                                i_ich_buffer[4:0] <= i_ich_buffer[7:3];
                            end // default
                        endcase
                    end // eRS_READ_TWO_PAIR

                    default:  begin
                        // no shift in the "almost" or "last" states
                        i_ich_buffer <= i_ich_buffer;
                    end // default
                endcase
            end else if (i_load_buffer == 1'b1) begin
                if (i_read_state == eRS_INIT_LINE) begin
                    i_ich_buffer[7] <= i_adjusted_read_pixel[1];
                    i_ich_buffer[6] <= i_adjusted_read_pixel[0];
                    i_ich_buffer[5:0] <= i_ich_buffer[7:2];
                end else if (i_read_state != eRS_FIRST_GROUP) begin
                    i_ich_buffer[8] <= i_adjusted_read_pixel[1];
                    i_ich_buffer[7] <= i_adjusted_read_pixel[0];
                end // if
            end // if


            //
            //  MMAP buffer management
            //
            if (i_first_line_of_slice == 1'b1) begin
                i_mmap_buffer <= '{default: kDSC_PIXEL_INIT};
            end else if (i_advance_read_buffer == 1'b1) begin
                case (i_read_state)
                    eRS_FIRST_GROUP:  begin
                        i_mmap_buffer <= i_ich_buffer[6:1];
                    end // eRS_FIRST_GROUP

                    eRS_READ_ONE_PAIR:  begin
                        case (i_end_of_slice_position_flag)
                            3'b001:  begin
                                i_mmap_buffer[5] <= i_ich_buffer[7];
                                i_mmap_buffer[4:0] <= i_ich_buffer[7:3];
                            end // position 1

                            3'b010:  begin
                                i_mmap_buffer[5:0] <= i_ich_buffer[8:3];
                            end // position 2

                            3'b100:  begin
                                i_mmap_buffer[5:0] <= i_ich_buffer[8:3];
                            end // position 3

                            default:  begin
                                i_mmap_buffer <= i_ich_buffer[8:3];
                            end // default
                        endcase
                    end // eRS_READ_ONE_PAIR

                    eRS_READ_TWO_PAIR:  begin
                        case (i_end_of_slice_position_flag)
                            3'b001:  begin
                                i_mmap_buffer[5] <= i_ich_buffer[7];
                                i_mmap_buffer[4:0] <= i_ich_buffer[7:3];
                            end // position 1

                            3'b010:  begin
                                i_mmap_buffer[5] <= i_adjusted_read_pixel[0];
                                i_mmap_buffer[4:0] <= i_ich_buffer[7:3];
                            end // position 2

                            3'b100:  begin
                                i_mmap_buffer[5] <= i_adjusted_read_pixel[0];
                                i_mmap_buffer[4:0] <= i_ich_buffer[7:3];
                            end // position 3

                            default:  begin
                                i_mmap_buffer[5] <= i_adjusted_read_pixel[0];
                                i_mmap_buffer[4:0] <= i_ich_buffer[7:3];
                            end // default
                        endcase
                    end // eRS_READ_TWO_PAIR

                    eRS_ALMOST_LAST_1:  begin
                        i_mmap_buffer[5:3] <= {i_ich_buffer[6], i_ich_buffer[6], i_ich_buffer[6]};
                        i_mmap_buffer[2:0] <= i_ich_buffer[6:4];
                    end // eRS_ALMOST_LAST_2

                    eRS_ALMOST_LAST_2:  begin
                        i_mmap_buffer[5:4] <= {i_ich_buffer[6], i_ich_buffer[6]};
                        i_mmap_buffer[3:0] <= i_ich_buffer[6:3];
                    end // eRS_ALMOST_LAST_2

                    default:  begin
                        // no shift
                        i_mmap_buffer <= i_mmap_buffer;
                    end // default
                endcase
            end else if (i_load_buffer == 1'b1 && i_read_state == eRS_INIT_LINE) begin
                case (i_read_addr[1:0])
                    2'b01:  begin  : FirstInitRead
                        i_mmap_buffer <= '{kDSC_PIXEL_INIT,
                                           kDSC_PIXEL_INIT,
                                           i_adjusted_read_pixel[1],
                                           i_adjusted_read_pixel[0],
                                           i_adjusted_read_pixel[0],
                                           i_adjusted_read_pixel[0]};
                    end : FirstInitRead

                    2'b10:  begin  : SecondInitRead
                        i_mmap_buffer[5:4] <= '{i_adjusted_read_pixel[1], i_adjusted_read_pixel[0]};
                    end : SecondInitRead

                    default:  i_mmap_buffer <= i_mmap_buffer;
                endcase
            end // if

        end // if
    end : BufferManager


    // -------------------------------------------------------
    //  track the position in the slice for pixel selection
    // -------------------------------------------------------
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : PositionTracker
        if (dsc_reset_n == 1'b0) begin
            i_first_group_of_line <= 1'b0;
            i_slice_position <= 16'd0;
            i_first_line_of_slice <= 1'b0;

        end else begin

            // detect the first line of the slice
            if (i_start_of_slice_line == 1'b1) begin
                i_first_group_of_line <= 1'b1;
            end else if (i_advance_read_buffer == 1'b1) begin
                i_first_group_of_line <= 1'b0;
            end // if

            if (i_start_of_slice_line == 1'b1) begin
                i_slice_position <= 16'd8;
            end else begin
                if (i_advance_read_buffer == 1'b1) begin
                    if (i_first_group_of_line == 1'b1) begin
                        i_slice_position <= 16'd9;
                    end else begin
                        i_slice_position <= i_slice_position + 16'd3;
                    end // if
                end // if
            end // if

            // the first line of each slice should output 0
            if (dsc_start_of_slice == 1'b1) begin
                i_first_line_of_slice <= 1'b1;
            end else if (dsc_input_valid_in == 1'b1 && dsc_input_last_in == 1'b1) begin
                i_first_line_of_slice <= 1'b0;
            end // if

        end // if
    end : PositionTracker


    // ------------------------------------------------------------------------------------------------------------
    //                                             buffer memory
    // ------------------------------------------------------------------------------------------------------------
    gram_bist_1r1w
    # (
        .pADDRESS_BITS (kLINE_ADDR_BITS),
        .pDATA_BITS    (96)
    ) line_buffer_inst
    (
        // port a, read port
        .clk_r    (dsc_clk),
        .en_r     (i_read_enable),
        .addr_r   (i_read_addr),
        .data_r   (i_read_data),
        // port b, write port
        .clk_w    (dsc_clk),
        .addr_w   (i_write_addr),
        .we_w     (i_write_enable),
        .data_w   (i_write_data),
        // bist interface
        .bist_in  (bist_sram_in),
        .bist_out (bist_sram_out)
    );

endmodule : dsce_linemem

