// ------------------------------------------------------------------------------------------------
//     COPYRIGHT © 2017-2023, TRILINEAR TECHNOLOGIES, INC.
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
//     DESCRIPTION : Display Stream Compression encoder register constants.
// ------------------------------------------------------------------------------------------------


// ------------------------------------------------------------------------------------------------
//                        Register Definitions
// ------------------------------------------------------------------------------------------------
package dsce_regdefs_pkg;

    // ----------------------------------------------
    //  register map
    // ----------------------------------------------

    // ----- basic fields ----- //
    localparam logic [11:0] kDSCE_ENCODER_COMMAND        = 12'h000;
    localparam logic [11:0] kDSCE_ENCODER_ACTIVE         = 12'h004;
    localparam logic [11:0] kDSCE_PIXELS_PER_CYCLE       = 12'h008;
    localparam logic [11:0] kDSCE_LOCK_TO_INPUT_VSYNC    = 12'h00c;
    localparam logic [11:0] kDSCE_ENCODER_TIMEOUT_COUNT  = 12'h010;
    localparam logic [11:0] kDSCE_RESERVED_014           = 12'h014;
    localparam logic [11:0] kDSCE_RESERVED_018           = 12'h018;
    localparam logic [11:0] kDSCE_RESERVED_01C           = 12'h01c;
    localparam logic [11:0] kDSCE_ENCODED_FRAME_COUNT    = 12'h020;
    localparam logic [11:0] kDSCE_FORCE_ENABLE           = 12'h024;
    localparam logic [11:0] kDSCE_QP_OVERRIDE            = 12'h028;
    localparam logic [11:0] kDSCE_USEC_CLOCK_DIVIDER     = 12'h02c;
    localparam logic [11:0] kDSCE_OUTPUT_MODE            = 12'h030;
    localparam logic [11:0] kDSCE_HOST_TIMER             = 12'h034;

    // ----- slice control ----- //
    localparam logic [11:0] kDSCE_SLICE_WIDTH_ALIGNMENT  = 12'h040;
    localparam logic [11:0] kDSCE_SLICES_PER_LINE        = 12'h044;
    localparam logic [11:0] kDSCE_SLICES_PER_PROCESSOR   = 12'h048;
    localparam logic [11:0] kDSCE_SLICE_PROCESSOR_COUNT  = 12'h04c;
    localparam logic [11:0] kDSCE_SLICE_BUFFER_DEPTH     = 12'h050;

    // ----- rate control ----- //
    localparam logic [11:0] kDSCE_MAX_BITS_PER_GROUP     = 12'h060;
    localparam logic [11:0] kDSCE_TRAILING_BITS_FLAG     = 12'h064;
    localparam logic [11:0] kDSCE_CHUNK_SIZE             = 12'h068;

    // ----- interrupt control ----- //
    localparam logic [11:0] kDSCE_INTERRUPT_ENABLE       = 12'h080;
    localparam logic [11:0] kDSCE_INTERRUPT_CAUSE        = 12'h084;
    localparam logic [11:0] kDSCE_INTERRUPT_STATE        = 12'h088;
    localparam logic [11:0] kDSCE_FRAME_INTERRUPT_COUNT  = 12'h08c;

    // ----- core features and revision ----- //
    localparam logic [11:0] kDSCE_CORE_FEATURES          = 12'h0f8;
    localparam logic [11:0] kDSCE_CORE_REVISION          = 12'h0fc;

    // ----- picture parameter set ----- //
    localparam logic [11:0] kDSCE_PPS_TABLE_DATA         = 12'h100;
    localparam logic [11:0] kDSCE_PPS_TABLE_ENTRY        = 12'h104;
    localparam logic [11:0] kDSCE_PPS_TABLE_COMMIT       = 12'h108;


    // ----------------------------------------------
    //  interrupt bit field definitions
    // ----------------------------------------------
    localparam int kDSCE_INT_SLICE_ERROR     = 32'h0000_0040;
    localparam int kDSCE_INT_TIMER           = 32'h0000_0020;
    localparam int kDSCE_INT_FRAME_COUNT     = 32'h0000_0010;
    localparam int kDSCE_INT_RATE_ERROR      = 32'h0000_0008;
    localparam int kDSCE_INT_END_OF_FRAME    = 32'h0000_0004;
    localparam int kDSCE_INT_END_OF_SLICE    = 32'h0000_0002;
    localparam int kDSCE_INT_ENCODER_TIMEOUT = 32'h0000_0001;

    localparam int kDSCE_INT_ENABLE_ALL      = 32'hffff_ffff;
    localparam int kDSCE_INT_DISABLE_ALL     = 32'h0000_0000;

    // ----------------------------------------------
    //  output mode settings
    // ----------------------------------------------
    localparam logic [2:0] kDSCE_OUTPUT_8_BIT       = 3'd0;
    localparam logic [2:0] kDSCE_OUTPUT_16_BIT      = 3'd1;
    localparam logic [2:0] kDSCE_OUTPUT_24_BIT      = 3'd2;
    localparam logic [2:0] kDSCE_OUTPUT_32_BIT      = 3'd3;
    localparam logic [2:0] kDSCE_OUTPUT_48_BIT      = 3'd4;
    localparam logic [2:0] kDSCE_OUTPUT_64_BIT      = 3'd5;
    localparam logic [2:0] kDSCE_OUTPUT_96_BIT      = 3'd6;
    localparam logic [2:0] kDSCE_OUTPUT_192_BIT     = 3'd7;

endpackage : dsce_regdefs_pkg

