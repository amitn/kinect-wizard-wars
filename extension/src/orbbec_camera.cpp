#include "orbbec_camera.h"

#include <libobsensor/ObSensor.hpp>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cstring>
#include <string>

#if defined(_WIN32)
#include <windows.h>
#else
#include <dlfcn.h>
#endif

namespace wizardwars {

namespace {

/// Directory holding this extension's shared library, so the SDK's "extensions"
/// folder can live next to it instead of next to the Godot executable.
std::string library_directory() {
#if defined(_WIN32)
	HMODULE module = nullptr;
	GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
			reinterpret_cast<LPCSTR>(&library_directory), &module);
	char path[MAX_PATH] = {};
	if (module != nullptr && GetModuleFileNameA(module, path, MAX_PATH) > 0) {
		std::string s(path);
		size_t slash = s.find_last_of("\\/");
		return slash == std::string::npos ? "." : s.substr(0, slash);
	}
	return ".";
#else
	Dl_info info;
	if (dladdr(reinterpret_cast<void *>(&library_directory), &info) != 0 && info.dli_fname != nullptr) {
		std::string s(info.dli_fname);
		size_t slash = s.find_last_of('/');
		return slash == std::string::npos ? "." : s.substr(0, slash);
	}
	return ".";
#endif
}

godot::Array joint(const Vec3 &p) {
	godot::Array a;
	a.push_back(p.x);
	a.push_back(p.y);
	a.push_back(p.z);
	a.push_back(2);
	return a;
}

} // namespace

OrbbecCamera::OrbbecCamera() {
	set_process_mode(PROCESS_MODE_ALWAYS);
}

OrbbecCamera::~OrbbecCamera() {
	stop();
}

void OrbbecCamera::_bind_methods() {
	using godot::D_METHOD;
	godot::ClassDB::bind_method(D_METHOD("start"), &OrbbecCamera::start);
	godot::ClassDB::bind_method(D_METHOD("stop"), &OrbbecCamera::stop);
	godot::ClassDB::bind_method(D_METHOD("is_running"), &OrbbecCamera::is_running);
	godot::ClassDB::bind_method(D_METHOD("learn_background"), &OrbbecCamera::learn_background);
	godot::ClassDB::bind_method(D_METHOD("is_background_ready"), &OrbbecCamera::is_background_ready);
	godot::ClassDB::bind_method(D_METHOD("get_tracked_body_count"), &OrbbecCamera::get_tracked_body_count);
	godot::ClassDB::bind_method(D_METHOD("get_last_error"), &OrbbecCamera::get_last_error);
	godot::ClassDB::bind_method(D_METHOD("get_device_name"), &OrbbecCamera::get_device_name);
	godot::ClassDB::bind_method(D_METHOD("get_depth_width"), &OrbbecCamera::get_depth_width);
	godot::ClassDB::bind_method(D_METHOD("get_depth_height"), &OrbbecCamera::get_depth_height);
	godot::ClassDB::bind_method(D_METHOD("set_debug_enabled", "enabled"), &OrbbecCamera::set_debug_enabled);
	godot::ClassDB::bind_method(D_METHOD("get_debug_image"), &OrbbecCamera::get_debug_image);
	godot::ClassDB::bind_method(D_METHOD("get_color_image"), &OrbbecCamera::get_color_image);
	godot::ClassDB::bind_method(D_METHOD("get_color_width"), &OrbbecCamera::get_color_width);
	godot::ClassDB::bind_method(D_METHOD("get_color_height"), &OrbbecCamera::get_color_height);
	godot::ClassDB::bind_method(D_METHOD("get_color_frame_id"), &OrbbecCamera::get_color_frame_id);
	godot::ClassDB::bind_method(D_METHOD("get_timestamp"), &OrbbecCamera::get_timestamp);
	godot::ClassDB::bind_method(D_METHOD("get_depth_at", "x", "y", "radius"), &OrbbecCamera::get_depth_at);
	godot::ClassDB::bind_method(D_METHOD("get_depth_percentile", "x", "y", "radius", "percentile"), &OrbbecCamera::get_depth_percentile);
	godot::ClassDB::bind_method(D_METHOD("deproject_pixel", "x", "y", "depth_m"), &OrbbecCamera::deproject_pixel);
	godot::ClassDB::bind_method(D_METHOD("get_intrinsics"), &OrbbecCamera::get_intrinsics);

	ADD_SIGNAL(godot::MethodInfo("frame_received", godot::PropertyInfo(godot::Variant::ARRAY, "bodies")));
}

