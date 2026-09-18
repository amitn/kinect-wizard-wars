#pragma once
// RTMPose inside the extension: ONNX Runtime's C API, no bridge, no Python.
//
// The model is a top-down pose estimator - it expects a crop around one person
// and returns that person's keypoints. It does not find people. In this game it
// does not have to: the depth blob tracker in body_tracker.cpp already knows
// where the people are, so the expensive detector network that usually sits in
// front of RTMPose is replaced by the depth camera doing what it is good at.
//
// Feed it an RGB8 image and a person box in pixels; get back one Vector3 per
// keypoint: (x pixel, y pixel, confidence), in COCO-17 order.

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/rect2.hpp>

#include <vector>

#include "onnxruntime_c_api.h"

class RtmPose : public godot::RefCounted {
	GDCLASS(RtmPose, godot::RefCounted)

public:
	RtmPose();
	~RtmPose();

	// The model comes in as bytes rather than a path so it can live inside an
	// exported .pck, where there is no file for the runtime to open.
	bool initialize(const godot::PackedByteArray &model_bytes, int threads);
	bool is_ready() const { return session != nullptr; }
	godot::String get_last_error() const { return last_error; }

	godot::PackedVector3Array infer(const godot::Ref<godot::Image> &image, const godot::Rect2 &box);

	int get_keypoint_count() const { return keypoint_count; }
	godot::Vector2i get_input_size() const { return godot::Vector2i(input_w, input_h); }
	double get_last_ms() const { return last_ms; }
	double get_preprocess_ms() const { return preprocess_ms; }
	void set_rgb_input(bool p_rgb) { rgb_input = p_rgb; }
	bool get_rgb_input() const { return rgb_input; }
	void set_box_padding(double p_padding) { box_padding = (float)p_padding; }
	double get_box_padding() const { return box_padding; }

protected:
	static void _bind_methods();

private:
	void shutdown();
	bool crop_to_input(const godot::Ref<godot::Image> &image, const godot::Rect2 &box,
			float &out_x0, float &out_y0, float &out_w, float &out_h);

	const OrtApi *api = nullptr;
	OrtEnv *env = nullptr;
	OrtSessionOptions *options = nullptr;
	OrtSession *session = nullptr;
	OrtMemoryInfo *memory = nullptr;

	int input_w = 192;
	int input_h = 256;
	int keypoint_count = 17;
	float split_ratio = 2.0f;
	float box_padding = 1.25f;
	bool rgb_input = true;

	std::vector<float> input_buf;
	double last_ms = 0.0;
	double preprocess_ms = 0.0;
	godot::String last_error;
};
