#if defined(__linux__)

// Webcam capture through V4L2, memory-mapped streaming. YUYV is asked for
// first because every UVC camera has it at 640x480 and it needs no decoder;
// MJPG frames are handed on as JPEG for Godot's own decoder.

#include "webcam_backend.h"
#include "webcam_convert.h"

#include <linux/videodev2.h>

#include <fcntl.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include <atomic>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <thread>

namespace wizardwars {

namespace {

int xioctl(int fd, unsigned long request, void *arg) {
	int result;
	do {
		result = ioctl(fd, request, arg);
	} while (result == -1 && errno == EINTR);
	return result;
}

struct CaptureNode {
	std::string path;
	std::string name;
};

/// /dev/video* nodes that capture video. A UVC camera also registers a metadata
/// node, which has no capture capability and is skipped.
std::vector<CaptureNode> capture_nodes() {
	std::vector<CaptureNode> nodes;
	for (int i = 0; i < 64; i++) {
		char path[32];
		std::snprintf(path, sizeof(path), "/dev/video%d", i);
		const int fd = ::open(path, O_RDWR | O_NONBLOCK);
		if (fd < 0) {
			continue;
		}
		v4l2_capability cap;
		std::memset(&cap, 0, sizeof(cap));
		if (xioctl(fd, VIDIOC_QUERYCAP, &cap) == 0) {
			const uint32_t caps = (cap.capabilities & V4L2_CAP_DEVICE_CAPS) != 0 ? cap.device_caps : cap.capabilities;
			if ((caps & V4L2_CAP_VIDEO_CAPTURE) != 0 && (caps & V4L2_CAP_STREAMING) != 0) {
				CaptureNode node;
				node.path = path;
				node.name = std::string(reinterpret_cast<const char *>(cap.card)) + " (" + path + ")";
				nodes.push_back(node);
			}
		}
		::close(fd);
	}
	return nodes;
}

bool convertible(uint32_t pixel_format) {
	return pixel_format == V4L2_PIX_FMT_YUYV || pixel_format == V4L2_PIX_FMT_MJPEG || pixel_format == V4L2_PIX_FMT_JPEG ||
			pixel_format == V4L2_PIX_FMT_NV12 || pixel_format == V4L2_PIX_FMT_RGB24 || pixel_format == V4L2_PIX_FMT_BGR24;
}

class V4l2Webcam : public WebcamBackend {
public:
	~V4l2Webcam() override { close(); }

	bool open(int device_index, int width, int height, int fps, FrameCallback on_frame, std::string &error) override {
		close();
		set_problem("");
		const std::vector<CaptureNode> nodes = capture_nodes();
		if (nodes.empty()) {
			error = "no webcam found (/dev/video*)";
			return false;
		}
		if (device_index < 0 || device_index >= static_cast<int>(nodes.size())) {
			device_index = 0;
		}
		name = nodes[device_index].name;
		fd = ::open(nodes[device_index].path.c_str(), O_RDWR | O_NONBLOCK);
		if (fd < 0) {
			error = "could not open " + name + ": " + std::strerror(errno);
			return false;
		}

		// The driver answers S_FMT with what it will really deliver, which may be
		// neither the size nor the pixel format that was asked for.
		bool negotiated = false;
		const uint32_t wanted[] = { V4L2_PIX_FMT_YUYV, V4L2_PIX_FMT_MJPEG };
		for (uint32_t pixel_format : wanted) {
			std::memset(&format, 0, sizeof(format));
			format.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
			format.fmt.pix.width = static_cast<uint32_t>(width);
			format.fmt.pix.height = static_cast<uint32_t>(height);
			format.fmt.pix.pixelformat = pixel_format;
			format.fmt.pix.field = V4L2_FIELD_ANY;
			if (xioctl(fd, VIDIOC_S_FMT, &format) == 0 && convertible(format.fmt.pix.pixelformat)) {
				negotiated = true;
				break;
			}
		}
		if (!negotiated) {
			error = name + " offers no video format this build can convert";
			shutdown();
			return false;
		}

		v4l2_streamparm parm;
		std::memset(&parm, 0, sizeof(parm));
		parm.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
		parm.parm.capture.timeperframe.numerator = 1;
		parm.parm.capture.timeperframe.denominator = static_cast<uint32_t>(fps > 0 ? fps : 30);
		xioctl(fd, VIDIOC_S_PARM, &parm); // best effort: not every driver lets the rate be set

		v4l2_requestbuffers request;
		std::memset(&request, 0, sizeof(request));
		request.count = 4;
		request.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
		request.memory = V4L2_MEMORY_MMAP;
		if (xioctl(fd, VIDIOC_REQBUFS, &request) != 0 || request.count < 2) {
			error = name + ": no capture buffers (" + std::strerror(errno) + ")";
			shutdown();
			return false;
		}
		for (uint32_t i = 0; i < request.count; i++) {
			v4l2_buffer buffer;
			std::memset(&buffer, 0, sizeof(buffer));
			buffer.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
			buffer.memory = V4L2_MEMORY_MMAP;
			buffer.index = i;
			if (xioctl(fd, VIDIOC_QUERYBUF, &buffer) != 0) {
				error = name + ": could not query a capture buffer";
				shutdown();
				return false;
			}
			void *memory = mmap(nullptr, buffer.length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, buffer.m.offset);
			if (memory == MAP_FAILED) {
				error = name + ": could not map a capture buffer";
				shutdown();
				return false;
			}
			Mapping mapping;
			mapping.memory = memory;
			mapping.length = buffer.length;
			mappings.push_back(mapping);
			if (xioctl(fd, VIDIOC_QBUF, &buffer) != 0) {
				error = name + ": could not queue a capture buffer";
				shutdown();
				return false;
			}
		}
		int type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
		if (xioctl(fd, VIDIOC_STREAMON, &type) != 0) {
			error = name + ": could not start streaming (" + std::strerror(errno) + ")";
			shutdown();
			return false;
		}
		streaming = true;
		callback = std::move(on_frame);
		stop_requested = false;
		alive = true;
		worker = std::thread(&V4l2Webcam::run, this);
		return true;
	}