bool OrbbecCamera::start() {
	if (running) {
		return true;
	}
	last_error = "";
	try {
		static bool extensions_set = false;
		if (!extensions_set) {
			std::string ext_dir = library_directory() + "/extensions";
			ob::Context::setExtensionsDirectory(ext_dir.c_str());
			extensions_set = true;
		}
		ob::Context::setLoggerSeverity(OB_LOG_SEVERITY_ERROR);

		pipeline = std::make_shared<ob::Pipeline>();
		std::shared_ptr<ob::Device> device = pipeline->getDevice();
		if (device) {
			std::shared_ptr<ob::DeviceInfo> info = device->getDeviceInfo();
			if (info) {
				device_name = godot::String(info->getName()) + " (" + godot::String(info->getSerialNumber()) + ")";
			}
		}

		std::shared_ptr<ob::Config> config = std::make_shared<ob::Config>();
		config->setFrameAggregateOutputMode(OB_FRAME_AGGREGATE_OUTPUT_ALL_TYPE_FRAME_REQUIRE);
		try {
			config->enableVideoStream(OB_STREAM_DEPTH, 640, 400, 30, OB_FORMAT_Y16);
		} catch (const ob::Error &) {
			config->enableVideoStream(OB_STREAM_DEPTH);
		}
		color_enabled = true;
		try {
			config->enableVideoStream(OB_STREAM_COLOR, 1280, 720, 30, OB_FORMAT_RGB);
		} catch (const ob::Error &) {
			try {
				config->enableVideoStream(OB_STREAM_COLOR, 0, 0, 30, OB_FORMAT_RGB);
			} catch (const ob::Error &) {
				color_enabled = false;
				config->setFrameAggregateOutputMode(OB_FRAME_AGGREGATE_OUTPUT_ANY_SITUATION);
			}
		}
		if (color_enabled) {
			align = std::make_shared<ob::Align>(OB_STREAM_COLOR);
		}

		pipeline->start(config, [this](std::shared_ptr<ob::FrameSet> frames) {
			if (frames) {
				on_frameset(frames);
			}
		});
		running = true;
		godot::UtilityFunctions::print("OrbbecCamera: streaming depth from ", device_name);
		return true;
	} catch (const ob::Error &e) {
		last_error = godot::String(e.what());
	} catch (const std::exception &e) {
		last_error = godot::String(e.what());
	}
	pipeline.reset();
	running = false;
	return false;
}

void OrbbecCamera::stop() {
	align.reset();
	if (pipeline) {
		try {
			pipeline->stop();
		} catch (...) {
		}
		pipeline.reset();
	}
	running = false;
	tracked_count = 0;
}

bool OrbbecCamera::is_running() const {
	return running;
}

void OrbbecCamera::learn_background() {
	tracker.learn_background();
}

bool OrbbecCamera::is_background_ready() const {
	return tracker.background_ready();
}

int OrbbecCamera::get_tracked_body_count() const {
	return tracked_count;
}

godot::String OrbbecCamera::get_last_error() const {
	return last_error;
}

godot::String OrbbecCamera::get_device_name() const {
	return device_name;
}

int OrbbecCamera::get_depth_width() const {
	return source_w;
}

int OrbbecCamera::get_depth_height() const {
	return source_h;
}

