
** SEE TEST MODEL NOTES AT BOTTOM OF THIS DOCUMENT **


How to use Display Stream Compression (DSC) algorithm model
--------------------------------------------------------------

1)  The typical usage for the DSC model is:

DSC -F <configuration_file>

The configuration_file contains a list of options for the model.  An example is given in test.cfg that is included with the model.  The parameters are listed in the section below.


2)  The configuration file can specify whether the DSC executable behaves as an encoder, decoder, or both using the FUNCTION parameter.  If the FUNCTION is 1, the executable will encode to an output bitstream that is stored in a file (or files) with the same base name and a .dsc extension.  If the FUNCTION is set to 2, the executable will decode a .dsc file (or files) specified.  If .dpx or .ppm files are listed in the input list file instead of .dsc files, the .dsc files will be decoded and PSNR will be calculated as well.  If the FUNCTION is 0, the executable will encode and decode, but no bitstream file will be generated.

A list file (SRC_LIST) is required to indicate which source files to encode.  The list file is also required in decode mode to indicate which .dsc files to decode.  The list file may contain full pathnames.  By default, the model outputs to the current working directory; however, an alternative OUT_DIR can be specified in the config file.  If the same list file is used for encoding and decoding, the PSNR will be calculated between the source file and decoded output.

Parameters besides SRC_LIST and FUNCTION are ignored for the decoder, since the configuration is stored as part of the bitstream file.


3)  Output files to the current working directory:
	- log.txt (or filename specified as LOG_FILENAME) provides PSNR information
	- <name>.ref.dpx is the converted DPX file that represents the encoder input
	- <name>.out.dpx is the decoder output
        - <name>.dsc is the output bitstream if FUNCTION = 1 or if DSC_FILE_OUTPUT = 1


4)  The included EXE file is compiled under Win32, and some users may experience memory allocation errors for very large pictures.  Compiling the code using "x64" platform target under Windows or compiling under 64-bit Linux will fix these errors.



Configuration file paramters - general 
---------------------------------------

FUNCTION - 0=encode and decode (no bitstream file is produced), 1=encode only, 2=decode only, 3=print PPS only (no encode or decode)

INCLUDE - Several different include files are used for different rate control settings.  The distribution has recommended settings for 8, 10, and 12 bpc and 8 and 12 bpp.

PRINT_PPS_FORMAT - specifies format when printing PPS output (format 1 or format 2)


Configuration file paramters - encoding 
----------------------------------------

The following parameters control the encoding and are required to be specified if encoding is taking place.

BITS_PER_PIXEL - The constant bit rate of the output stream (bits/pixel).  Can be specified as a floating point number.

BITS_PER_COMPONENT - The input image files will be converted to this number of bits per component if they aren't already in that format and coded using this value for bpc.

