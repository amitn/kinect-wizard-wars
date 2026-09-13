// Native test for BodyTracker with synthetic depth frames. No SDK, no Godot.
//   g++ -std=c++17 -O2 -Isrc tests/body_tracker_test.cpp src/body_tracker.cpp -o body_tracker_test && ./body_tracker_test
#include "body_tracker.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

using namespace wizardwars;

namespace {

const int W = 320, H = 200;
const float FX = 150.0f, FY = 150.0f, CX = W / 2.0f, CY = H / 2.0f;
int failures = 0;

#define CHECK(cond, msg)                                              \
	do {                                                              \
		if (!(cond)) {                                                \
			std::printf("FAIL: %s (%s:%d)\n", msg, __FILE__, __LINE__); \
			failures++;                                               \
		} else {                                                      \
			std::printf("ok:   %s\n", msg);                           \
		}                                                             \
	} while (0)

struct Scene {
	std::vector<uint16_t> depth;
	Scene() : depth(W * H, 0) {
		// Back wall at 3.5 m; a flat floor 0.9 m below the camera, so a floor
		// pixel in row v lies at z = 0.9 * FY / (v - CY).
		for (int v = 0; v < H; v++) {
			for (int u = 0; u < W; u++) {
				float floor_z = v > CY ? std::min(3.5f, 0.9f * FY / (v - CY)) : 3.5f;
				depth[v * W + u] = static_cast<uint16_t>(floor_z * 1000.0f);
			}
		}
	}
	// Project a world point (meters, +y up) to a pixel.
	static void project(float x, float y, float z, int &u, int &v) {
		u = static_cast<int>(std::lround(CX + x / z * FX));
		v = static_cast<int>(std::lround(CY - y / z * FY));
	}
	void box(float x0, float x1, float y0, float y1, float z) {
		int u0, v0, u1, v1;
		project(x0, y1, z, u0, v0);
		project(x1, y0, z, u1, v1);
		for (int v = std::max(0, v0); v <= std::min(H - 1, v1); v++) {
			for (int u = std::max(0, u0); u <= std::min(W - 1, u1); u++) {
				uint16_t &d = depth[v * W + u];
				uint16_t nd = static_cast<uint16_t>(z * 1000.0f);
				if (d == 0 || nd < d) d = nd;
			}
		}
	}
	// A standing person: feet at y = -0.9 (camera 0.9 m above the floor), 1.7 m tall.
	void person(float x, float z, bool hands_up = false, float punch_right = 0.0f, float sweep_right_x = 0.0f) {
		float feet = -0.9f;
		box(x - 0.1f, x + 0.1f, feet, feet + 0.9f, z);              // legs
		box(x - 0.22f, x + 0.22f, feet + 0.9f, feet + 1.5f, z);     // torso
		box(x - 0.1f, x + 0.1f, feet + 1.5f, feet + 1.7f, z);       // head
		if (hands_up) {
			box(x - 0.32f, x - 0.22f, feet + 1.4f, feet + 2.2f, z);  // left arm up
			box(x + 0.22f, x + 0.32f, feet + 1.4f, feet + 2.2f, z);  // right arm up
		} else {
			box(x - 0.30f, x - 0.22f, feet + 0.75f, feet + 1.45f, z); // arms down
			box(x + 0.22f, x + 0.30f, feet + 0.75f, feet + 1.45f, z);
		}
		if (punch_right > 0.0f) {
			// Arm extended toward the camera: a bar from the shoulder to z - punch_right.
			for (float dz = 0.0f; dz <= punch_right; dz += 0.05f) {
				box(x + 0.15f, x + 0.25f, feet + 1.3f, feet + 1.4f, z - dz);
			}
		}
		if (sweep_right_x != 0.0f) {
			// Arm out to the side at chest height, angled slightly forward so the
			// depth changes gradually from the shoulder to the hand.
			int steps = 20;
			for (int i = 0; i <= steps; i++) {
				float f = static_cast<float>(i) / steps;
				float ax = x + sweep_right_x * f;
				box(ax - 0.03f, ax + 0.03f, feet + 1.25f, feet + 1.35f, z - 0.3f * f);
			}
		}
	}
};

void run_frames(BodyTracker &t, const Scene &s, double &time_s, int frames) {
	for (int i = 0; i < frames; i++) {
		t.process(s.depth.data(), time_s);
		time_s += 1.0 / 30.0;
	}
}

} // namespace