// Runs on the SDK's thread. Depth alone feeds the blob tracker; with color the
// depth is aligned to the color image and both are kept for pose estimation.
void OrbbecCamera::on_frameset(std::shared_ptr<ob::FrameSet> frames) {
	std::shared_ptr<ob::DepthFrame> depth = frames->getDepthFrame();
	std::shared_ptr<ob::ColorFrame> color = frames->getColorFrame();
	if (!depth) {
		return;
	}
	if (color_enabled && color && align) {
		try {
			std::shared_ptr<ob::Frame> aligned = align->process(frames);
			std::shared_ptr<ob::FrameSet> aset = aligned ? aligned->as<ob::FrameSet>() : nullptr;
			std::shared_ptr<ob::DepthFrame> adepth = aset ? aset->getDepthFrame() : nullptr;
			if (adepth) {
				std::shared_ptr<ob::VideoStreamProfile> cprof = color->getStreamProfile()->as<ob::VideoStreamProfile>();
				OBCameraIntrinsic cin = cprof->getIntrinsic();
				const int w = adepth->getWidth(), h = adepth->getHeight();
				const float scale = adepth->getValueScale();
				const uint16_t *src = reinterpret_cast<const uint16_t *>(adepth->getData());
				{
					std::lock_guard<std::mutex> lock(frame_mutex);
					aligned_depth_mm.resize(w * h);
					for (int i = 0; i < w * h; i++) {
						float mm = src[i] * scale;
						aligned_depth_mm[i] = mm > 65535.0f ? 0 : static_cast<uint16_t>(mm);
					}
					aligned_w = w;
					aligned_h = h;
					col_fx = cin.fx;
					col_fy = cin.fy;
					col_cx = cin.cx;
					col_cy = cin.cy;
					if (color->getFormat() == OB_FORMAT_RGB) {
						const int cw = color->getWidth(), ch = color->getHeight();
						const uint8_t *cdata = static_cast<const uint8_t *>(color->getData());
						color_rgb.assign(cdata, cdata + cw * ch * 3);
						color_w = cw;
						color_h = ch;
						color_frame_id++;
						color_ts_ms = color->getTimeStampUs() / 1000.0;
					}
				}
				// The blob tracker keeps working on the aligned depth (downsampled 4x).
				const int ds = 4;
				std::vector<uint16_t> small((w / ds) * (h / ds));
				for (int v = 0; v < h / ds; v++) {
					for (int u = 0; u < w / ds; u++) {
						float mm = src[(v * ds + ds / 2) * w + u * ds + ds / 2] * scale;
						small[v * (w / ds) + u] = mm > 65535.0f ? 0 : static_cast<uint16_t>(mm);
					}
				}
				std::lock_guard<std::mutex> lock(frame_mutex);
				latest_depth = std::move(small);
				latest_w = w / ds;
				latest_h = h / ds;
				source_w = w;
				source_h = h;
				latest_fx = cin.fx / ds;
				latest_fy = cin.fy / ds;
				latest_cx = cin.cx / ds;
				latest_cy = cin.cy / ds;
				latest_ts = adepth->getTimeStampUs();
				has_new_frame = true;
				frames_received++;
				return;
			}
		} catch (const ob::Error &e) {
			godot::UtilityFunctions::push_warning("OrbbecCamera: align failed: ", e.what());
		}
	}
	std::shared_ptr<ob::VideoStreamProfile> profile = depth->getStreamProfile()->as<ob::VideoStreamProfile>();
	OBCameraIntrinsic in = profile->getIntrinsic();
	on_depth(reinterpret_cast<const uint16_t *>(depth->getData()), depth->getWidth(), depth->getHeight(),
			depth->getValueScale(), in.fx, in.fy, in.cx, in.cy, depth->getTimeStampUs());
}

godot::Ref<godot::Image> OrbbecCamera::get_color_image() {
	godot::PackedByteArray data;
	int w, h;
	{
		std::lock_guard<std::mutex> lock(frame_mutex);
		if (color_w == 0 || color_rgb.empty()) {
			return godot::Ref<godot::Image>();
		}
		w = color_w;
		h = color_h;
		data.resize(color_rgb.size());
		std::memcpy(data.ptrw(), color_rgb.data(), color_rgb.size());
	}
	return godot::Image::create_from_data(w, h, false, godot::Image::FORMAT_RGB8, data);
}

int OrbbecCamera::get_color_width() const { return color_w; }
int OrbbecCamera::get_color_height() const { return color_h; }
int OrbbecCamera::get_color_frame_id() const { return color_frame_id; }
double OrbbecCamera::get_timestamp() const { return color_ts_ms; }

float OrbbecCamera::get_depth_at(int x, int y, int radius) const {
	return get_depth_percentile(x, y, radius, 0.5f);
}

float OrbbecCamera::get_depth_percentile(int x, int y, int radius, float percentile) const {
	std::lock_guard<std::mutex> lock(const_cast<std::mutex &>(frame_mutex));
	if (aligned_w == 0) {
		return 0.0f;
	}
	std::vector<uint16_t> samples;
	samples.reserve((2 * radius + 1) * (2 * radius + 1));
	for (int dy = -radius; dy <= radius; dy++) {
		for (int dx = -radius; dx <= radius; dx++) {
			int u = x + dx, v = y + dy;
			if (u < 0 || v < 0 || u >= aligned_w || v >= aligned_h) {
				continue;
			}
			uint16_t d = aligned_depth_mm[v * aligned_w + u];
			if (d >= 250 && d <= 6000) {
				samples.push_back(d);
			}
		}
	}
	if (samples.empty()) {
		return 0.0f;
	}
	size_t k = static_cast<size_t>(std::max(0.0f, std::min(1.0f, percentile)) * (samples.size() - 1));
	std::nth_element(samples.begin(), samples.begin() + k, samples.end());
	return samples[k] / 1000.0f;
}

