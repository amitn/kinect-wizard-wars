#ifndef WIZARD_WARS_KINECT_V2_H
#define WIZARD_WARS_KINECT_V2_H

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/string.hpp>

struct IKinectSensor;
struct IBodyFrameReader;

namespace wizardwars {

/// Godot node that reads body frames straight from the Kinect v2 SDK.
///
/// Add it to the tree and call start(). Every frame it polls the sensor and
/// emits `frame_received(bodies)` with the same dictionaries the UDP bridge
/// sends, so the GDScript side does not care which source is active:
///   {"id": "123", "hands": {"l": "open", "r": "closed"},
///    "joints": {"Head": [x, y, z, tracking_state], ...}}
class KinectV2 : public godot::Node {
	GDCLASS(KinectV2, godot::Node)

public:
	KinectV2();
	~KinectV2() override;

	/// Opens the default sensor. Returns false when no sensor is present.
	bool start();
	void stop();
	bool is_running() const;
	/// True when the SDK reports the sensor as plugged in and ready.
	bool is_available() const;
	int get_tracked_body_count() const;
	godot::String get_last_error() const;

	void _process(double delta) override;

protected:
	static void _bind_methods();

private:
	bool poll_frame();

	IKinectSensor *sensor = nullptr;
	IBodyFrameReader *reader = nullptr;
	int tracked_body_count = 0;
	godot::String last_error;
};

} // namespace wizardwars

#endif // WIZARD_WARS_KINECT_V2_H
