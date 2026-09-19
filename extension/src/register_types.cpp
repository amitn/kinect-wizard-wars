#include "register_types.h"

#include "orbbec_camera.h"
#include "webcam_camera.h"
#ifdef HAVE_ONNXRUNTIME
#include "rtmpose.h"
#endif

#include <gdextension_interface.h>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

void initialize_orbbec_module(godot::ModuleInitializationLevel p_level) {
	if (p_level != godot::MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	GDREGISTER_CLASS(wizardwars::OrbbecCamera);
	GDREGISTER_CLASS(wizardwars::WebcamCamera);
#ifdef HAVE_ONNXRUNTIME
	GDREGISTER_CLASS(RtmPose);
#endif
}

void uninitialize_orbbec_module(godot::ModuleInitializationLevel p_level) {
	if (p_level != godot::MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
}

extern "C" {
GDExtensionBool GDE_EXPORT orbbec_library_init(GDExtensionInterfaceGetProcAddress p_get_proc_address,
		const GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization) {
	godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);
	init_obj.register_initializer(initialize_orbbec_module);
	init_obj.register_terminator(uninitialize_orbbec_module);
	init_obj.set_minimum_library_initialization_level(godot::MODULE_INITIALIZATION_LEVEL_SCENE);
	return init_obj.init();
}
}
