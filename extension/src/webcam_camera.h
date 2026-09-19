#ifndef WIZARD_WARS_WEBCAM_CAMERA_H
#define WIZARD_WARS_WEBCAM_CAMERA_H

#include "webcam_backend.h"

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <chrono>
#include <cstdint>
#include <memory>
#include <mutex>
#include <vector>

namespace wizardwars {

/// An ordinary RGB webcam, with the color half of OrbbecCamera's interface so
/// the pose pipeline can run on either. There is no depth here: has_depth() is
/// false, the depth queries answer 0, and the pose layer estimates distance
/// from how large a person appears (see rtm_pose_processor.gd).
class WebcamCamera : public godot::Node {
	GDCLASS(WebcamCamera, godot::Node)

public:
	WebcamCamera();
	~WebcamCamera() override;

	bool start();
	void stop();
	bool is_running() const;
	godot::String get_last_error() const;
	godot::String get_device_name() const;
	bool has_depth() const { return false; }

	/// Names of the cameras the system offers; the position is the index for set_device().
	godot::PackedStringArray list_devices() const;
	void set_device(int index);
	int get_device() const;
	/// Mode asked for at the next start(); the camera's nearest mode is used. Defaults to 640x480 at 30.
	void set_mode(int width, int height, int fps);
	/// A webcam reports no intrinsics, so they come from an assumed horizontal field of view.
	void set_horizontal_fov(float degrees);
	float get_horizontal_fov() const;

	godot::Ref<godot::Image> get_color_image();
	int get_color_width() const;
	int get_color_height() const;
	int get_color_frame_id() const;
	double get_timestamp() const;
	float get_depth_at(int x, int y, int radius) const { return 0.0f; }
	float get_depth_percentile(int x, int y, int radius, float percentile) const { return 0.0f; }
	godot::Vector3 deproject_pixel(float x, float y, float depth_m) const;
	godot::PackedFloat32Array get_intrinsics() const;

protected:
	static void _bind_methods();

private:
	void on_frame(const uint8_t *data, size_t size, int width, int height, WebcamBackend::Pixels pixels);
	float focal_px() const;

	std::unique_ptr<WebcamBackend> backend;
	godot::String last_error;
	int device_index = 0;
	int want_w = 640, want_h = 480, want_fps = 30;
	float horizontal_fov_deg = 62.0f;
	std::chrono::steady_clock::time_point started_at;

	// Written by the capture thread, read on the main thread.
	mutable std::mutex frame_mutex;
	std::vector<uint8_t> frame_bytes; // RGB8, or one JPEG when frame_is_jpeg
	bool frame_is_jpeg = false;
	int frame_w = 0, frame_h = 0;
	int frame_id = 0;
	double frame_ts_ms = 0.0;

	// MJPG frames are decoded on demand, once per frame, on the main thread.
	godot::Ref<godot::Image> decoded;
	int decoded_id = -1;
};

} // namespace wizardwars

#endif // WIZARD_WARS_WEBCAM_CAMERA_H