	void close() override {
		stop_requested = true;
		if (worker.joinable()) {
			worker.join();
		}
		alive = false;
		shutdown();
	}

	bool is_alive() const override { return alive; }
	std::string device_name() const override { return name; }
	std::string last_error() const override {
		std::lock_guard<std::mutex> lock(problem_mutex);
		return problem;
	}

private:
	struct Mapping {
		void *memory = nullptr;
		size_t length = 0;
	};

	void set_problem(const std::string &text) {
		std::lock_guard<std::mutex> lock(problem_mutex);
		problem = text;
	}

	void shutdown() {
		if (fd >= 0 && streaming) {
			int type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
			xioctl(fd, VIDIOC_STREAMOFF, &type);
		}
		streaming = false;
		for (const Mapping &mapping : mappings) {
			munmap(mapping.memory, mapping.length);
		}
		mappings.clear();
		if (fd >= 0) {
			::close(fd);
			fd = -1;
		}
	}

	void run() {
		int quiet_polls = 0;
		while (!stop_requested) {
			pollfd waiting;
			waiting.fd = fd;
			waiting.events = POLLIN;
			waiting.revents = 0;
			const int ready = poll(&waiting, 1, 250);
			if (ready < 0 && errno == EINTR) {
				continue;
			}
			if (ready <= 0 || (waiting.revents & POLLIN) == 0) {
				if (ready < 0 || (waiting.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0 || ++quiet_polls > 12) {
					set_problem("the camera stopped delivering frames");
					break;
				}
				continue;
			}
			quiet_polls = 0;
			v4l2_buffer buffer;
			std::memset(&buffer, 0, sizeof(buffer));
			buffer.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
			buffer.memory = V4L2_MEMORY_MMAP;
			if (xioctl(fd, VIDIOC_DQBUF, &buffer) != 0) {
				if (errno == EAGAIN) {
					continue;
				}
				set_problem(std::string("the camera stopped: ") + std::strerror(errno));
				break;
			}
			if ((buffer.flags & V4L2_BUF_FLAG_ERROR) == 0 && buffer.index < mappings.size()) {
				deliver(static_cast<const uint8_t *>(mappings[buffer.index].memory), buffer.bytesused);
			}
			if (xioctl(fd, VIDIOC_QBUF, &buffer) != 0) {
				set_problem(std::string("the camera stopped: ") + std::strerror(errno));
				break;
			}
		}
		alive = false;
	}

	void deliver(const uint8_t *data, size_t used) {
		if (!callback) {
			return;
		}
		const int w = static_cast<int>(format.fmt.pix.width);
		const int h = static_cast<int>(format.fmt.pix.height);
		const uint32_t pixel_format = format.fmt.pix.pixelformat;
		if (pixel_format == V4L2_PIX_FMT_MJPEG || pixel_format == V4L2_PIX_FMT_JPEG) {
			webcam::jpeg_with_tables(data, used, jpeg);
			callback(jpeg.data(), jpeg.size(), w, h, Pixels::JPEG);
			return;
		}
		ptrdiff_t stride = static_cast<ptrdiff_t>(format.fmt.pix.bytesperline);
		rgb.resize(static_cast<size_t>(w) * h * 3);
		if (pixel_format == V4L2_PIX_FMT_YUYV) {
			stride = stride > 0 ? stride : w * 2;
			if (used < static_cast<size_t>(stride) * h) {
				return; // a short frame: the camera dropped part of it
			}
			webcam::yuy2_to_rgb(data, stride, w, h, rgb.data());
		} else if (pixel_format == V4L2_PIX_FMT_NV12) {
			stride = stride > 0 ? stride : w;
			if (used < static_cast<size_t>(stride) * h * 3 / 2) {
				return;
			}
			webcam::nv12_to_rgb(data, stride, w, h, rgb.data());
		} else {
			stride = stride > 0 ? stride : w * 3;
			if (used < static_cast<size_t>(stride) * h) {
				return;
			}
			webcam::rgb24_to_rgb(data, stride, w, h, pixel_format == V4L2_PIX_FMT_BGR24, rgb.data());
		}
		callback(rgb.data(), rgb.size(), w, h, Pixels::RGB8);
	}

	int fd = -1;
	bool streaming = false;
	v4l2_format format;
	std::vector<Mapping> mappings;
	FrameCallback callback;
	std::thread worker;
	std::atomic<bool> stop_requested{ false };
	std::atomic<bool> alive{ false };
	std::string name;
	mutable std::mutex problem_mutex;
	std::string problem;
	std::vector<uint8_t> rgb;
	std::vector<uint8_t> jpeg;
};

} // namespace

std::vector<std::string> WebcamBackend::list_devices() {
	std::vector<std::string> names;
	for (const CaptureNode &node : capture_nodes()) {
		names.push_back(node.name);
	}
	return names;
}

std::unique_ptr<WebcamBackend> WebcamBackend::create() {
	return std::unique_ptr<WebcamBackend>(new V4l2Webcam());
}

} // namespace wizardwars

#endif // __linux__
