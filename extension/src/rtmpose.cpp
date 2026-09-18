#include "rtmpose.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>

using namespace godot;

// ImageNet statistics, the normalisation RTMPose was trained with.
static const float MEAN[3] = { 123.675f, 116.28f, 103.53f };
static const float STD[3] = { 58.395f, 57.12f, 57.375f };

// Every OrtStatus the API hands back owns memory, including the ones we do not
// act on, so none of them may simply be dropped.
static void ort_discard(const OrtApi *api, OrtStatus *status) {
	if (status != nullptr) {
		api->ReleaseStatus(status);
	}
}

RtmPose::RtmPose() {
	api = OrtGetApiBase()->GetApi(ORT_API_VERSION);
}

RtmPose::~RtmPose() {
	shutdown();
}

void RtmPose::shutdown() {
	if (api == nullptr) {
		return;
	}
	if (session != nullptr) {
		api->ReleaseSession(session);
		session = nullptr;
	}
	if (options != nullptr) {
		api->ReleaseSessionOptions(options);
		options = nullptr;
	}
	if (memory != nullptr) {
		api->ReleaseMemoryInfo(memory);
		memory = nullptr;
	}
	if (env != nullptr) {
		api->ReleaseEnv(env);
		env = nullptr;
	}
}

// Turns an OrtStatus into our error string; returns true when something failed.
#define ORT_FAILED(expr, what)                                            \
	do {                                                                  \
		OrtStatus *status_ = (expr);                                      \
		if (status_ != nullptr) {                                         \
			last_error = String(what) + ": " + String(api->GetErrorMessage(status_)); \
			api->ReleaseStatus(status_);                                  \
			shutdown();                                                   \
			return false;                                                 \
		}                                                                 \
	} while (0)

bool RtmPose::initialize(const PackedByteArray &model_bytes, int threads) {
	shutdown();
	if (api == nullptr) {
		last_error = "onnxruntime not available";
		return false;
	}
	if (model_bytes.size() < 1024) {
		last_error = "model is empty - run tools/fetch_rtmpose_model.sh";
		return false;
	}

	ORT_FAILED(api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "rtmpose", &env), "CreateEnv");
	ORT_FAILED(api->CreateSessionOptions(&options), "CreateSessionOptions");
	// This runs beside a game loop: leave it cores, do not take them all.
	ort_discard(api, api->SetIntraOpNumThreads(options, threads > 0 ? threads : 2));
	ort_discard(api, api->SetInterOpNumThreads(options, 1));
	ort_discard(api, api->SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL));
	ORT_FAILED(api->CreateSessionFromArray(env, model_bytes.ptr(), (size_t)model_bytes.size(),
					   options, &session),
			"CreateSessionFromArray");
	ORT_FAILED(api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memory), "CreateCpuMemoryInfo");

	// Read the input geometry off the model rather than assuming it.
	OrtTypeInfo *type_info = nullptr;
	if (api->SessionGetInputTypeInfo(session, 0, &type_info) == nullptr) {
		const OrtTensorTypeAndShapeInfo *tensor_info = nullptr;
		if (api->CastTypeInfoToTensorInfo(type_info, &tensor_info) == nullptr && tensor_info != nullptr) {
			size_t dims = 0;
			ort_discard(api, api->GetDimensionsCount(tensor_info, &dims));
			if (dims == 4) {
				int64_t shape[4] = { 0, 0, 0, 0 };
				api->GetDimensions(tensor_info, shape, 4);
				if (shape[2] > 0 && shape[3] > 0) {
					input_h = (int)shape[2];
					input_w = (int)shape[3];
				}
			}
		}
		api->ReleaseTypeInfo(type_info);
	}
	// simcc_x is [1, keypoints, input_w * split_ratio]: both numbers come from it.
	type_info = nullptr;
	if (api->SessionGetOutputTypeInfo(session, 0, &type_info) == nullptr) {
		const OrtTensorTypeAndShapeInfo *tensor_info = nullptr;
		if (api->CastTypeInfoToTensorInfo(type_info, &tensor_info) == nullptr && tensor_info != nullptr) {
			size_t dims = 0;
			ort_discard(api, api->GetDimensionsCount(tensor_info, &dims));
			if (dims == 3) {
				int64_t shape[3] = { 0, 0, 0 };
				ort_discard(api, api->GetDimensions(tensor_info, shape, 3));
				if (shape[1] > 0) {
					keypoint_count = (int)shape[1];
				}
				if (shape[2] > 0 && input_w > 0) {
					split_ratio = (float)shape[2] / (float)input_w;
				}
			}
		}
		api->ReleaseTypeInfo(type_info);
	}

	input_buf.assign((size_t)input_w * input_h * 3, 0.0f);
	last_error = "";
	return true;
}

