#include "webcam_camera.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

#include <cmath>
#include <cstring>

namespace wizardwars {

#if !defined(_WIN32) && !defined(__linux__)
// No capture backend for this platform: the class exists and reports why it cannot start.
std::vector<std::string> WebcamBackend::list_devices() {
	return {};
}

std::unique_ptr<WebcamBackend> WebcamBackend::create() {
	return nullptr;
}
#endif

WebcamCamera::WebcamCamera() {
	set_process_mode(PROCESS_MODE_ALWAYS);
}

WebcamCamera::~WebcamCamera() {
	stop();
}

void WebcamCamera::_bind_methods() {
	using godot::D_METHOD;
	godot::ClassDB::bind_method(D_METHOD("start"), &WebcamCamera::start);
	godot::ClassDB::bind_method(D_METHOD("stop"), &WebcamCamera::stop);
	godot::ClassDB::bind_method(D_METHOD("is_running"), &WebcamCamera::is_running);
	godot::ClassDB::bind_method(D_METHOD("get_last_error"), &WebcamCamera::get_last_error);
	godot::ClassDB::bind_method(D_METHOD("get_device_name"), &WebcamCamera::get_device_name);
	godot::ClassDB::bind_method(D_METHOD("has_depth"), &WebcamCamera::has_depth);
	godot::ClassDB::bind_method(D_METHOD("list_devices"), &WebcamCamera::list_devices);
	godot::ClassDB::bind_method(D_METHOD("set_device", "index"), &WebcamCamera::set_device);
	godot::ClassDB::bind_method(D_METHOD("get_device"), &WebcamCamera::get_device);
	godot::ClassDB::bind_method(D_METHOD("set_mode", "width", "height", "fps"), &WebcamCamera::set_mode);
	godot::ClassDB::bind_method(D_METHOD("set_horizontal_fov", "degrees"), &WebcamCamera::set_horizontal_fov);
	godot::ClassDB::bind_method(D_METHOD("get_horizontal_fov"), &WebcamCamera::get_horizontal_fov);
	godot::ClassDB::bind_method(D_METHOD("get_color_image"), &WebcamCamera::get_color_image);
	godot::ClassDB::bind_method(D_METHOD("get_color_width"), &WebcamCamera::get_color_width);
	godot::ClassDB::bind_method(D_METHOD("get_color_height"), &WebcamCamera::get_color_height);
	godot::ClassDB::bind_method(D_METHOD("get_color_frame_id"), &WebcamCamera::get_color_frame_id);
	godot::ClassDB::bind_method(D_METHOD("get_timestamp"), &WebcamCamera::get_timestamp);
	godot::ClassDB::bind_method(D_METHOD("get_depth_at", "x", "y", "radius"), &WebcamCamera::get_depth_at);
	godot::ClassDB::bind_method(D_METHOD("get_depth_percentile", "x", "y", "radius", "percentile"), &WebcamCamera::get_depth_percentile);
	godot::ClassDB::bind_method(D_METHOD("deproject_pixel", "x", "y", "depth_m"), &WebcamCamera::deproject_pixel);
	godot::ClassDB::bind_method(D_METHOD("get_intrinsics"), &WebcamCamera::get_intrinsics);
}

bool WebcamCamera::start() {
	if (is_running()) {
		return true;
	}
	stop();
	last_error = "";
	backend = WebcamBackend::create();
	if (!backend) {
		last_error = "webcams are not supported on this platform";
		return false;
	}
	{
		std::lock_guard<std::mutex> lock(frame_mutex);
		frame_bytes.clear();
		frame_w = frame_h = 0;
	}
	started_at = std::chrono::steady_clock::now();
	std::string error;
	const bool opened = backend->open(device_index, want_w, want_h, want_fps,
			[this](const uint8_t *data, size_t size, int width, int height, WebcamBackend::Pixels pixels) {
				on_frame(data, size, width, height, pixels);
			},
			error);
	if (!opened) {
		last_error = godot::String::utf8(error.c_str());
		backend.reset();
		return false;
	}
	return true;
}

void WebcamCamera::stop() {
	if (backend) {
		backend->close();
		backend.reset();
	}
	decoded.unref();
	decoded_id = -1;
}

bool WebcamCamera::is_running() const {
	return backend && backend->is_alive();
}

godot::String WebcamCamera::get_last_error() const {
	if (backend && !backend->is_alive()) {
		const std::string text = backend->last_error();
		if (!text.empty()) {
			return godot::String::utf8(text.c_str());
		}
	}
	return last_error;
}

godot::String WebcamCamera::get_device_name() const {
	return backend ? godot::String::utf8(backend->device_name().c_str()) : godot::String();
}

godot::PackedStringArray WebcamCamera::list_devices() const {
	godot::PackedStringArray out;
	for (const std::string &name : WebcamBackend::list_devices()) {
		out.push_back(godot::String::utf8(name.c_str()));
	}
	return out;
}

void WebcamCamera::set_device(int index) {
	device_index = index < 0 ? 0 : index;
}

int WebcamCamera::get_device() const {
	return device_index;
}

void WebcamCamera::set_mode(int width, int height, int fps) {
	if (width > 0 && height > 0) {
		want_w = width;
		want_h = height;
	}
	if (fps > 0) {
		want_fps = fps;
	}
}

void WebcamCamera::set_horizontal_fov(float degrees) {
	horizontal_fov_deg = degrees < 20.0f ? 20.0f : (degrees > 140.0f ? 140.0f : degrees);
}

float WebcamCamera::get_horizontal_fov() const {
	return horizontal_fov_deg;
}

// Runs on the backend's capture thread.
void WebcamCamera::on_frame(const uint8_t *data, size_t size, int width, int height, WebcamBackend::Pixels pixels) {
	if (data == nullptr || size == 0 || width <= 0 || height <= 0) {
		return;
	}
	const double ts = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started_at).count();
	std::lock_guard<std::mutex> lock(frame_mutex);
	frame_bytes.assign(data, data + size);
	frame_is_jpeg = pixels == WebcamBackend::Pixels::JPEG;
	frame_w = width;
	frame_h = height;
	frame_ts_ms = ts;
	frame_id++;
}

