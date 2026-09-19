#ifndef WIZARD_WARS_WEBCAM_BACKEND_H
#define WIZARD_WARS_WEBCAM_BACKEND_H

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace wizardwars {

/// One platform's way of reading an ordinary webcam: Media Foundation on
/// Windows (webcam_backend_win.cpp), V4L2 on Linux (webcam_backend_v4l2.cpp).
/// Frames arrive on the backend's own thread.
class WebcamBackend {
public:
	enum class Pixels {
		RGB8, // tightly packed, top row first
		JPEG, // one complete JPEG image (Huffman tables included)
	};
	/// `data` is only valid during the call.
	using FrameCallback = std::function<void(const uint8_t *data, size_t size, int width, int height, Pixels pixels)>;

	virtual ~WebcamBackend() = default;
	/// Opens the device_index-th camera of list_devices() near the wanted mode and starts streaming.
	virtual bool open(int device_index, int width, int height, int fps, FrameCallback on_frame, std::string &error) = 0;
	virtual void close() = 0;
	/// False once the device stopped delivering: unplugged, or taken by something else.
	virtual bool is_alive() const = 0;
	virtual std::string device_name() const = 0;
	virtual std::string last_error() const = 0;

	/// Names of the cameras that can be opened, in open() index order.
	static std::vector<std::string> list_devices();
	/// Null on a platform without a backend.
	static std::unique_ptr<WebcamBackend> create();
};

} // namespace wizardwars

#endif // WIZARD_WARS_WEBCAM_BACKEND_H