int main() {
	BodyTracker t;
	t.set_intrinsics(FX, FY, CX, CY, W, H);
	double time_s = 0.0;

	Scene empty;
	run_frames(t, empty, time_s, t.params.bg_learn_frames);
	CHECK(t.background_ready(), "background learned from empty frames");
	CHECK(t.bodies().empty(), "no bodies in an empty room");

	Scene two;
	two.person(-0.7f, 2.5f);
	two.person(0.7f, 2.5f);
	run_frames(t, two, time_s, 5);
	CHECK(t.bodies().size() == 2, "two people found");
	if (t.bodies().size() == 2) {
		const TrackedBody &a = t.bodies()[0].centroid.x < t.bodies()[1].centroid.x ? t.bodies()[0] : t.bodies()[1];
		const TrackedBody &b = &a == &t.bodies()[0] ? t.bodies()[1] : t.bodies()[0];
		CHECK(std::fabs(a.centroid.x + 0.7f) < 0.15f && std::fabs(b.centroid.x - 0.7f) < 0.15f, "centroids near the real x positions");
		CHECK(std::fabs(a.centroid.z - 2.5f) < 0.1f, "centroid depth about 2.5 m");
		std::printf("      height_now=%.2f baseline=%.2f bottom.y=%.2f top.y=%.2f\n", a.height_now, a.height_baseline, a.bottom.y, a.top.y);
		CHECK(std::fabs(a.height_now - 1.7f) < 0.2f, "height about 1.7 m (feet merge with the floor)");
		CHECK(std::fabs(a.bottom.y + 0.9f) < 0.15f, "feet near the floor");
		CHECK(!a.hands_up, "hands are not up when standing");
		CHECK(a.bbox_w > 10 && a.bbox_h > 50 && a.mask.size() == size_t(a.bbox_w * a.bbox_h * 2), "silhouette mask has the bbox size");
		CHECK(a.id != b.id, "distinct ids");
	}
	int id_left = 0;
	for (const TrackedBody &b : t.bodies()) {
		if (b.centroid.x < 0) id_left = b.id;
	}

	// Hands up on the left person.
	Scene shield;
	shield.person(-0.7f, 2.5f, true);
	shield.person(0.7f, 2.5f);
	run_frames(t, shield, time_s, 3);
	{
		const TrackedBody *left = nullptr;
		for (const TrackedBody &b : t.bodies()) if (b.centroid.x < 0) left = &b;
		CHECK(left != nullptr, "left person still tracked");
		if (left) {
			CHECK(left->id == id_left, "id persists across frames");
			std::printf("      height_now=%.2f baseline=%.2f head.y=%.2f handL.y=%.2f handR.y=%.2f\n", left->height_now, left->height_baseline, left->head.y, left->hand_left.y, left->hand_right.y);
			CHECK(left->hands_up, "both arms raised -> hands_up");
			CHECK(left->hand_left.y > left->head.y - 0.05f && left->hand_right.y > left->head.y - 0.05f, "both hands reported above the head");
		}
	}

	// Punch toward the camera with the right arm.
	Scene punch;
	punch.person(-0.7f, 2.5f, false, 0.6f);
	punch.person(0.7f, 2.5f);
	run_frames(t, punch, time_s, 3);
	{
		const TrackedBody *left = nullptr;
		for (const TrackedBody &b : t.bodies()) if (b.centroid.x < 0) left = &b;
		if (left) {
			float hz = std::min(left->hand_left.z, left->hand_right.z);
			CHECK(left->spine_shoulder.z - hz > 0.45f, "punching hand is well in front of the shoulders");
			CHECK(!left->hands_up, "punch is not hands_up");
		}
	}

	// Sweep: arm out to the right side.
	Scene sweep;
	sweep.person(-0.7f, 2.5f, false, 0.0f, 0.7f);
	sweep.person(0.7f, 2.5f);
	run_frames(t, sweep, time_s, 3);
	{
		const TrackedBody *left = nullptr;
		for (const TrackedBody &b : t.bodies()) if (b.centroid.x < 0) left = &b;
		if (left) {
			std::printf("      centroid.x=%.2f handR.x=%.2f handL.x=%.2f\n", left->centroid.x, left->hand_right.x, left->hand_left.x);
			CHECK(left->hand_right.x - left->centroid.x > 0.5f, "extended arm tip found far to the side");
		}
	}

	// Person leaves: only one body remains, the other keeps its id.
	Scene one;
	one.person(0.7f, 2.5f);
	run_frames(t, one, time_s, 3);
	CHECK(t.bodies().size() == 1, "one person after the other leaves");

	std::printf("%s (%d failures)\n", failures == 0 ? "ALL PASSED" : "FAILED", failures);
	return failures == 0 ? 0 : 1;
}
