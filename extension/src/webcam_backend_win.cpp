#if defined(_WIN32)

// Webcam capture through Media Foundation's source reader.
//
// Two things keep this from becoming a dependency of the whole extension:
//   - the three Media Foundation DLLs are loaded at run time, so a Windows
//     without them (the N editions, a bare server) loses webcams and nothing
//     else - the depth camera path still loads;
//   - <initguid.h> turns every GUID the headers declare into a definition in
//     this one file, so nothing has to be linked from mfuuid.

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <initguid.h>

#include "webcam_backend.h"
#include "webcam_convert.h"

#include <windows.h>

#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>

#include <atomic>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <mutex>
#include <thread>

namespace wizardwars {

namespace {

template <class T>
void release(T *&p) {
	if (p != nullptr) {
		p->Release();
		p = nullptr;
	}
}

std::string narrow(const wchar_t *wide) {
	if (wide == nullptr) {
		return "";
	}
	const int bytes = WideCharToMultiByte(CP_UTF8, 0, wide, -1, nullptr, 0, nullptr, nullptr);
	if (bytes <= 1) {
		return "";
	}
	std::string out(static_cast<size_t>(bytes - 1), '\0');
	WideCharToMultiByte(CP_UTF8, 0, wide, -1, &out[0], bytes, nullptr, nullptr);
	return out;
}

std::string hresult_text(const std::string &what, HRESULT hr) {
	if (hr == E_ACCESSDENIED) {
		return what + ": access denied. Allow desktop apps to use the camera in Windows Settings > Privacy & security > Camera";
	}
	if (hr == static_cast<HRESULT>(0xC00D3704) || hr == HRESULT_FROM_WIN32(ERROR_SHARING_VIOLATION)) {
		return what + ": the camera is in use by another app";
	}
	char code[32];
	std::snprintf(code, sizeof(code), " (0x%08lX)", static_cast<unsigned long>(hr));
	return what + code;
}

/// The handful of flat functions Media Foundation needs; everything else is COM.
struct MfApi {
	HRESULT(WINAPI *Startup)(ULONG, DWORD) = nullptr;
	HRESULT(WINAPI *Shutdown)() = nullptr;
	HRESULT(WINAPI *CreateAttributes)(IMFAttributes **, UINT32) = nullptr;
	HRESULT(WINAPI *CreateMediaType)(IMFMediaType **) = nullptr;
	HRESULT(WINAPI *EnumDeviceSources)(IMFAttributes *, IMFActivate ***, UINT32 *) = nullptr;
	HRESULT(WINAPI *CreateSourceReaderFromMediaSource)(IMFMediaSource *, IMFAttributes *, IMFSourceReader **) = nullptr;
	bool ok = false;
	std::string error;

	template <class F>
	bool bind(HMODULE module, const char *name, F &target) {
		target = module != nullptr ? reinterpret_cast<F>(reinterpret_cast<void *>(GetProcAddress(module, name))) : nullptr;
		return target != nullptr;
	}

	MfApi() {
		HMODULE mfplat = LoadLibraryW(L"mfplat.dll");
		HMODULE mf = LoadLibraryW(L"mf.dll");
		HMODULE mfreadwrite = LoadLibraryW(L"mfreadwrite.dll");
		ok = bind(mfplat, "MFStartup", Startup);
		ok = bind(mfplat, "MFShutdown", Shutdown) && ok;
		ok = bind(mfplat, "MFCreateAttributes", CreateAttributes) && ok;
		ok = bind(mfplat, "MFCreateMediaType", CreateMediaType) && ok;
		ok = bind(mf, "MFEnumDeviceSources", EnumDeviceSources) && ok;
		ok = bind(mfreadwrite, "MFCreateSourceReaderFromMediaSource", CreateSourceReaderFromMediaSource) && ok;
		if (!ok) {
			error = "Media Foundation is not installed on this Windows (webcams need it; on an N edition install the Media Feature Pack)";
		}
	}
};

MfApi &mf_api() {
	static MfApi api;
	return api;
}

/// COM and Media Foundation for the lifetime of one thread's work.
struct MfSession {
	bool com = false;
	bool started = false;
	std::string error;

