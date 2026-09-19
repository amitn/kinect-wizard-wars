// Plain g++ test for the webcam pixel conversions (no Godot, no camera):
//   g++ -std=c++17 -O2 -Wall -Isrc tests/webcam_convert_test.cpp -o webcam_convert_test && ./webcam_convert_test
#include "webcam_convert.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>

using namespace wizardwars::webcam;

static int failures = 0;

static void check(bool ok, const char *what) {
	std::printf("%s  %s\n", ok ? "ok  " : "FAIL", what);
	if (!ok) {
		failures++;
	}
}

static bool near(const uint8_t *rgb, int r, int g, int b, int tolerance = 3) {
	return std::abs(rgb[0] - r) <= tolerance && std::abs(rgb[1] - g) <= tolerance && std::abs(rgb[2] - b) <= tolerance;
}

int main() {
	uint8_t px[3];

	// BT.601 limited range reference colours.
	yuv_to_rgb(16, 128, 128, px);
	check(near(px, 0, 0, 0), "yuv black");
	yuv_to_rgb(235, 128, 128, px);
	check(near(px, 255, 255, 255), "yuv white");
	yuv_to_rgb(81, 90, 240, px);
	check(near(px, 255, 0, 0), "yuv red");
	yuv_to_rgb(145, 54, 34, px);
	check(near(px, 0, 255, 0), "yuv green");
	yuv_to_rgb(41, 240, 110, px);
	check(near(px, 0, 0, 255), "yuv blue");
	yuv_to_rgb(0, 0, 0, px);
	check(px[0] == 0 || px[0] < 140, "yuv out-of-range input stays clamped");

	// YUY2: a 4x2 image with padding in the stride; left half red, right half blue.
	{
		const int w = 4, h = 2, stride = 12;
		uint8_t src[stride * h];
		std::memset(src, 0x55, sizeof(src));
		for (int row = 0; row < h; row++) {
			uint8_t *s = src + row * stride;
			s[0] = 81; s[1] = 90; s[2] = 81; s[3] = 240;      // two red pixels
			s[4] = 41; s[5] = 240; s[6] = 41; s[7] = 110;     // two blue pixels
		}
		uint8_t out[w * h * 3];
		yuy2_to_rgb(src, stride, w, h, out);
		check(near(out, 255, 0, 0) && near(out + 3, 255, 0, 0), "yuy2 left pair is red");
		check(near(out + 6, 0, 0, 255) && near(out + 9, 0, 0, 255), "yuy2 right pair is blue");
		check(near(out + (w * 3), 255, 0, 0), "yuy2 second row honours the stride");
	}

	// NV12: 4x2, top row red / bottom row red (one chroma row serves both), stride 8.
	{
		const int w = 4, h = 2, stride = 8;
		uint8_t src[stride * 3];
		std::memset(src, 0x55, sizeof(src));
		for (int row = 0; row < h; row++) {
			for (int x = 0; x < w; x++) {
				src[row * stride + x] = x < 2 ? 81 : 145;
			}
		}
		uint8_t *uv = src + stride * h;
		uv[0] = 90; uv[1] = 240;   // red
		uv[2] = 54; uv[3] = 34;    // green
		uint8_t out[w * h * 3];
		nv12_to_rgb(src, stride, w, h, out);
		check(near(out, 255, 0, 0) && near(out + 3, 255, 0, 0), "nv12 left pair is red");
		check(near(out + 6, 0, 255, 0) && near(out + 9, 0, 255, 0), "nv12 right pair is green");
		check(near(out + w * 3 + 6, 0, 255, 0), "nv12 second row shares the chroma row");
	}

	// BGRX, bottom-up: the top row is the last one in memory and the pitch is negative.
	{
		const int w = 2, h = 2, stride = 8;
		const uint8_t src[stride * h] = {
			// memory row 0 = image bottom row: blue, blue
			255, 0, 0, 0, 255, 0, 0, 0,
			// memory row 1 = image top row: red, green
			0, 0, 255, 0, 0, 255, 0, 0,
		};
		uint8_t out[w * h * 3];
		bgrx_to_rgb(src + stride * (h - 1), -stride, w, h, out);
		check(near(out, 255, 0, 0, 0) && near(out + 3, 0, 255, 0, 0), "bgrx bottom-up: top row red, green");
		check(near(out + 6, 0, 0, 255, 0) && near(out + 9, 0, 0, 255, 0), "bgrx bottom-up: bottom row blue");
		bgrx_to_rgb(src, stride, w, h, out);
		check(near(out, 0, 0, 255, 0), "bgrx top-down reads memory order");
	}

	// RGB24 / BGR24 with stride padding.
	{
		const int w = 2, h = 1, stride = 8;
		const uint8_t src[stride] = { 10, 20, 30, 40, 50, 60, 0x55, 0x55 };
		uint8_t out[w * 3];
		rgb24_to_rgb(src, stride, w, h, false, out);
		check(out[0] == 10 && out[2] == 30 && out[3] == 40, "rgb24 copies");
		rgb24_to_rgb(src, stride, w, h, true, out);
		check(out[0] == 30 && out[2] == 10 && out[3] == 60, "bgr24 swaps");
	}

	// MJPG without Huffman tables gets the standard ones, exactly once, before the scan.
	{
		check(sizeof(JPEG_STANDARD_DHT) == 2 + 0x01A2, "standard DHT segment is 420 bytes");
		int counted = 0;
		for (int table = 0, at = 4; table < 4; table++) {
			int symbols = 0;
			for (int i = 1; i <= 16; i++) {
				symbols += JPEG_STANDARD_DHT[at + i];
			}
			at += 17 + symbols;
			counted = at;
		}
		check(counted == static_cast<int>(sizeof(JPEG_STANDARD_DHT)), "the four tables' code counts add up to the segment length");

		const uint8_t bare[] = { 0xFF, 0xD8, 0xFF, 0xDB, 0x00, 0x04, 1, 2, 0xFF, 0xC0, 0x00, 0x03, 9, 0xFF, 0xDA, 0x00, 0x02, 7, 7, 0xFF, 0xD9 };
		std::vector<uint8_t> fixed;
		jpeg_with_tables(bare, sizeof(bare), fixed);
		check(fixed.size() == sizeof(bare) + sizeof(JPEG_STANDARD_DHT), "tables inserted into a bare frame");
		check(fixed[13] == 0xFF && fixed[14] == 0xC4, "tables sit right before the scan");
		check(fixed[13 + sizeof(JPEG_STANDARD_DHT)] == 0xFF && fixed[14 + sizeof(JPEG_STANDARD_DHT)] == 0xDA, "the scan follows the tables");

		std::vector<uint8_t> again;
		jpeg_with_tables(fixed.data(), fixed.size(), again);
		check(again == fixed, "a frame that has tables is left alone");

		const uint8_t junk[] = { 1, 2, 3, 4, 5 };
		jpeg_with_tables(junk, sizeof(junk), again);
		check(again.size() == sizeof(junk), "data that is not a JPEG passes through");
	}

	std::printf(failures == 0 ? "ALL PASSED\n" : "%d FAILED\n", failures);
	return failures == 0 ? 0 : 1;
}
