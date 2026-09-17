#ifndef WIZARD_WARS_ORBBEC_CAMERA_H
#define WIZARD_WARS_ORBBEC_CAMERA_H

#include "body_tracker.h"

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <cstdint>
#include <memory>
#include <mutex>
#include <vector>

namespace ob {
class Pipeline;
class FrameSet;
class Align;
}

namespace wizardwars {

/// Godot node that streams depth from an Orbbec camera (Gemini 2 and friends),
/// tracks up to two people with BodyTracker and emits `frame_received(bodies)`.
/// Each body is a Dictionary shaped like the UDP bridge's, plus a silhouette:
///   {"id": "3", "hands": {...}, "hands_up": bool, "height": float,
///    "joints": {"SpineBase": [x, y, z, 2], "SpineShoulder": ..., "Head": ...,
///               "HandLeft": ..., "HandRight": ..., "FootLeft": ..., "FootRight": ...},
///    "silhouette": {"w": int, "h": int, "cx": int, "cy": int, "data": PackedByteArray (LA8)}}
class OrbbecCamera : public godot::Node {
	GDCLASS(OrbbecCamera, godot::Node)

public:
	OrbbecCamera();
	~OrbbecCamera() override;

	bool start();
	void stop();
	bool is_running() const;
	void learn_background();
	bool is_background_ready() const;
	int get_tracked_body_count() const;
	godot::String get_last_error() const;
	godot::String get_device_name() const;
	int get_depth_width() const;
	int get_depth_height() const;
	/// Debug view: the working depth image with foreground tinted and body markers drawn.
	void set_debug_enabled(bool enabled);
	godot::Ref<godot::Image> get_debug_image() const;

	// --- Color + aligned depth for pose estimation (see NEW_INTEGRATION) ---
	/// Latest color frame as an RGB8 Image (a copy), or null before the first frame.
	godot::Ref<godot::Image> get_color_image();
	int get_color_width() const;
	int get_color_height() const;
	/// Frame counter of the latest color frame; poll it to avoid processing a frame twice.
	int get_color_frame_id() const;
	/// Timestamp (ms) of the latest color frame.
	double get_timestamp() const;
	/// Median depth in meters in a (2*radius+1)^2 window of the aligned depth at a color pixel; 0 when unknown.
	float get_depth_at(int x, int y, int radius) const;
	/// Like get_depth_at but returns the given percentile (0..1) of the valid samples;
	/// a low percentile favours the nearest surface, which is right for hands in front of a wall.
	float get_depth_percentile(int x, int y, int radius, float percentile) const;
	/// Camera-space point in meters for a color pixel and depth: +x right, +y up, +z away from the camera.
	godot::Vector3 deproject_pixel(float x, float y, float depth_m) const;
	/// Color intrinsics as [fx, fy, cx, cy] (aligned depth shares them).
	godot::PackedFloat32Array get_intrinsics() const;

	void _process(double delta) override;

protected:
	static void _bind_methods();

private:
	void on_depth(const uint16_t *data, int width, int height, float scale_mm, float fx, float fy, float cx, float cy, uint64_t timestamp_us);
	void on_frameset(std::shared_ptr<ob::FrameSet> frames);
	godot::Array bodies_to_array() const;

	std::shared_ptr<ob::Pipeline> pipeline;
	std::shared_ptr<ob::Align> align;
	bool running = false;
	bool color_enabled = true;
	godot::String last_error;
	godot::String device_name;

	// Written by the SDK thread, read on the main thread.
	std::mutex frame_mutex;
	std::vector<uint8_t> color_rgb;          // latest color frame, RGB8
	int color_w = 0, color_h = 0;
	int color_frame_id = 0;
	double color_ts_ms = 0.0;
	std::vector<uint16_t> aligned_depth_mm;  // depth aligned to color, full resolution
	int aligned_w = 0, aligned_h = 0;
	float col_fx = 0, col_fy = 0, col_cx = 0, col_cy = 0;
	std::vector<uint16_t> latest_depth;  // working resolution, millimetres
	int latest_w = 0, latest_h = 0;
	int source_w = 0, source_h = 0;
	float latest_fx = 0, latest_fy = 0, latest_cx = 0, latest_cy = 0;
	uint64_t latest_ts = 0;
	bool has_new_frame = false;
	uint64_t frames_received = 0;

	int downsample = 2;
	BodyTracker tracker;
	int tracked_count = 0;
	bool debug_enabled = false;
	std::vector<uint16_t> last_depth;
	godot::Ref<godot::Image> debug_image;

	void build_debug_image();
};

} // namespace wizardwars

#endif // WIZARD_WARS_ORBBEC_CAMERA_H