#undef ORT_FAILED

// The padded, aspect-corrected source rectangle this crop was taken from -
// keypoints come back in input pixels and are mapped home through it.
bool RtmPose::crop_to_input(const Ref<Image> &image, const Rect2 &box,
		float &out_x0, float &out_y0, float &out_w, float &out_h) {
	if (image.is_null() || image->get_format() != Image::FORMAT_RGB8) {
		last_error = "image must be RGB8";
		return false;
	}
	const int img_w = image->get_width();
	const int img_h = image->get_height();
	if (img_w <= 0 || img_h <= 0) {
		last_error = "empty image";
		return false;
	}

	float bw = (float)box.size.x;
	float bh = (float)box.size.y;
	if (bw <= 1.0f || bh <= 1.0f) {
		last_error = "degenerate box";
		return false;
	}
	const float cx = (float)box.position.x + bw * 0.5f;
	const float cy = (float)box.position.y + bh * 0.5f;
	const float aspect = (float)input_w / (float)input_h;
	if (bw / bh > aspect) {
		bh = bw / aspect;
	} else {
		bw = bh * aspect;
	}
	bw *= box_padding;
	bh *= box_padding;
	out_x0 = cx - bw * 0.5f;
	out_y0 = cy - bh * 0.5f;
	out_w = bw;
	out_h = bh;

	const PackedByteArray data = image->get_data();
	const uint8_t *src = data.ptr();
	const size_t plane = (size_t)input_w * input_h;
	const float sx = bw / (float)input_w;
	const float sy = bh / (float)input_h;

	for (int y = 0; y < input_h; y++) {
		const float fy = out_y0 + ((float)y + 0.5f) * sy - 0.5f;
		const int y0 = (int)std::floor(fy);
		const float wy = fy - (float)y0;
		const int ya = std::clamp(y0, 0, img_h - 1);
		const int yb = std::clamp(y0 + 1, 0, img_h - 1);
		for (int x = 0; x < input_w; x++) {
			const float fx = out_x0 + ((float)x + 0.5f) * sx - 0.5f;
			const int x0 = (int)std::floor(fx);
			const float wx = fx - (float)x0;
			const int xa = std::clamp(x0, 0, img_w - 1);
			const int xb = std::clamp(x0 + 1, 0, img_w - 1);

			const uint8_t *p00 = src + ((size_t)ya * img_w + xa) * 3;
			const uint8_t *p01 = src + ((size_t)ya * img_w + xb) * 3;
			const uint8_t *p10 = src + ((size_t)yb * img_w + xa) * 3;
			const uint8_t *p11 = src + ((size_t)yb * img_w + xb) * 3;

			for (int c = 0; c < 3; c++) {
				const float top = (float)p00[c] + ((float)p01[c] - (float)p00[c]) * wx;
				const float bottom = (float)p10[c] + ((float)p11[c] - (float)p10[c]) * wx;
				const float value = top + (bottom - top) * wy;
				// The model was trained on RGB; the flag is here because an
				// exported graph that already swaps would need this not to.
				const int channel = rgb_input ? c : 2 - c;
				input_buf[(size_t)channel * plane + (size_t)y * input_w + x] =
						(value - MEAN[channel]) / STD[channel];
			}
		}
	}
	return true;
}

