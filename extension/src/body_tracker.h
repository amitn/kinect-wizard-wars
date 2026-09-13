#ifndef WIZARD_WARS_BODY_TRACKER_H
#define WIZARD_WARS_BODY_TRACKER_H

#include <cstdint>
#include <deque>
#include <map>
#include <vector>

namespace wizardwars {

struct Vec3 {
	float x = 0.0f, y = 0.0f, z = 0.0f;
};

/// One person found in a depth frame. Positions are meters in the camera frame:
/// +x to the image's right, +y up, +z away from the camera.
struct TrackedBody {
	int id = 0;
	int area = 0;
	Vec3 centroid;        // whole-silhouette centroid, roughly the hips
	Vec3 spine_shoulder;  // estimated from the standing height
	Vec3 head;
	Vec3 top;             // topmost point of the silhouette
	Vec3 bottom;          // lowest point of the silhouette
	Vec3 hand_left;       // "left" = image left, i.e. the player's right hand in a mirror view
	Vec3 hand_right;
	bool hand_left_found = false;
	bool hand_right_found = false;
	bool hands_up = false;
	float height_now = 0.0f;
	float height_baseline = 0.0f;

	// Silhouette mask, LA8 (luma 255, alpha 0/255), bbox_w * bbox_h * 2 bytes.
	int bbox_x = 0, bbox_y = 0, bbox_w = 0, bbox_h = 0;
	int center_px_x = 0, center_px_y = 0;  // centroid pixel, relative to the bbox
	std::vector<uint8_t> mask;
};

/// Simple depth-only people tracker: background subtraction, connected
/// components, and a few geometric features per blob. No machine learning,
/// no GPU, runs on anything.
class BodyTracker {
public:
	struct Params {
		float min_range_m = 0.5f;
		float max_range_m = 4.0f;
		float bg_margin_m = 0.15f;      // closer than the background by this much = foreground
		float link_max_dz_m = 0.20f;    // neighbouring pixels join a blob only if this close in depth
		int min_area_px = 250;          // at the working resolution
		int bg_learn_frames = 45;
		int max_bodies = 2;
		float lateral_arm_m = 0.35f;    // hand candidates: this far sideways from the body axis (arms at rest are ~0.25)
		float front_arm_m = 0.25f;      // ...or this far in front of the torso
		float hands_up_margin_m = 0.22f;
		float match_max_dist_m = 0.7f;  // blob-to-previous-body matching
		double baseline_window_s = 3.0;
	};

	Params params;

	void set_intrinsics(float fx, float fy, float cx, float cy, int width, int height);
	void learn_background();
	bool background_ready() const { return bg_ready; }
	int background_progress() const { return bg_frames_seen; }

	/// depth_mm must be width*height uint16 in millimetres, 0 = invalid.
	void process(const uint16_t *depth_mm, double time_s);
	const std::vector<TrackedBody> &bodies() const { return current; }

	Vec3 unproject(int u, int v, float z_m) const;

private:
	struct HistoryEntry {
		double t;
		float height;
	};
	struct BodyState {
		std::deque<HistoryEntry> heights;
		Vec3 hand_left, hand_right;
		bool has_hands = false;
		double last_seen = 0.0;
	};

	void update_background(const uint16_t *depth_mm);
	void find_blobs(const uint16_t *depth_mm, std::vector<std::vector<int>> &blobs);
	TrackedBody analyse(const std::vector<int> &pixels, const uint16_t *depth_mm, double time_s, BodyState &state);
	void assign_ids(std::vector<TrackedBody> &found, std::vector<const std::vector<int> *> &blob_refs, const uint16_t *depth_mm, double time_s);

	int width = 0, height = 0;
	float fx = 1.0f, fy = 1.0f, cx = 0.0f, cy = 0.0f;
	std::vector<uint16_t> background;
	std::vector<uint8_t> foreground;
	std::vector<int32_t> labels;
	bool bg_ready = false;
	int bg_frames_seen = 0;
	int next_id = 1;
	std::map<int, BodyState> states;
	std::vector<TrackedBody> current;
};

} // namespace wizardwars

#endif // WIZARD_WARS_BODY_TRACKER_H