SIMPLE_422 - If set to 1, USE_YUV_INPUT must be set 1.  The input files will be converted to YCbCr 4:2:2 (if they aren't already in that format) and coded using the Simple 4:2:2 mode described in the spec.

NATIVE_422 - If set to 1, USE_YUV_INPUT must be set to 1. The input files will be converted to YCbCr 4:2:2 (if they aren't already in that format) and coded using the Native 4:2:2 mode described in the spec.

NATIVE_420 - If set to 1, USE_YUV_INPUT must be set to 1. The input files will be converted to YCbCr 4:2:0 (if they aren't already in that format) and coded using the Native 4:2:0 mode described in the spec.

VBR_ENABLE - Enable VBR mode.

USE_YUV_INPUT - If set 0, the input DPX files will be converted to RGB (if they aren't already in that format) and coded that way.  If set to 1, the input DPX files will be converted to YCbCr (if the aren't already in that format) and coded that way.

SLICE_WIDTH - If specified, sets the width of the rectangular slices.  If unspecified, slices are assumed to be the full picture width.

SLICE_HEIGHT - If specified, sets the height of the rectangular slices.  If unspecified, slices are assumed to be the full picture height.

AUTO_SLICE_HEIGHT_ALGORITHM - 0 => Use slice height specified in SLICE_HEIGHT; 1 => Find largest slice height >=96 that minimizes padding lines; 2 => Find smallest slice height >=96 that minimizes padding lines.

BLOCK_PRED_ENABLE - Enables block prediction with a range of 8 positions.  A value of 0 disables block prediction.  Block prediction helps certain pathological images but can have a slight negative effect on "typical" content.

LINE_BUFFER_BPC - From 8-17, specifies the number of bits/pixel in the line buffer used to store the previous line's samples.

DSC_VERSION_MINOR - Set to 1 for DSC 1.1 mode or 2 for DSC 1.2/1.2a/1.2b mode (see DSC specifcation for more information)


Configuration file paramters - file I/O 
----------------------------------------

SRC_LIST - Specifies a text file that contains the image or bitstream files to be processed (one file name per line).

OUT_DIR - Destination directory for output bitstreams and image files

PIC_WIDTH - Specifies the picture width when reading raw YUV files

PIC_HEIGHT - Specifies the picture height when reading raw YUV files

YUV_FILE_FORMAT - Specifies the input/output format for raw YUV files (0 = planar 4:2:0 YUV, 1 = interleaved 4:2:2 UYVY)

YUV_FILE_OUTPUT - Set to 1 to output .YUV files in 4:2:0 or 4:2:2 mode (output is only generated if it matches the coding pixel format)

PPM_FILE_OUTPUT - Set to 1 to output PPM files (YCbCr, 4:2:2, and 4:2:0 are converted to RGB)

DPX_FILE_OUTPUT - Set to 1 to output (non-HDR) DPX files

HDR_DPX_FILE_OUTPUT - Set to 1 to output HDR DPX files (conforming to SMPTE ST 268-2). Note that only one of DPX_FILE_OUTPUT and HDR_DPX_FILE_OUTPUT can be selected.

TRANSFER_FUNCTION - Specify the transfer function for the HDR DPX output files (most common are 5=>BT.709, 6=>xvYCC, 10=>BT.2020/NCL/gamma, 11=>BT.2020/CL/gamma, 12=>BT.2100/NCL/PQ, 13=>BT.2100/CI/PQ, 14=>BT.2100/NCL/HLG, 15=>BT.2100/CI/HGL, 16=>P3 gamma 2.8, 17=>sRGB)

COLORIMETRY - Specify the colorimetry for the HDR DPX output files (most common are 3=>BT.709, 4=>BT.601/NTSC, 5=>BT.601/PAL, 7=>BT.2020/BT.2100, 8=>SMPTE ST 2113 P3D65, 9=>ST 2113 P3DCI, 10=>ST 2113 P3D60, 11=>ACES)

COLOR_DIFF_SITING - Specify 4:2:0 color difference (chroma) siting: 0=>cosited horizontally & vertically, 1=>interstitial horizontally and cosited vertically, 2=>cosited horizontally and interstitial vertically, 3=>interstitial horizontally & vertically

DSC_FILE_OUTPUT - Set to 1 to output .dsc bitsream files when FUNCTION = 0

BIT_DEPTH_CONV_ROUNDING - 0 = bit depth conversions from source images are done using shifts and truncation only (default, same as 1.2a model)
                          1 = bit depth conversions add 0.5 to each sample for lower->higher depth and round for higher->lower depth 


Configuration file paramters - rate control 
--------------------------------------------

GENERATE_RC_PARAMETERS - 0 = explictly specify rate control parameters for encoding in cfg file (see list below); 1 = automatically configure rate control parameters using VESA guidance. Note that the automatically-generated values are suitable for typical use cases (8-12bpc, slices > 16000 pixels) and customization might be needed if assumptions are violated. 2 = use automatic configuration for rate control parameters and adjust max_QP[14] if an overflow warning would otherwise be generated

List of rate control parameters:
RC_OFFSET, RC_MINQP[], RC_MAX_QP[], RC_BUF_THRESH[], RC_MODEL_SIZE, FIRST_LINE_BPG_OFFSET, SECOND_LINE_BPG_OFFSET, SECOND_LINE_OFFSET_ADJ, INITIAL_FULLNESS_OFFSET, INITIAL_DELAY, RC_TGT_OFFSET_HI, RC_TGT_OFFSET_LO, RC_EDGE_FACTOR, RC_QUANT_INCR_LIMIT0, RC_QUANT_INCR_LIMIT1, FLATNESS_MIN_QP, FLATNESS_MAX_QP, FLATNESS_DET_THRESH


Configuration file paramters - (non-HDR) DPX 
---------------------------------------------
The model supports reading and writing 8, 10, 12, and 16-bit DPX files.  We attempted to follow the SMPTE ST 268-1 specification as closely as possible.  Although some testing has been done to try to ensure compatibility, there may be some issues reading certain types of DPX files.  The written DPX files aren't guaranteed to work with any specific DPX reader software.

1)  See the included DPX application note for information on the DPX standard and compatibility as well as the config file options for DPX.

2)  We always output a .ref.dpx file that contains the image the codec is trying to code.  If your reader doesn't read this file, it won't be able to read the .out.dpx file either.  If you know your DPX reader ordinarily works with the .ref.dpx file, but some particular source image causes problems, there may be a compatibility issue between that source image and the DPX reader.

3)  The model can also input and output PPM format. Set PPM_FILE_OUTPUT to 1 to output PPM files.


