// dear imgui: standalone example application for SDL2 + Vulkan
// If you are new to dear imgui, see examples/README.txt and documentation at the top of imgui.cpp.

// Important note to the reader who wish to integrate imgui_impl_vulkan.cpp/.h in their own engine/app.
// - Common ImGui_ImplVulkan_XXX functions and structures are used to interface with imgui_impl_vulkan.cpp/.h.
//   You will use those if you want to use this rendering back-end in your engine/app.
// - Helper ImGui_ImplVulkanH_XXX functions and structures are only used by this example (main.cpp) and by 
//   the back-end itself (imgui_impl_vulkan.cpp), but should PROBABLY NOT be used by your own engine/app code.
// Read comments in imgui_impl_vulkan.h.

#include "imgui.h"
#include "imgui_impl_sdl.h"
#include "imgui_impl_vulkan.h"
#include <stdio.h>          // printf, fprintf
#include <stdlib.h>         // abort
#include <SDL2/SDL.h>
#include <SDL2/SDL_vulkan.h>
#include <vulkan/vulkan.h>

static SDL_Window* g_SDLWindow = NULL;

extern "C" bool imguiImpl_Init(const char* title, int width, int height, struct Viewport_Context* context)
{
    assert(context != NULL);

    // Setup SDL
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_TIMER | SDL_INIT_GAMECONTROLLER) != 0)
    {
        printf("Error: %s\n", SDL_GetError());
        return false;
    }

    // Setup window
    SDL_WindowFlags window_flags = (SDL_WindowFlags)(SDL_WINDOW_VULKAN | SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI);
    g_SDLWindow = SDL_CreateWindow(title, SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, width, height, window_flags);

    // Setup Vulkan
    uint32_t extensions_count = 0;
    SDL_Vulkan_GetInstanceExtensions(g_SDLWindow, &extensions_count, NULL);
    const char** extensions = new const char*[extensions_count];
    SDL_Vulkan_GetInstanceExtensions(g_SDLWindow, &extensions_count, extensions);
    VkInstance instance = Viewport_SetupVulkan(context, extensions, extensions_count);
    delete[] extensions;

    if (instance == VK_NULL_HANDLE) {
        printf("Failed to create Vulkan instance.\n");
        return false;
    }

    // Create Window Surface
    VkSurfaceKHR surface;
    if (SDL_Vulkan_CreateSurface(g_SDLWindow, instance, &surface) == 0)
    {
        printf("Failed to create Vulkan surface.\n");
        return false;
    }

    // Create Framebuffers
    int w, h;
    SDL_GetWindowSize(g_SDLWindow, &w, &h);
    Viewport_SetupWindow(context, surface, w, h, VK_SAMPLE_COUNT_1_BIT, 2, true);

    // Setup Dear ImGui context
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO(); (void)io;
    //io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;     // Enable Keyboard Controls
    //io.ConfigFlags |= ImGuiConfigFlags_NavEnableGamepad;      // Enable Gamepad Controls

    // Setup Dear ImGui style
    ImGui::StyleColorsDark();
    //ImGui::StyleColorsClassic();

    // Setup Platform/Renderer bindings
    ImGui_ImplSDL2_InitForVulkan(g_SDLWindow);
    ImGui_ImplVulkan_Init(context);
   
    return true;
}

extern "C" void imguiImpl_GetWindowSize(struct Viewport_Context* context, uint32_t* width, uint32_t* height)
{
    SDL_GetWindowSize(g_SDLWindow, (int*)width, (int*)height);
}

extern "C" void imguiImpl_NewFrameSDL(struct Viewport_Context* context)
{
    ImGui_ImplSDL2_NewFrame(g_SDLWindow);
}


extern "C" void imguiImpl_Destroy(struct Viewport_Context* context)
{
    // Cleanup
    ImGui_ImplVulkan_Shutdown(context);
    ImGui_ImplSDL2_Shutdown();
    ImGui::DestroyContext();

    Viewport_CleanupWindow(context);
    Viewport_CleanupVulkan(context);

    SDL_DestroyWindow(g_SDLWindow); g_SDLWindow = NULL;
    SDL_Quit();
}