godot::Vector3 OrbbecCamera::deproject_pixel(float x, float y, float depth_m) const {
	if (col_fx <= 0.0f) {
		return godot::Vector3(0, 0, depth_m);
	}
	return godot::Vector3((x - col_cx) / col_fx * depth_m, -(y - col_cy) / col_fy * depth_m, depth_m);
}

godot::PackedFloat32Array OrbbecCamera::get_intrinsics() const {
	godot::PackedFloat32Array a;
	a.push_back(col_fx);
	a.push_back(col_fy);
	a.push_back(col_cx);
	a.push_back(col_cy);
	return a;
}

// Runs on the SDK's thread: downsample into millimetres and hand over.
void OrbbecCamera::on_depth(const uint16_t *data, int width, int height, float scale_mm, float fx, float fy, float cx, float cy, uint64_t timestamp_us) {
	const int ds = downsample;
	const int w = width / ds, h = height / ds;
	std::lock_guard<std::mutex> lock(frame_mutex);
	latest_depth.resize(w * h);
	for (int v = 0; v < h; v++) {
		const uint16_t *row = data + (v * ds + ds / 2) * width;
		uint16_t *out = latest_depth.data() + v * w;
		for (int u = 0; u < w; u++) {
			float mm = row[u * ds + ds / 2] * scale_mm;
			out[u] = mm > 65535.0f ? 0 : static_cast<uint16_t>(mm);
		}
	}
	latest_w = w;
	latest_h = h;
	source_w = width;
	source_h = height;
	latest_fx = fx / ds;
	latest_fy = fy / ds;
	latest_cx = cx / ds;
	latest_cy = cy / ds;
	latest_ts = timestamp_us;
	has_new_frame = true;
	frames_received++;
}

void OrbbecCamera::_process(double) {
	if (!running) {
		return;
	}
	std::vector<uint16_t> depth;
	int w, h;
	float fx, fy, cx, cy;
	uint64_t ts;
	{
		std::lock_guard<std::mutex> lock(frame_mutex);
		if (!has_new_frame) {
			return;
		}
		has_new_frame = false;
		depth = latest_depth;
		w = latest_w;
		h = latest_h;
		fx = latest_fx;
		fy = latest_fy;
		cx = latest_cx;
		cy = latest_cy;
		ts = latest_ts;
	}
	tracker.set_intrinsics(fx, fy, cx, cy, w, h);
	tracker.process(depth.data(), ts / 1e6);
	tracked_count = static_cast<int>(tracker.bodies().size());
	if (debug_enabled) {
		last_depth = depth;
		build_debug_image();
	}
	emit_signal("frame_received", bodies_to_array());
}

void OrbbecCamera::set_debug_enabled(bool enabled) {
	debug_enabled = enabled;
	if (!enabled) {
		debug_image.unref();
	}
}

godot::Ref<godot::Image> OrbbecCamera::get_debug_image() const {
	return debug_image;
}

namespace {
void put_marker(godot::PackedByteArray &rgb, int w, int h, int u, int v, uint8_t r, uint8_t g, uint8_t b, int size) {
	for (int dy = -size; dy <= size; dy++) {
		for (int dx = -size; dx <= size; dx++) {
			int x = u + dx, y = v + dy;
			if (x < 0 || y < 0 || x >= w || y >= h) {
				continue;
			}
			uint8_t *px = rgb.ptrw() + (y * w + x) * 3;
			px[0] = r; px[1] = g; px[2] = b;
		}
	}
}
} // namespace

