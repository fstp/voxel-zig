/* One translation unit for the stb_image implementation. The Zig side only
 * declares the three entry points it uses (src/gfx/stb.zig).
 *
 * Do NOT define STBI_NO_STDIO here: stbi_load() (the path-based loader) is
 * inside `#ifndef STBI_NO_STDIO` in stb_image.h, and defining it - even as 0 -
 * removes the function and the link fails with "undefined symbol: stbi_load". */
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
