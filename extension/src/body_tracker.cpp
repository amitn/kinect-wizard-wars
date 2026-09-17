#include "body_tracker.h"

#include <algorithm>
#include <cmath>
#include <limits>

namespace wizardwars {

namespace {

float dist3(const Vec3 &a, const Vec3 &b) {
	float dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z;
	return std::sqrt(dx * dx + dy * dy + dz * dz);
}

} // namespace

void BodyTracker::set_intrinsics(float p_fx, float p_fy, float p_cx, float p_cy, int p_width, int p_height) {
	fx = p_fx;
	fy = p_fy;
	cx = p_cx;
	cy = p_cy;
	if (p_width != width || p_height != height) {
		width = p_width;
		height = p_height;
		background.assign(width * height, 0);
		bg_pending.assign(width * height, 0);
		foreground.assign(width * height, 0);
		labels.assign(width * height, -1);
		learn_background();
	}
}

void BodyTracker::learn_background() {
	std::fill(background.begin(), background.end(), 0);
	std::fill(bg_pending.begin(), bg_pending.end(), 0);
	bg_ready = false;
	bg_frames_seen = 0;
}

Vec3 BodyTracker::unproject(int u, int v, float z_m) const {
	Vec3 p;
	p.x = (static_cast<float>(u) - cx) / fx * z_m;
	p.y = -(static_cast<float>(v) - cy) / fy * z_m;
	p.z = z_m;
	return p;
}

void BodyTracker::update_background(const uint16_t *depth_mm) {
	// The background is the farthest valid depth seen per pixel while learning.
	const int n = width * height;
	for (int i = 0; i < n; i++) {
		uint16_t d = depth_mm[i];
		if (d != 0 && d > background[i]) {
			background[i] = d;
		}
	}
	bg_frames_seen++;
	if (bg_frames_seen >= params.bg_learn_frames) {
		bg_ready = true;
	}
}

void BodyTracker::find_blobs(const uint16_t *depth_mm, std::vector<std::vector<int>> &blobs) {
	const int n = width * height;
	const uint16_t min_mm = static_cast<uint16_t>(params.min_range_m * 1000.0f);
	const uint16_t max_mm = static_cast<uint16_t>(params.max_range_m * 1000.0f);
	const uint16_t margin_mm = static_cast<uint16_t>(params.bg_margin_m * 1000.0f);
	const int link_mm = static_cast<int>(params.link_max_dz_m * 1000.0f);

	for (int i = 0; i < n; i++) {
		uint16_t d = depth_mm[i];
		bool fg = d >= min_mm && d <= max_mm;
		if (d != 0 && bg_ready) {
			// Keep learning: farther is accepted at once, closer only after it stays put.
			if (d + margin_mm >= background[i] || background[i] == 0) {
				if (d > background[i]) {
					background[i] = d;
				}
				if (bg_pending[i] > 0) {
					bg_pending[i]--;  // tolerate flicker: a farther reading only backs off one step
				}
			} else {
				if (bg_pending[i] < 65535) {
					bg_pending[i]++;
				}
				if (bg_pending[i] >= params.bg_accept_frames) {
					background[i] = d;
					bg_pending[i] = 0;
				}
			}
		}
		if (bg_ready && background[i] == 0) {
			fg = false;  // first time this pixel has valid depth: it just became background
		} else if (fg && bg_ready && d + margin_mm >= background[i]) {
			fg = false;
		}
		foreground[i] = fg ? 1 : 0;
		labels[i] = -1;
	}

	std::vector<int> stack;
	stack.reserve(4096);
	for (int start = 0; start < n; start++) {
		if (!foreground[start] || labels[start] != -1) {
			continue;
		}
		const int label = static_cast<int>(blobs.size());
		std::vector<int> pixels;
		stack.clear();
		stack.push_back(start);
		labels[start] = label;
		while (!stack.empty()) {
			int i = stack.back();
			stack.pop_back();
			pixels.push_back(i);
			int u = i % width, v = i / width;
			const int d = depth_mm[i];
			const int neighbours[4] = { u > 0 ? i - 1 : -1, u < width - 1 ? i + 1 : -1, v > 0 ? i - width : -1, v < height - 1 ? i + width : -1 };
			for (int j : neighbours) {
				if (j < 0 || !foreground[j] || labels[j] != -1) {
					continue;
				}
				if (std::abs(static_cast<int>(depth_mm[j]) - d) > link_mm) {
					continue;
				}
				labels[j] = label;
				stack.push_back(j);
			}
		}
		if (static_cast<int>(pixels.size()) >= params.min_area_px) {
			blobs.push_back(std::move(pixels));
		} else {
			blobs.emplace_back();  // keep label indices stable; empty = discarded
		}
	}
}

TrackedBody BodyTracker::analyse(const std::vector<int> &pixels, const uint16_t *depth_mm, double time_s, BodyState &state) {
	TrackedBody b;
	b.area = static_cast<int>(pixels.size());

	int umin = width, umax = -1, vmin = height, vmax = -1;
	double sx = 0.0, sy = 0.0, sz = 0.0;
	std::vector<float> zs;
	zs.reserve(pixels.size());
	std::vector<Vec3> points;
	points.reserve(pixels.size());
	for (int i : pixels) {
		int u = i % width, v = i / width;
		float z = depth_mm[i] / 1000.0f;
		Vec3 p = unproject(u, v, z);
		points.push_back(p);
		zs.push_back(z);
		sx += p.x;
		sy += p.y;
		sz += p.z;
		umin = std::min(umin, u);
		umax = std::max(umax, u);
		vmin = std::min(vmin, v);
		vmax = std::max(vmax, v);
	}
	const float inv = 1.0f / static_cast<float>(pixels.size());
	b.centroid.x = static_cast<float>(sx * inv);
	b.centroid.y = static_cast<float>(sy * inv);
	b.centroid.z = static_cast<float>(sz * inv);
	std::nth_element(zs.begin(), zs.begin() + zs.size() / 2, zs.end());
	const float z_med = zs[zs.size() / 2];

	// Top and bottom of the silhouette: mean of the pixels in the extreme rows.
	double tx = 0, ty = 0, tz = 0, bx = 0, by = 0, bz = 0;
	int tn = 0, bn = 0;
	for (size_t k = 0; k < pixels.size(); k++) {
		int v = pixels[k] / width;
		if (v <= vmin + 1) {
			tx += points[k].x; ty += points[k].y; tz += points[k].z; tn++;
		}
		if (v >= vmax - 1) {
			bx += points[k].x; by += points[k].y; bz += points[k].z; bn++;
		}
	}
	b.top = { static_cast<float>(tx / tn), static_cast<float>(ty / tn), static_cast<float>(tz / tn) };
	b.bottom = { static_cast<float>(bx / bn), static_cast<float>(by / bn), static_cast<float>(bz / bn) };
	b.height_now = b.top.y - b.bottom.y;

	// Standing height: the smallest height seen over the last few seconds.
	state.heights.push_back({ time_s, b.height_now });
	while (!state.heights.empty() && time_s - state.heights.front().t > params.baseline_window_s) {
		state.heights.pop_front();
	}
	float baseline = std::numeric_limits<float>::max();
	for (const HistoryEntry &h : state.heights) {
		baseline = std::min(baseline, h.height);
	}
	b.height_baseline = baseline;

	// Hands up: silhouette taller than usual and at least two separate columns near the top.
	bool taller = b.height_now > baseline + params.hands_up_margin_m;
	int max_runs = 0;
	if (taller) {
		const int band_rows = std::max(2, static_cast<int>(0.15f * fy / std::max(z_med, 0.3f)));
		for (int v = vmin; v <= std::min(vmax, vmin + band_rows); v++) {
			int runs = 0;
			bool in_run = false;
			for (int u = umin; u <= umax; u++) {
				bool on = labels[v * width + u] >= 0 && labels[v * width + u] == labels[pixels[0]];
				if (on && !in_run) {
					runs++;
				}
				in_run = on;
			}
			max_runs = std::max(max_runs, runs);
		}
	}
	const float head_y = b.bottom.y + 0.93f * baseline;
	bool hands_up_shape = taller && max_runs >= 2;
	b.spine_shoulder = { b.centroid.x, b.bottom.y + 0.80f * baseline, z_med };

	// Hand candidates: above the waist and either sideways, in front, or above the head.
	const float waist_y = b.centroid.y - 0.15f;
	const Vec3 torso = { b.centroid.x, b.centroid.y + 0.3f, z_med };
	Vec3 tip_left, tip_right;
	float best_left = -1.0f, best_right = -1.0f;
	for (const Vec3 &p : points) {
		if (p.y < waist_y) {
			continue;
		}
		bool sideways = std::fabs(p.x - b.centroid.x) > params.lateral_arm_m;
		bool in_front = z_med - p.z > params.front_arm_m;
		bool above = p.y > head_y + 0.10f;
		if (!(sideways || in_front || above)) {
			continue;
		}
		float d = dist3(p, torso);
		if (p.x < b.centroid.x) {
			if (d > best_left) { best_left = d; tip_left = p; }
		} else {
			if (d > best_right) { best_right = d; tip_right = p; }
		}
	}
	const Vec3 rest_left = { b.centroid.x - 0.2f, b.bottom.y + 0.45f * baseline, z_med };
	const Vec3 rest_right = { b.centroid.x + 0.2f, b.bottom.y + 0.45f * baseline, z_med };
	bool found_l = best_left >= 0.0f, found_r = best_right >= 0.0f;

	// Continuity: if only one tip exists, give it to whichever hand was nearer last frame,
	// so a sweep across the body stays on the same hand.
	if (found_l != found_r && state.has_hands) {
		Vec3 tip = found_l ? tip_left : tip_right;
		bool nearer_left = dist3(tip, state.hand_left) <= dist3(tip, state.hand_right);
		found_l = nearer_left;
		found_r = !nearer_left;
		if (nearer_left) { tip_left = tip; } else { tip_right = tip; }
	}
	b.hand_left = found_l ? tip_left : rest_left;
	b.hand_right = found_r ? tip_right : rest_right;
	b.hand_left_found = found_l;
	b.hand_right_found = found_r;
	// Hands up needs the silhouette shape and both hand tips above the head.
	b.hands_up = hands_up_shape && found_l && found_r && b.hand_left.y > head_y + 0.05f && b.hand_right.y > head_y + 0.05f;
	if (b.hands_up) {
		b.head = { b.centroid.x, head_y, z_med };
	} else {
		b.head = b.top;
	}
	state.hand_left = b.hand_left;
	state.hand_right = b.hand_right;
	state.has_hands = true;
	if (time_s - state.last_seen > 0.2) {
		state.frames_seen = 0;  // a gap resets the confirmation count
	}
	state.frames_seen++;
	state.last_seen = time_s;
	state.last_centroid = b.centroid;

	// Silhouette mask for drawing.
	b.bbox_x = umin;
	b.bbox_y = vmin;
	b.bbox_w = umax - umin + 1;
	b.bbox_h = vmax - vmin + 1;
	b.mask.assign(b.bbox_w * b.bbox_h * 2, 0);
	for (int i = 0; i < b.bbox_w * b.bbox_h; i++) {
		b.mask[i * 2] = 255;
	}
	for (int i : pixels) {
		int u = i % width - umin, v = i / width - vmin;
		b.mask[(v * b.bbox_w + u) * 2 + 1] = 255;
	}
	double cu = 0, cv = 0;
	for (int i : pixels) {
		cu += i % width;
		cv += i / width;
	}
	b.center_px_x = static_cast<int>(cu / pixels.size()) - umin;
	b.center_px_y = static_cast<int>(cv / pixels.size()) - vmin;
	return b;
}

void BodyTracker::assign_ids(std::vector<TrackedBody> &found, std::vector<const std::vector<int> *> &blob_refs, const uint16_t *depth_mm, double time_s) {
	// Greedy nearest-centroid matching against remembered bodies (recent ones first).
	std::vector<bool> used(found.size(), false);
	std::vector<int> ids(found.size(), 0);
	std::vector<std::pair<double, int>> candidates;  // (-last_seen, id)
	for (const auto &kv : states) {
		if (time_s - kv.second.last_seen <= params.id_memory_s) {
			candidates.push_back({ -kv.second.last_seen, kv.first });
		}
	}
	std::sort(candidates.begin(), candidates.end());
	std::vector<bool> id_taken;
	for (const auto &cand : candidates) {
		const BodyState &prev = states[cand.second];
		int best = -1;
		float best_d = params.match_max_dist_m;
		for (size_t k = 0; k < found.size(); k++) {
			if (used[k]) {
				continue;
			}
			float d = dist3(found[k].centroid, prev.last_centroid);
			if (d < best_d) {
				best_d = d;
				best = static_cast<int>(k);
			}
		}
		if (best >= 0) {
			used[best] = true;
			ids[best] = cand.second;
		}
	}
	for (size_t k = 0; k < found.size(); k++) {
		if (!used[k]) {
			ids[k] = next_id++;
		}
	}
	// Re-run the analysis with the right per-id state so hand continuity and
	// height history follow the person, not the slot.
	for (size_t k = 0; k < found.size(); k++) {
		found[k] = analyse(*blob_refs[k], depth_mm, time_s, states[ids[k]]);
		found[k].id = ids[k];
	}
	for (auto it = states.begin(); it != states.end();) {
		if (time_s - it->second.last_seen > params.id_memory_s + 1.0) {
			it = states.erase(it);
		} else {
			++it;
		}
	}
}

void BodyTracker::process(const uint16_t *depth_mm, double time_s) {
	if (width == 0) {
		return;
	}
	if (!bg_ready) {
		update_background(depth_mm);
		current.clear();
		return;
	}

	std::vector<std::vector<int>> blobs;
	find_blobs(depth_mm, blobs);

	std::vector<const std::vector<int> *> chosen;
	for (const auto &blob : blobs) {
		if (blob.empty()) {
			continue;
		}
		// Physical height check: rows spanned times meters per pixel at the blob's depth.
		int vmin = height, vmax = -1;
		double zsum = 0.0;
		for (int i : blob) {
			int v = i / width;
			vmin = std::min(vmin, v);
			vmax = std::max(vmax, v);
			zsum += depth_mm[i];
		}
		float z = static_cast<float>(zsum / blob.size()) / 1000.0f;
		float phys_h = (vmax - vmin + 1) * z / fy;
		if (phys_h < params.min_height_m) {
			continue;
		}
		chosen.push_back(&blob);
	}
	std::sort(chosen.begin(), chosen.end(), [](const std::vector<int> *a, const std::vector<int> *b) { return a->size() > b->size(); });
	if (static_cast<int>(chosen.size()) > params.max_bodies) {
		chosen.resize(params.max_bodies);
	}

	// First pass with throwaway state just to get centroids for id matching.
	std::vector<TrackedBody> found;
	for (const std::vector<int> *blob : chosen) {
		BodyState scratch;
		found.push_back(analyse(*blob, depth_mm, time_s, scratch));
	}
	assign_ids(found, chosen, depth_mm, time_s);
	current.clear();
	for (TrackedBody &b : found) {
		if (b.height_now < params.min_height_m) {
			continue;
		}
		if (states[b.id].frames_seen >= params.confirm_frames) {
			current.push_back(std::move(b));
		}
	}
}

} // namespace wizardwars