PackedVector3Array RtmPose::infer(const Ref<Image> &image, const Rect2 &box) {
	PackedVector3Array out;
	if (session == nullptr) {
		last_error = "not initialized";
		return out;
	}

	const auto pre_start = std::chrono::steady_clock::now();
	float x0 = 0.0f, y0 = 0.0f, bw = 0.0f, bh = 0.0f;
	if (!crop_to_input(image, box, x0, y0, bw, bh)) {
		return out;
	}
	const auto pre_end = std::chrono::steady_clock::now();
	preprocess_ms = std::chrono::duration<double, std::milli>(pre_end - pre_start).count();

	const int64_t shape[4] = { 1, 3, input_h, input_w };
	OrtValue *input_tensor = nullptr;
	if (api->CreateTensorWithDataAsOrtValue(memory, input_buf.data(),
				input_buf.size() * sizeof(float), shape, 4,
				ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &input_tensor) != nullptr) {
		last_error = "could not wrap the input tensor";
		return out;
	}

	const char *input_names[] = { "input" };
	const char *output_names[] = { "simcc_x", "simcc_y" };
	OrtValue *outputs[2] = { nullptr, nullptr };
	OrtStatus *status = api->Run(session, nullptr, input_names, (const OrtValue *const *)&input_tensor, 1,
			output_names, 2, outputs);
	api->ReleaseValue(input_tensor);
	if (status != nullptr) {
		last_error = String("Run: ") + String(api->GetErrorMessage(status));
		api->ReleaseStatus(status);
		return out;
	}
	const auto run_end = std::chrono::steady_clock::now();
	last_ms = std::chrono::duration<double, std::milli>(run_end - pre_start).count();

	float *simcc_x = nullptr;
	float *simcc_y = nullptr;
	ort_discard(api, api->GetTensorMutableData(outputs[0], (void **)&simcc_x));
	ort_discard(api, api->GetTensorMutableData(outputs[1], (void **)&simcc_y));
	const int bins_x = (int)std::lround(input_w * split_ratio);
	const int bins_y = (int)std::lround(input_h * split_ratio);

	if (simcc_x != nullptr && simcc_y != nullptr) {
		out.resize(keypoint_count);
		Vector3 *write = out.ptrw();
		for (int k = 0; k < keypoint_count; k++) {
			// SimCC: one 1-D distribution per axis per keypoint. The peak is the
			// coordinate; the confidence is the weaker of the two peaks, so a
			// keypoint is only as trustworthy as its least certain axis.
			const float *row_x = simcc_x + (size_t)k * bins_x;
			const float *row_y = simcc_y + (size_t)k * bins_y;
			int best_x = 0;
			float best_x_val = row_x[0];
			for (int i = 1; i < bins_x; i++) {
				if (row_x[i] > best_x_val) {
					best_x_val = row_x[i];
					best_x = i;
				}
			}
			int best_y = 0;
			float best_y_val = row_y[0];
			for (int i = 1; i < bins_y; i++) {
				if (row_y[i] > best_y_val) {
					best_y_val = row_y[i];
					best_y = i;
				}
			}
			const float score = std::min(best_x_val, best_y_val);
			if (score <= 0.0f) {
				write[k] = Vector3(-1.0f, -1.0f, 0.0f);
				continue;
			}
			const float px = (float)best_x / split_ratio;
			const float py = (float)best_y / split_ratio;
			write[k] = Vector3(x0 + px * bw / (float)input_w,
					y0 + py * bh / (float)input_h, score);
		}
	}

	api->ReleaseValue(outputs[0]);
	api->ReleaseValue(outputs[1]);
	return out;
}

void RtmPose::_bind_methods() {
	ClassDB::bind_method(D_METHOD("initialize", "model_bytes", "threads"), &RtmPose::initialize, DEFVAL(2));
	ClassDB::bind_method(D_METHOD("is_ready"), &RtmPose::is_ready);
	ClassDB::bind_method(D_METHOD("get_last_error"), &RtmPose::get_last_error);
	ClassDB::bind_method(D_METHOD("infer", "image", "box"), &RtmPose::infer);
	ClassDB::bind_method(D_METHOD("get_keypoint_count"), &RtmPose::get_keypoint_count);
	ClassDB::bind_method(D_METHOD("get_input_size"), &RtmPose::get_input_size);
	ClassDB::bind_method(D_METHOD("get_last_ms"), &RtmPose::get_last_ms);
	ClassDB::bind_method(D_METHOD("get_preprocess_ms"), &RtmPose::get_preprocess_ms);
	ClassDB::bind_method(D_METHOD("set_rgb_input", "enabled"), &RtmPose::set_rgb_input);
	ClassDB::bind_method(D_METHOD("get_rgb_input"), &RtmPose::get_rgb_input);
	ClassDB::bind_method(D_METHOD("set_box_padding", "padding"), &RtmPose::set_box_padding);
	ClassDB::bind_method(D_METHOD("get_box_padding"), &RtmPose::get_box_padding);
}