godot::Ref<godot::Image> WebcamCamera::get_color_image() {
	godot::PackedByteArray data;
	int w, h, id;
	bool is_jpeg;
	{
		std::lock_guard<std::mutex> lock(frame_mutex);
		if (frame_w == 0 || frame_bytes.empty()) {
			return godot::Ref<godot::Image>();
		}
		if (decoded.is_valid() && decoded_id == frame_id) {
			return decoded;
		}
		w = frame_w;
		h = frame_h;
		id = frame_id;
		is_jpeg = frame_is_jpeg;
		data.resize(frame_bytes.size());
		std::memcpy(data.ptrw(), frame_bytes.data(), frame_bytes.size());
	}
	godot::Ref<godot::Image> image;
	if (is_jpeg) {
		image.instantiate();
		if (image->load_jpg_from_buffer(data) != godot::OK || image->is_empty()) {
			return godot::Ref<godot::Image>();
		}
		if (image->get_format() != godot::Image::FORMAT_RGB8) {
			image->convert(godot::Image::FORMAT_RGB8);
		}
	} else {
		if (data.size() != static_cast<int64_t>(w) * h * 3) {
			return godot::Ref<godot::Image>();
		}
		image = godot::Image::create_from_data(w, h, false, godot::Image::FORMAT_RGB8, data);
	}
	decoded = image;
	decoded_id = id;
	return image;
}

int WebcamCamera::get_color_width() const {
	std::lock_guard<std::mutex> lock(frame_mutex);
	return frame_w;
}

int WebcamCamera::get_color_height() const {
	std::lock_guard<std::mutex> lock(frame_mutex);
	return frame_h;
}

int WebcamCamera::get_color_frame_id() const {
	std::lock_guard<std::mutex> lock(frame_mutex);
	return frame_id;
}

double WebcamCamera::get_timestamp() const {
	std::lock_guard<std::mutex> lock(frame_mutex);
	return frame_ts_ms;
}

float WebcamCamera::focal_px() const {
	const int w = get_color_width();
	if (w <= 0) {
		return 0.0f;
	}
	return (w * 0.5f) / std::tan(horizontal_fov_deg * 0.5f * 3.14159265f / 180.0f);
}

godot::Vector3 WebcamCamera::deproject_pixel(float x, float y, float depth_m) const {
	const float f = focal_px();
	if (f <= 0.0f) {
		return godot::Vector3(0, 0, depth_m);
	}
	const float cx = get_color_width() * 0.5f;
	const float cy = get_color_height() * 0.5f;
	return godot::Vector3((x - cx) / f * depth_m, -(y - cy) / f * depth_m, depth_m);
}

godot::PackedFloat32Array WebcamCamera::get_intrinsics() const {
	const float f = focal_px();
	godot::PackedFloat32Array a;
	a.push_back(f);
	a.push_back(f);
	a.push_back(get_color_width() * 0.5f);
	a.push_back(get_color_height() * 0.5f);
	return a;
}

} // namespace wizardwars