	MfSession() {
		const HRESULT com_hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
		com = com_hr == S_OK || com_hr == S_FALSE;
		MfApi &api = mf_api();
		if (!api.ok) {
			error = api.error;
			return;
		}
		const HRESULT hr = api.Startup(MF_VERSION, MFSTARTUP_LITE);
		started = SUCCEEDED(hr);
		if (!started) {
			error = hresult_text("Media Foundation did not start", hr);
		}
	}

	~MfSession() {
		if (started) {
			mf_api().Shutdown();
		}
		if (com) {
			CoUninitialize();
		}
	}
};

HRESULT enumerate_cameras(IMFActivate ***devices, UINT32 *count) {
	*devices = nullptr;
	*count = 0;
	IMFAttributes *attributes = nullptr;
	HRESULT hr = mf_api().CreateAttributes(&attributes, 1);
	if (SUCCEEDED(hr)) {
		hr = attributes->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
	}
	if (SUCCEEDED(hr)) {
		hr = mf_api().EnumDeviceSources(attributes, devices, count);
	}
	release(attributes);
	return hr;
}

void free_cameras(IMFActivate **devices, UINT32 count) {
	if (devices == nullptr) {
		return;
	}
	for (UINT32 i = 0; i < count; i++) {
		release(devices[i]);
	}
	CoTaskMemFree(devices);
}

std::string friendly_name(IMFActivate *device) {
	wchar_t *name = nullptr;
	UINT32 length = 0;
	std::string out = "camera";
	if (SUCCEEDED(device->GetAllocatedString(MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME, &name, &length)) && name != nullptr) {
		out = narrow(name);
	}
	CoTaskMemFree(name);
	return out;
}

void unpack(UINT64 packed, UINT32 &high, UINT32 &low) {
	high = static_cast<UINT32>(packed >> 32);
	low = static_cast<UINT32>(packed & 0xFFFFFFFFu);
}

class MediaFoundationWebcam : public WebcamBackend {
public:
	~MediaFoundationWebcam() override { close(); }

	bool open(int device_index, int width, int height, int fps, FrameCallback on_frame, std::string &error) override {
		close();
		callback = std::move(on_frame);
		stop_requested = false;
		alive = false;
		{
			std::lock_guard<std::mutex> lock(state_mutex);
			phase = Phase::OPENING;
			problem.clear();
			name.clear();
		}
		worker = std::thread(&MediaFoundationWebcam::run, this, device_index, width, height, fps);
		std::unique_lock<std::mutex> lock(state_mutex);
		phase_changed.wait(lock, [this] { return phase != Phase::OPENING; });
		if (phase == Phase::FAILED) {
			error = problem;
			lock.unlock();
			worker.join();
			return false;
		}
		return true;
	}

	void close() override {
		stop_requested = true;
		if (worker.joinable()) {
			worker.join();
		}
		alive = false;
	}

	bool is_alive() const override { return alive; }

	std::string device_name() const override {
		std::lock_guard<std::mutex> lock(state_mutex);
		return name;
	}

	std::string last_error() const override {
		std::lock_guard<std::mutex> lock(state_mutex);
		return problem;
	}

private:
	enum class Phase { IDLE, OPENING, STREAMING, FAILED };
	enum class Layout { BGRX, YUY2, NV12 };

	struct Format {
		Layout layout = Layout::BGRX;
		int width = 0;
		int height = 0;
		LONG stride = 0; // from the media type; negative for a bottom-up bitmap
	};

	void set_phase(Phase next, const std::string &text = "") {
		{
			std::lock_guard<std::mutex> lock(state_mutex);
			phase = next;
			if (!text.empty()) {
				problem = text;
			}
		}
		phase_changed.notify_all();
	}