// Depth as grey (near bright), foreground pixels tinted, remembered bodies outlined,
// hand tips red/green, head yellow, centroid cyan.
void OrbbecCamera::build_debug_image() {
	const int w = tracker.frame_width(), h = tracker.frame_height();
	if (w == 0 || static_cast<int>(last_depth.size()) < w * h) {
		return;
	}
	godot::PackedByteArray rgb;
	rgb.resize(w * h * 3);
	const std::vector<uint8_t> &fg = tracker.foreground_mask();
	const std::vector<int32_t> &labels = tracker.label_map();
	uint8_t *out = rgb.ptrw();
	for (int i = 0; i < w * h; i++) {
		uint16_t d = last_depth[i];
		uint8_t grey = 0;
		if (d != 0) {
			float t = (4000.0f - std::min<float>(d, 4000.0f)) / 3500.0f;  // 0.5 m -> 1, 4 m -> 0
			grey = static_cast<uint8_t>(std::max(0.0f, std::min(1.0f, t)) * 200.0f);
		}
		uint8_t r = grey, g = grey, b = grey;
		if (i < static_cast<int>(fg.size()) && fg[i]) {
			int lab = i < static_cast<int>(labels.size()) ? labels[i] : -1;
			// Tint by label so separate blobs read as separate colours.
			switch (lab % 4) {
				case 0: r = grey / 2; g = std::min(255, grey + 90); b = grey / 2; break;
				case 1: r = std::min(255, grey + 90); g = grey / 2; b = grey / 2; break;
				case 2: r = grey / 2; g = grey / 2; b = std::min(255, grey + 110); break;
				default: r = std::min(255, grey + 80); g = std::min(255, grey + 80); b = grey / 2; break;
			}
		}
		out[i * 3] = r; out[i * 3 + 1] = g; out[i * 3 + 2] = b;
	}
	for (const TrackedBody &body : tracker.bodies()) {
		// Bounding box in white.
		for (int x = body.bbox_x; x < body.bbox_x + body.bbox_w; x++) {
			put_marker(rgb, w, h, x, body.bbox_y, 255, 255, 255, 0);
			put_marker(rgb, w, h, x, body.bbox_y + body.bbox_h - 1, 255, 255, 255, 0);
		}
		for (int y = body.bbox_y; y < body.bbox_y + body.bbox_h; y++) {
			put_marker(rgb, w, h, body.bbox_x, y, 255, 255, 255, 0);
			put_marker(rgb, w, h, body.bbox_x + body.bbox_w - 1, y, 255, 255, 255, 0);
		}
		int u, v;
		tracker.project(body.centroid, u, v);
		put_marker(rgb, w, h, u, v, 0, 255, 255, 2);
		tracker.project(body.head, u, v);
		put_marker(rgb, w, h, u, v, 255, 230, 0, 2);
		tracker.project(body.spine_shoulder, u, v);
		put_marker(rgb, w, h, u, v, 255, 255, 255, 1);
		if (body.hand_left_found) {
			tracker.project(body.hand_left, u, v);
			put_marker(rgb, w, h, u, v, 255, 60, 60, 3);
		}
		if (body.hand_right_found) {
			tracker.project(body.hand_right, u, v);
			put_marker(rgb, w, h, u, v, 60, 255, 60, 3);
		}
	}
	debug_image = godot::Image::create_from_data(w, h, false, godot::Image::FORMAT_RGB8, rgb);
}

godot::Array OrbbecCamera::bodies_to_array() const {
	godot::Array out;
	for (const TrackedBody &b : tracker.bodies()) {
		godot::Dictionary joints;
		joints["SpineBase"] = joint(b.centroid);
		joints["SpineShoulder"] = joint(b.spine_shoulder);
		joints["Head"] = joint(b.head);
		joints["HandLeft"] = joint(b.hand_left);
		joints["HandRight"] = joint(b.hand_right);
		joints["FootLeft"] = joint(b.bottom);
		joints["FootRight"] = joint(b.bottom);

		godot::Dictionary hands;
		hands["l"] = b.hand_left_found ? "tracked" : "rest";
		hands["r"] = b.hand_right_found ? "tracked" : "rest";

		godot::PackedByteArray mask;
		mask.resize(b.mask.size());
		std::memcpy(mask.ptrw(), b.mask.data(), b.mask.size());
		godot::Dictionary silhouette;
		silhouette["w"] = b.bbox_w;
		silhouette["h"] = b.bbox_h;
		silhouette["cx"] = b.center_px_x;
		silhouette["cy"] = b.center_px_y;
		silhouette["data"] = mask;

		godot::Dictionary entry;
		entry["id"] = godot::String::num_int64(b.id);
		entry["hands"] = hands;
		entry["hands_up"] = b.hands_up;
		entry["height"] = b.height_baseline;
		entry["joints"] = joints;
		entry["silhouette"] = silhouette;
		out.push_back(entry);
	}
	return out;
}

} // namespace wizardwars