The following options relate to (non-HDR) DPX I/O:

SWAP_R_AND_B - Allows the swapping of the R & B components of the input files if the (non-HDR) DPX file input has incorrect component ordering.

DPXR_FORCE_BE - Interpret the image data words as big-endian for (non-HDR) DPX image files that are read.

DPXR_PAD_ENDS - 0 = (Non-HDR) DPX reader assumes samples are packed tightly with no special treatment for line ends; 1 = Lines are assumed to always begin on a 32-bit data word boundary, so data words at the ends of lines are assumed to be padded if needed.

DPXR_DATUM_ORDER - 0 = (Non-HDR) DPX reader assumes samples are packed within 32-bit words starting from the lsb (right-to-left); 1 = Samples are packed within 32-bit words starting from the msb (left-to-right)

SWAP_R_AND_B_OUT - Allows the swapping of the R & B components of the output files if the (non-HDR) DPX viewer has incorrect component ordering.

DPXW_PAD_ENDS - 0 = (Non-HDR) DPX writer packs samples tightly with no special treatment for line ends; 1 = Lines are assumed to always begin on a 32-bit data word boundary, so data words at the ends of lines are padded if needed.

DPXW_DATUM_ORDER - 0 = (Non-HDR) DPX writer packs samples within 32-bit words starting from the lsb (right-to-left); 1 = Samples are packed within 32-bit words starting from the msb (left-to-right)

DPXW_FORCE_PACKING - 0 = (Non-HDR) DPX writer packs 10/12-bpc samples tightly with no padding; 1 = (Non-HDR) DPX writer packs 10/12-bpc samples using "Method A" (described in SMPTE ST 268-1); 2 = (Non-HDR) DPX writer packs 10/12-bpc samples using "Method B" (described in SMPTE ST 268-1)

DPXW_BYTE_SWAP - 0 = Write (non-HDR) DPX file as big-endian file (preferred for interoperability); 1 = Write (non-HDR) DPX file as little-endian



The following features are added to DSC 1.2:
--------------------------------------------

-  Support for YUV 4:2:0 input/output .YUV files (only single frames currently supported).  Files with >8 BPC use 16-bit LE packing.
-  Support for native 420 and native 422 modes (set NATIVE_420 or NATIVE_422 equal to 1 in the config file).  Note that USE_YUV_INPUT is required to be 1 and SIMPLE_422 is required to be 0 for these modes.
-  Support for 14 & 16 bpc
-  Some minor modifications for flatness, rate control.

Brief description of parameters:

- SECOND_LINE_BPG_OFFSET - Specifies BPG offset for 2nd line (used in 4:2:0 mode)

- SECOND_LINE_OFFSET_ADJ - Specifies a portion of the initial offset to use for the 2nd line (used in 4:2:0 mode)

- DSC_VERSION_MINOR (default 2) - Set minor version to 1 to generate a DSC 1.1 compliant output.

- PIC_WIDTH, PIC_HEIGHT - Picture width & height for YUV input



The following features are added to DSC 1.2a:
---------------------------------------------

- FULL_ICH_ERR_PRECISION - 0 = truncate errors in encoder ICH decision, 1 = use full precision for errors in encoder ICH decision

- Note that Native 4:2:0 was not correctly supported in DSC 1.2 and was deprecated; the DSC 1.2a model provides a corrected implementation for Native 4:2:0.
