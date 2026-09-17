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

	void _process(double delta) override;

protected:
	static void _bind_methods();

private:
	void on_depth(const uint16_t *data, int width, int height, float scale_mm, float fx, float fy, float cx, float cy, uint64_t timestamp_us);
	godot::Array bodies_to_array() const;

	std::shared_ptr<ob::Pipeline> pipeline;
	bool running = false;
	godot::String last_error;
	godot::String device_name;

	// Written by the SDK thread, read on the main thread.
	std::mutex frame_mutex;
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