	/// Picks the native mode nearest to what was asked for. Uncompressed wins a
	/// tie; anything the reader cannot turn into pixels (H.264 and friends) loses.
	static bool choose_native_type(IMFSourceReader *reader, int want_w, int want_h, int want_fps, IMFMediaType **chosen) {
		double best_cost = 1e18;
		*chosen = nullptr;
		for (DWORD i = 0;; i++) {
			IMFMediaType *type = nullptr;
			if (FAILED(reader->GetNativeMediaType(static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), i, &type))) {
				break;
			}
			UINT64 size = 0, rate = 0;
			GUID subtype = {};
			type->GetUINT64(MF_MT_FRAME_SIZE, &size);
			type->GetUINT64(MF_MT_FRAME_RATE, &rate);
			type->GetGUID(MF_MT_SUBTYPE, &subtype);
			UINT32 w = 0, h = 0, num = 0, den = 0;
			unpack(size, w, h);
			unpack(rate, num, den);
			if (w == 0 || h == 0) {
				release(type);
				continue;
			}
			const double fps = den > 0 ? static_cast<double>(num) / den : 30.0;
			double cost = std::fabs(std::log((static_cast<double>(w) * h) / (static_cast<double>(want_w) * want_h))) * 1000.0;
			cost += std::fabs(static_cast<double>(w) / h - static_cast<double>(want_w) / want_h) * 100.0;
			cost += fps < want_fps ? (want_fps - fps) * 20.0 : (fps - want_fps) * 1.0;
			if (subtype == MFVideoFormat_MJPG) {
				cost += 5.0;
			} else if (subtype != MFVideoFormat_YUY2 && subtype != MFVideoFormat_NV12 && subtype != MFVideoFormat_RGB32 &&
					subtype != MFVideoFormat_RGB24 && subtype != MFVideoFormat_I420 && subtype != MFVideoFormat_UYVY) {
				cost += 5000.0;
			}
			if (cost < best_cost) {
				best_cost = cost;
				release(*chosen);
				*chosen = type;
			} else {
				release(type);
			}
		}
		return *chosen != nullptr;
	}

	static bool read_format(IMFSourceReader *reader, Format &format) {
		IMFMediaType *type = nullptr;
		if (FAILED(reader->GetCurrentMediaType(static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), &type))) {
			return false;
		}
		UINT64 size = 0;
		GUID subtype = {};
		type->GetUINT64(MF_MT_FRAME_SIZE, &size);
		type->GetGUID(MF_MT_SUBTYPE, &subtype);
		UINT32 w = 0, h = 0;
		unpack(size, w, h);
		format.width = static_cast<int>(w);
		format.height = static_cast<int>(h);
		if (subtype == MFVideoFormat_RGB32 || subtype == MFVideoFormat_ARGB32) {
			format.layout = Layout::BGRX;
		} else if (subtype == MFVideoFormat_YUY2) {
			format.layout = Layout::YUY2;
		} else if (subtype == MFVideoFormat_NV12) {
			format.layout = Layout::NV12;
		} else {
			release(type);
			return false;
		}
		UINT32 stride = 0;
		if (SUCCEEDED(type->GetUINT32(MF_MT_DEFAULT_STRIDE, &stride))) {
			format.stride = static_cast<LONG>(stride);
		} else {
			format.stride = format.layout == Layout::BGRX ? format.width * 4 : (format.layout == Layout::YUY2 ? format.width * 2 : format.width);
		}
		release(type);
		return format.width > 0 && format.height > 0;
	}

	/// Opens the camera and leaves `reader` delivering a pixel layout this file can convert.
	std::string configure(int device_index, int want_w, int want_h, int want_fps,
			IMFMediaSource **source, IMFSourceReader **reader, Format &format) {
		MfApi &api = mf_api();
		IMFActivate **devices = nullptr;
		UINT32 count = 0;
		HRESULT hr = enumerate_cameras(&devices, &count);
		if (FAILED(hr)) {
			return hresult_text("could not list cameras", hr);
		}
		if (count == 0) {
			free_cameras(devices, count);
			return "no webcam found";
		}
		if (device_index < 0 || device_index >= static_cast<int>(count)) {
			device_index = 0;
		}
		const std::string camera = friendly_name(devices[device_index]);
		{
			std::lock_guard<std::mutex> lock(state_mutex);
			name = camera;
		}
		hr = devices[device_index]->ActivateObject(IID_PPV_ARGS(source));
		free_cameras(devices, count);
		if (FAILED(hr)) {
			return hresult_text("could not open " + camera, hr);
		}

		IMFAttributes *options = nullptr;
		hr = api.CreateAttributes(&options, 2);
		if (SUCCEEDED(hr)) {
			// Lets the reader decode MJPG and convert whatever the camera sends to RGB32.
			options->SetUINT32(MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING, TRUE);
			hr = api.CreateSourceReaderFromMediaSource(*source, options, reader);
		}
		release(options);
		if (FAILED(hr)) {
			return hresult_text("could not read from " + camera, hr);
		}

		const DWORD stream = static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM);
		IMFMediaType *native = nullptr;
		UINT64 native_size = 0, native_rate = 0;
		if (choose_native_type(*reader, want_w, want_h, want_fps, &native)) {
			native->GetUINT64(MF_MT_FRAME_SIZE, &native_size);
			native->GetUINT64(MF_MT_FRAME_RATE, &native_rate);
			(*reader)->SetCurrentMediaType(stream, nullptr, native);
			release(native);
		}

