// dear imgui: Renderer for Vulkan
// This needs to be used along with a Platform Binding (e.g. GLFW, SDL, Win32, custom..)

// Implemented features:
//  [X] Renderer: Support for large meshes (64k+ vertices) with 16-bits indices.
// Missing features:
//  [ ] Renderer: User texture binding. Changes of ImTextureID aren't supported by this binding! See https://github.com/ocornut/imgui/pull/914

// You can copy and use unmodified imgui_impl_* files in your project. See main.cpp for an example of using this.
// If you are new to dear imgui, read examples/README.txt and read the documentation at the top of imgui.cpp.
// https://github.com/ocornut/imgui

// The aim of imgui_impl_vulkan.h/.cpp is to be usable in your engine without any modification.
// IF YOU FEEL YOU NEED TO MAKE ANY CHANGE TO THIS CODE, please share them and your feedback at https://github.com/ocornut/imgui/

// Important note to the reader who wish to integrate imgui_impl_vulkan.cpp/.h in their own engine/app.
// - Common ImGui_ImplVulkan_XXX functions and structures are used to interface with imgui_impl_vulkan.cpp/.h.
//   You will use those if you want to use this rendering back-end in your engine/app.
// - Helper ImGui_ImplVulkanH_XXX functions and structures are only used by this example (main.cpp) and by 
//   the back-end itself (imgui_impl_vulkan.cpp), but should PROBABLY NOT be used by your own engine/app code.
// Read comments in imgui_impl_vulkan.h.

#pragma once

#include <vulkan/vulkan.h>


#if defined __cplusplus
    #define EXTERN_CAPI extern "C"
#else 
    #define EXTERN_CAPI
    #include <stdbool.h>
#endif

// Called by user code
EXTERN_CAPI bool     ImGui_ImplVulkan_Init(struct Viewport_Context*);
EXTERN_CAPI void     ImGui_ImplVulkan_Shutdown(struct Viewport_Context*);

EXTERN_CAPI VkInstance Viewport_SetupVulkan(struct Viewport_Context*, const char** extensions, uint32_t extensions_count);
EXTERN_CAPI void Viewport_CleanupVulkan(struct Viewport_Context*);
EXTERN_CAPI void Viewport_SetupWindow(struct Viewport_Context*, VkSurfaceKHR surface, int width, int height, VkSampleCountFlagBits ms, uint32_t min_image_count, bool clear_enable);
EXTERN_CAPI void Viewport_CleanupWindow(struct Viewport_Context*);

