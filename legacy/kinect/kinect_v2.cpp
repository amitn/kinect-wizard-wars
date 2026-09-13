#include "kinect_v2.h"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <Kinect.h>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

namespace wizardwars {

namespace {

// Order matches the JointType enum in Kinect.h and JOINT_NAMES in body_data.gd.
const char *const JOINT_NAMES[JointType_Count] = {
	"SpineBase", "SpineMid", "Neck", "Head",
	"ShoulderLeft", "ElbowLeft", "WristLeft", "HandLeft",
	"ShoulderRight", "ElbowRight", "WristRight", "HandRight",
	"HipLeft", "KneeLeft", "AnkleLeft", "FootLeft",
	"HipRight", "KneeRight", "AnkleRight", "FootRight",
	"SpineShoulder", "HandTipLeft", "ThumbLeft", "HandTipRight", "ThumbRight",
};

const char *hand_state_name(HandState state) {
	switch (state) {
		case HandState_Open: return "open";
		case HandState_Closed: return "closed";
		case HandState_Lasso: return "lasso";
		case HandState_NotTracked: return "not_tracked";
		default: return "unknown";
	}
}

template <class T>
void safe_release(T *&ptr) {
	if (ptr != nullptr) {
		ptr->Release();
		ptr = nullptr;
	}
}

// Kinect20.dll is resolved at runtime rather than linked, so the extension still
// loads on machines without the Kinect runtime (they just report "no sensor").
// GetDefaultKinectSensor is the only exported function used; everything else
// goes through COM vtables.
typedef HRESULT(WINAPI *GetDefaultKinectSensorFn)(IKinectSensor **);

HMODULE kinect_module = nullptr;
GetDefaultKinectSensorFn get_default_sensor = nullptr;

bool load_kinect_runtime(godot::String &error) {
	if (get_default_sensor != nullptr) {
		return true;
	}
	if (kinect_module == nullptr) {
		kinect_module = LoadLibraryW(L"Kinect20.dll");
	}
	if (kinect_module == nullptr) {
		error = "Kinect20.dll not found; install the Kinect for Windows Runtime or SDK 2.0";
		return false;
	}
	get_default_sensor = reinterpret_cast<GetDefaultKinectSensorFn>(GetProcAddress(kinect_module, "GetDefaultKinectSensor"));
	if (get_default_sensor == nullptr) {
		error = "Kinect20.dll has no GetDefaultKinectSensor export";
		return false;
	}
	return true;
}

} // namespace

KinectV2::KinectV2() {
	// Keep polling even while the game is paused so tracking never goes stale.
	set_process_mode(PROCESS_MODE_ALWAYS);
}

KinectV2::~KinectV2() {
	stop();
}

void KinectV2::_bind_methods() {
	using godot::D_METHOD;
	godot::ClassDB::bind_method(D_METHOD("start"), &KinectV2::start);
	godot::ClassDB::bind_method(D_METHOD("stop"), &KinectV2::stop);
	godot::ClassDB::bind_method(D_METHOD("is_running"), &KinectV2::is_running);
	godot::ClassDB::bind_method(D_METHOD("is_available"), &KinectV2::is_available);
	godot::ClassDB::bind_method(D_METHOD("get_tracked_body_count"), &KinectV2::get_tracked_body_count);
	godot::ClassDB::bind_method(D_METHOD("get_last_error"), &KinectV2::get_last_error);

	ADD_SIGNAL(godot::MethodInfo("frame_received", godot::PropertyInfo(godot::Variant::ARRAY, "bodies")));
}

bool KinectV2::start() {
	if (reader != nullptr) {
		return true;
	}
	last_error = "";
	if (!load_kinect_runtime(last_error)) {
		return false;
	}

	HRESULT hr = get_default_sensor(&sensor);
	if (FAILED(hr) || sensor == nullptr) {
		last_error = "GetDefaultKinectSensor failed; is the Kinect runtime installed and the sensor on USB 3.0?";
		return false;
	}
	hr = sensor->Open();
	if (FAILED(hr)) {
		last_error = "IKinectSensor::Open failed";
		safe_release(sensor);
		return false;
	}

	IBodyFrameSource *source = nullptr;
	hr = sensor->get_BodyFrameSource(&source);
	if (SUCCEEDED(hr) && source != nullptr) {
		hr = source->OpenReader(&reader);
	}
	safe_release(source);
	if (FAILED(hr) || reader == nullptr) {
		last_error = "could not open the body frame reader";
		sensor->Close();
		safe_release(sensor);
		return false;
	}

	godot::UtilityFunctions::print("KinectV2: sensor opened");
	return true;
}

void KinectV2::stop() {
	safe_release(reader);
	if (sensor != nullptr) {
		sensor->Close();
		safe_release(sensor);
	}
	tracked_body_count = 0;
}

bool KinectV2::is_running() const {
	return reader != nullptr;
}

bool KinectV2::is_available() const {
	if (sensor == nullptr) {
		return false;
	}
	BOOLEAN available = FALSE;
	return SUCCEEDED(sensor->get_IsAvailable(&available)) && available;
}

int KinectV2::get_tracked_body_count() const {
	return tracked_body_count;
}

godot::String KinectV2::get_last_error() const {
	return last_error;
}

void KinectV2::_process(double) {
	if (reader == nullptr) {
		return;
	}
	// Drain everything queued; only the newest frame is worth emitting.
	while (poll_frame()) {
	}
}

bool KinectV2::poll_frame() {
	IBodyFrame *frame = nullptr;
	if (FAILED(reader->AcquireLatestFrame(&frame)) || frame == nullptr) {
		return false;
	}

	IBody *bodies[BODY_COUNT] = {};
	HRESULT hr = frame->GetAndRefreshBodyData(_countof(bodies), bodies);
	safe_release(frame);
	if (FAILED(hr)) {
		return false;
	}

	godot::Array out;
	for (IBody *body : bodies) {
		if (body == nullptr) {
			continue;
		}
		BOOLEAN tracked = FALSE;
		if (SUCCEEDED(body->get_IsTracked(&tracked)) && tracked) {
			Joint joints[JointType_Count];
			if (SUCCEEDED(body->GetJoints(_countof(joints), joints))) {
				UINT64 tracking_id = 0;
				body->get_TrackingId(&tracking_id);
				HandState left = HandState_Unknown;
				HandState right = HandState_Unknown;
				body->get_HandLeftState(&left);
				body->get_HandRightState(&right);

				godot::Dictionary joint_dict;
				for (int i = 0; i < JointType_Count; i++) {
					const Joint &j = joints[i];
					godot::Array pos;
					pos.push_back(j.Position.X);
					pos.push_back(j.Position.Y);
					pos.push_back(j.Position.Z);
					pos.push_back(static_cast<int>(j.TrackingState));
					joint_dict[JOINT_NAMES[i]] = pos;
				}

				godot::Dictionary hands;
				hands["l"] = hand_state_name(left);
				hands["r"] = hand_state_name(right);

				godot::Dictionary entry;
				entry["id"] = godot::String::num_int64(static_cast<int64_t>(tracking_id));
				entry["hands"] = hands;
				entry["joints"] = joint_dict;
				out.push_back(entry);
			}
		}
		body->Release();
	}

	tracked_body_count = out.size();
	emit_signal("frame_received", out);
	return true;
}

} // namespace wizardwars