		// A camera whose smallest mode is still large (some only do 1080p and up) would
		// cost a 6 MB copy per frame for a pose model that looks at 256x192: ask the
		// reader's video processor to scale it down. Refused? The native size is next.
		UINT64 scaled_size = 0;
		UINT32 native_w = 0, native_h = 0;
		unpack(native_size, native_w, native_h);
		if (native_w > 1280 && native_h > 0) {
			const UINT32 w = 960;
			const UINT32 h = (static_cast<UINT32>(static_cast<UINT64>(native_h) * w / native_w) + 1u) & ~1u;
			scaled_size = (static_cast<UINT64>(w) << 32) | h;
		}

		// RGB32 first; the two YUV layouts cover a Windows whose video processor is missing.
		const GUID outputs[] = { MFVideoFormat_RGB32, MFVideoFormat_YUY2, MFVideoFormat_NV12 };
		bool configured = false;
		for (const GUID &subtype : outputs) {
			// 2: scaled down, 1: the native size, 0: whatever the reader picks.
			for (int with_size = 2; with_size >= 0 && !configured; with_size--) {
				const UINT64 size = with_size == 2 ? scaled_size : (with_size == 1 ? native_size : 0);
				if (with_size > 0 && size == 0) {
					continue;
				}
				IMFMediaType *wanted = nullptr;
				if (FAILED(api.CreateMediaType(&wanted))) {
					continue;
				}
				wanted->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
				wanted->SetGUID(MF_MT_SUBTYPE, subtype);
				if (with_size > 0) {
					wanted->SetUINT64(MF_MT_FRAME_SIZE, size);
					if (native_rate != 0) {
						wanted->SetUINT64(MF_MT_FRAME_RATE, native_rate);
					}
				}
				configured = SUCCEEDED((*reader)->SetCurrentMediaType(stream, nullptr, wanted)) && read_format(*reader, format);
				release(wanted);
			}
			if (configured) {
				break;
			}
		}
		if (!configured && !read_format(*reader, format)) {
			return camera + " offers no video format this build can convert";
		}
		(*reader)->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS), FALSE);
		(*reader)->SetStreamSelection(stream, TRUE);
		return "";
	}

	void deliver(IMFSample *sample, const Format &format) {
		IMFMediaBuffer *buffer = nullptr;
		if (FAILED(sample->ConvertToContiguousBuffer(&buffer))) {
			return;
		}
		const int w = format.width, h = format.height;
		rgb.resize(static_cast<size_t>(w) * h * 3);

		IMF2DBuffer *planar = nullptr;
		BYTE *top = nullptr;
		LONG pitch = 0;
		bool converted = false;
		if (SUCCEEDED(buffer->QueryInterface(IID_PPV_ARGS(&planar))) && SUCCEEDED(planar->Lock2D(&top, &pitch))) {
			convert(format.layout, top, pitch, w, h);
			planar->Unlock2D();
			converted = true;
		}
		release(planar);
		if (!converted) {
			BYTE *data = nullptr;
			DWORD length = 0;
			if (SUCCEEDED(buffer->Lock(&data, nullptr, &length))) {
				const LONG stride = format.stride;
				const size_t rows = format.layout == Layout::NV12 ? static_cast<size_t>(h) * 3 / 2 : static_cast<size_t>(h);
				if (stride != 0 && static_cast<size_t>(stride < 0 ? -stride : stride) * rows <= length) {
					// A negative stride is a bottom-up bitmap: the top row is the last one in memory.
					const BYTE *first = stride < 0 ? data + static_cast<size_t>(-stride) * (h - 1) : data;
					convert(format.layout, first, stride, w, h);
					converted = true;
				}
				buffer->Unlock();
			}
		}
		release(buffer);
		if (converted && callback) {
			callback(rgb.data(), rgb.size(), w, h, Pixels::RGB8);
		}
	}

	void convert(Layout layout, const BYTE *top, LONG pitch, int w, int h) {
		switch (layout) {
			case Layout::BGRX:
				webcam::bgrx_to_rgb(top, pitch, w, h, rgb.data());
				break;
			case Layout::YUY2:
				webcam::yuy2_to_rgb(top, pitch, w, h, rgb.data());
				break;
			case Layout::NV12:
				webcam::nv12_to_rgb(top, pitch, w, h, rgb.data());
				break;
		}
	}

	void run(int device_index, int want_w, int want_h, int want_fps) {
		MfSession session;
		if (!session.started) {
			set_phase(Phase::FAILED, session.error);
			return;
		}
		IMFMediaSource *source = nullptr;
		IMFSourceReader *reader = nullptr;
		Format format;
		const std::string failure = configure(device_index, want_w, want_h, want_fps, &source, &reader, format);
		if (!failure.empty()) {
			release(reader);
			if (source != nullptr) {
				source->Shutdown();
			}
			release(source);
			set_phase(Phase::FAILED, failure);
			return;
		}
		alive = true;
		set_phase(Phase::STREAMING);

		const DWORD stream = static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM);
		std::string ended;
		while (!stop_requested) {
			DWORD actual_stream = 0, flags = 0;
			LONGLONG timestamp = 0;
			IMFSample *sample = nullptr;
			const HRESULT hr = reader->ReadSample(stream, 0, &actual_stream, &flags, &timestamp, &sample);
			if (FAILED(hr)) {
				ended = hresult_text("the camera stopped", hr);
				release(sample);
				break;
			}
			if ((flags & MF_SOURCE_READERF_ERROR) != 0 || (flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0) {
				ended = "the camera stopped";
				release(sample);
				break;
			}
			if ((flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) != 0 || (flags & MF_SOURCE_READERF_NATIVEMEDIATYPECHANGED) != 0) {
				if (!read_format(reader, format)) {
					ended = "the camera switched to a format this build cannot convert";
					release(sample);
					break;
				}
			}
			if (sample != nullptr) {
				deliver(sample, format);
				release(sample);
			}
		}
		alive = false;
		release(reader);
		source->Shutdown();
		release(source);
		if (!ended.empty()) {
			std::lock_guard<std::mutex> lock(state_mutex);
			problem = ended;
		}
	}

	FrameCallback callback;
	std::thread worker;
	std::atomic<bool> stop_requested{ false };
	std::atomic<bool> alive{ false };
	mutable std::mutex state_mutex;
	std::condition_variable phase_changed;
	Phase phase = Phase::IDLE;
	std::string problem;
	std::string name;
	std::vector<uint8_t> rgb;
};

} // namespace

std::vector<std::string> WebcamBackend::list_devices() {
	// On a thread of its own: the caller's thread may already live in a COM
	// apartment of a different kind.
	std::vector<std::string> names;
	std::thread worker([&names] {
		MfSession session;
		if (!session.started) {
			return;
		}
		IMFActivate **devices = nullptr;
		UINT32 count = 0;
		if (SUCCEEDED(enumerate_cameras(&devices, &count))) {
			for (UINT32 i = 0; i < count; i++) {
				names.push_back(friendly_name(devices[i]));
			}
		}
		free_cameras(devices, count);
	});
	worker.join();
	return names;
}

std::unique_ptr<WebcamBackend> WebcamBackend::create() {
	return std::unique_ptr<WebcamBackend>(new MediaFoundationWebcam());
}

} // namespace wizardwars

#endif // _WIN32
