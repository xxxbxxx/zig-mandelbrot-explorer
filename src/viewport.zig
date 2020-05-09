const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const warn = std.debug.warn;
const fmt = std.fmt;
const assert = std.debug.assert;

usingnamespace @cImport({
    @cInclude("vulkan/vulkan.h");
});

const c = @cImport({
    @cDefine("CIMGUI_DEFINE_ENUMS_AND_STRUCTS", "1");
    @cInclude("cimgui.h");
    @cInclude("vulkan/vulkan.h");
});

const DVULKAN_DEBUG_REPORT = true;

const SwapchainFrame = struct {
    commandPool: VkCommandPool = null,
    commandBuffer: VkCommandBuffer = null,
    fence: VkFence = null,
    backbuffer: VkImage = null,
    backbufferView: VkImageView = null,
    framebuffer: VkFramebuffer = null,
};
const SwapchainSemaphores = struct {
    imageAcquiredSemaphore: VkSemaphore = null,
    renderCompleteSemaphore: VkSemaphore = null,
};
const FrameRenderData = struct {
    const RenderData = struct {
        vertexMemory: VkDeviceMemory = null,
        indexMemory: VkDeviceMemory = null,
        vertexSize: VkDeviceSize = 0,
        indexSize: VkDeviceSize = 0,
        vertex: VkBuffer = null,
        index: VkBuffer = null,
        descriptorSet: VkDescriptorSet = null,
    };

    data: [2]RenderData = [_]RenderData{ RenderData{}, RenderData{} },

    // mm devrait pas être là pour le multiwindow?
    activeTextureUploads: ArrayList(TextureUpload),
    activeTranscientTexture: ArrayList(*Texture),
};

const VulkanWindow = struct {
    width: u32 = 0,
    height: u32 = 0,
    swapchain: VkSwapchainKHR = null,
    surface: VkSurfaceKHR = null,
    surfaceFormat: VkSurfaceFormatKHR = undefined,
    presentMode: VkPresentModeKHR = undefined,
    renderPass: VkRenderPass = null,
    clearEnable: bool = false,
    clearValue: VkClearValue = undefined,

    frameIndex: u32 = 0,
    frames: []SwapchainFrame = &[0]SwapchainFrame{},
    semaphoreIndex: u32 = 0,
    frameSemaphores: []SwapchainSemaphores = &[0]SwapchainSemaphores{},
    renderDataIndex: u32 = 0,
    frameRenderData: []FrameRenderData = &[0]FrameRenderData{},
};

const Context = struct {
    instance: VkInstance = null,
    physicalDevice: VkPhysicalDevice = null,
    device: VkDevice = null,
    debugReport: VkDebugReportCallbackEXT = null,

    vk_allocator: ?*const VkAllocationCallbacks = null,
    allocator: *Allocator,

    descriptorPool: VkDescriptorPool = null,
    descriptorSetLayout: VkDescriptorSetLayout = null,

    pipelineLayout: VkPipelineLayout = null,
    pipeline: VkPipeline = null,
    pipelineCache: VkPipelineCache = null,

    queue: VkQueue = null,
    mainWindowData: VulkanWindow = VulkanWindow{},

    MSAASamples: VkSampleCountFlagBits = .VK_SAMPLE_COUNT_1_BIT,
    bufferMemoryAlignment: VkDeviceSize = 256,
    pipelineCreateFlags: VkPipelineCreateFlags = 0x00,
    minImageCount: u32 = 2,
    queueFamily: u32 = 0xFFFFFFFF,

    samplerTiling: VkSampler = null,
    fontTexture: Texture = Texture{},
    //texturePool: ArrayList(Texture),

    drawTextureUploads: ArrayList(TextureUpload),
    drawQuads: ArrayList(Quad),
};

pub const Vec2 = struct {
    x: f32,
    y: f32,
};
const Quad = struct {
    corners: [4]Vec2,
    texture: *Texture,
};

const Texture = struct {
    memory: VkDeviceMemory = null,
    image: VkImage = null,
    view: VkImageView = null,
    extent: VkExtent3D = undefined,
};
const TextureUpload = struct {
    memory: VkDeviceMemory = null,
    buffer: VkBuffer = null,
    texture: *const Texture = undefined,
};

fn check_vk_result(err: VkResult) !void {
    if (err == .VK_SUCCESS) return;
    warn("VkResult: {}\n", .{err});
    if (@enumToInt(err) < 0)
        return error.VulkanError;
}

// ---------------------------------------

//-----------------------------------------------------------------------------
// SHADERS
//-----------------------------------------------------------------------------

// glsl_shader.vert, compiled with:
// # glslangValidator -V -x -o glsl_shader.vert.u32 glsl_shader.vert
//
//              #version 450 core
//              layout(location = 0) in vec2 aPos;
//              layout(location = 1) in vec2 aUV;
//              layout(location = 2) in vec4 aColor;
//              layout(push_constant) uniform uPushConstant { vec2 uScale; vec2 uTranslate; } pc;
//
//              out gl_PerVertex { vec4 gl_Position; };
//              layout(location = 0) out struct { vec4 Color; vec2 UV; } Out;
//
//              void main()
//              {
//                  Out.Color = aColor;
//                  Out.UV = aUV;
//                  gl_Position = vec4(aPos * pc.uScale + pc.uTranslate, 0, 1);
//              }

const __glsl_shader_vert_spv = [_]u32{
    0x07230203, 0x00010000, 0x00080001, 0x0000002e, 0x00000000, 0x00020011, 0x00000001, 0x0006000b,
    0x00000001, 0x4c534c47, 0x6474732e, 0x3035342e, 0x00000000, 0x0003000e, 0x00000000, 0x00000001,
    0x000a000f, 0x00000000, 0x00000004, 0x6e69616d, 0x00000000, 0x0000000b, 0x0000000f, 0x00000015,
    0x0000001b, 0x0000001c, 0x00030003, 0x00000002, 0x000001c2, 0x00040005, 0x00000004, 0x6e69616d,
    0x00000000, 0x00030005, 0x00000009, 0x00000000, 0x00050006, 0x00000009, 0x00000000, 0x6f6c6f43,
    0x00000072, 0x00040006, 0x00000009, 0x00000001, 0x00005655, 0x00030005, 0x0000000b, 0x0074754f,
    0x00040005, 0x0000000f, 0x6c6f4361, 0x0000726f, 0x00030005, 0x00000015, 0x00565561, 0x00060005,
    0x00000019, 0x505f6c67, 0x65567265, 0x78657472, 0x00000000, 0x00060006, 0x00000019, 0x00000000,
    0x505f6c67, 0x7469736f, 0x006e6f69, 0x00030005, 0x0000001b, 0x00000000, 0x00040005, 0x0000001c,
    0x736f5061, 0x00000000, 0x00060005, 0x0000001e, 0x73755075, 0x6e6f4368, 0x6e617473, 0x00000074,
    0x00050006, 0x0000001e, 0x00000000, 0x61635375, 0x0000656c, 0x00060006, 0x0000001e, 0x00000001,
    0x61725475, 0x616c736e, 0x00006574, 0x00030005, 0x00000020, 0x00006370, 0x00040047, 0x0000000b,
    0x0000001e, 0x00000000, 0x00040047, 0x0000000f, 0x0000001e, 0x00000002, 0x00040047, 0x00000015,
    0x0000001e, 0x00000001, 0x00050048, 0x00000019, 0x00000000, 0x0000000b, 0x00000000, 0x00030047,
    0x00000019, 0x00000002, 0x00040047, 0x0000001c, 0x0000001e, 0x00000000, 0x00050048, 0x0000001e,
    0x00000000, 0x00000023, 0x00000000, 0x00050048, 0x0000001e, 0x00000001, 0x00000023, 0x00000008,
    0x00030047, 0x0000001e, 0x00000002, 0x00020013, 0x00000002, 0x00030021, 0x00000003, 0x00000002,
    0x00030016, 0x00000006, 0x00000020, 0x00040017, 0x00000007, 0x00000006, 0x00000004, 0x00040017,
    0x00000008, 0x00000006, 0x00000002, 0x0004001e, 0x00000009, 0x00000007, 0x00000008, 0x00040020,
    0x0000000a, 0x00000003, 0x00000009, 0x0004003b, 0x0000000a, 0x0000000b, 0x00000003, 0x00040015,
    0x0000000c, 0x00000020, 0x00000001, 0x0004002b, 0x0000000c, 0x0000000d, 0x00000000, 0x00040020,
    0x0000000e, 0x00000001, 0x00000007, 0x0004003b, 0x0000000e, 0x0000000f, 0x00000001, 0x00040020,
    0x00000011, 0x00000003, 0x00000007, 0x0004002b, 0x0000000c, 0x00000013, 0x00000001, 0x00040020,
    0x00000014, 0x00000001, 0x00000008, 0x0004003b, 0x00000014, 0x00000015, 0x00000001, 0x00040020,
    0x00000017, 0x00000003, 0x00000008, 0x0003001e, 0x00000019, 0x00000007, 0x00040020, 0x0000001a,
    0x00000003, 0x00000019, 0x0004003b, 0x0000001a, 0x0000001b, 0x00000003, 0x0004003b, 0x00000014,
    0x0000001c, 0x00000001, 0x0004001e, 0x0000001e, 0x00000008, 0x00000008, 0x00040020, 0x0000001f,
    0x00000009, 0x0000001e, 0x0004003b, 0x0000001f, 0x00000020, 0x00000009, 0x00040020, 0x00000021,
    0x00000009, 0x00000008, 0x0004002b, 0x00000006, 0x00000028, 0x00000000, 0x0004002b, 0x00000006,
    0x00000029, 0x3f800000, 0x00050036, 0x00000002, 0x00000004, 0x00000000, 0x00000003, 0x000200f8,
    0x00000005, 0x0004003d, 0x00000007, 0x00000010, 0x0000000f, 0x00050041, 0x00000011, 0x00000012,
    0x0000000b, 0x0000000d, 0x0003003e, 0x00000012, 0x00000010, 0x0004003d, 0x00000008, 0x00000016,
    0x00000015, 0x00050041, 0x00000017, 0x00000018, 0x0000000b, 0x00000013, 0x0003003e, 0x00000018,
    0x00000016, 0x0004003d, 0x00000008, 0x0000001d, 0x0000001c, 0x00050041, 0x00000021, 0x00000022,
    0x00000020, 0x0000000d, 0x0004003d, 0x00000008, 0x00000023, 0x00000022, 0x00050085, 0x00000008,
    0x00000024, 0x0000001d, 0x00000023, 0x00050041, 0x00000021, 0x00000025, 0x00000020, 0x00000013,
    0x0004003d, 0x00000008, 0x00000026, 0x00000025, 0x00050081, 0x00000008, 0x00000027, 0x00000024,
    0x00000026, 0x00050051, 0x00000006, 0x0000002a, 0x00000027, 0x00000000, 0x00050051, 0x00000006,
    0x0000002b, 0x00000027, 0x00000001, 0x00070050, 0x00000007, 0x0000002c, 0x0000002a, 0x0000002b,
    0x00000028, 0x00000029, 0x00050041, 0x00000011, 0x0000002d, 0x0000001b, 0x0000000d, 0x0003003e,
    0x0000002d, 0x0000002c, 0x000100fd, 0x00010038,
};

// glsl_shader.frag, compiled with:
// # glslangValidator -V -x -o glsl_shader.frag.u32 glsl_shader.frag
//
//              #version 450 core
//              layout(location = 0) out vec4 fColor;
//              layout(set=0, binding=0) uniform sampler2D sTexture;
//              layout(location = 0) in struct { vec4 Color; vec2 UV; } In;
//              void main()
//              {
//                  fColor = In.Color * texture(sTexture, In.UV.st);
//              }

const __glsl_shader_frag_spv = [_]u32{
    0x07230203, 0x00010000, 0x00080001, 0x0000001e, 0x00000000, 0x00020011, 0x00000001, 0x0006000b,
    0x00000001, 0x4c534c47, 0x6474732e, 0x3035342e, 0x00000000, 0x0003000e, 0x00000000, 0x00000001,
    0x0007000f, 0x00000004, 0x00000004, 0x6e69616d, 0x00000000, 0x00000009, 0x0000000d, 0x00030010,
    0x00000004, 0x00000007, 0x00030003, 0x00000002, 0x000001c2, 0x00040005, 0x00000004, 0x6e69616d,
    0x00000000, 0x00040005, 0x00000009, 0x6c6f4366, 0x0000726f, 0x00030005, 0x0000000b, 0x00000000,
    0x00050006, 0x0000000b, 0x00000000, 0x6f6c6f43, 0x00000072, 0x00040006, 0x0000000b, 0x00000001,
    0x00005655, 0x00030005, 0x0000000d, 0x00006e49, 0x00050005, 0x00000016, 0x78655473, 0x65727574,
    0x00000000, 0x00040047, 0x00000009, 0x0000001e, 0x00000000, 0x00040047, 0x0000000d, 0x0000001e,
    0x00000000, 0x00040047, 0x00000016, 0x00000022, 0x00000000, 0x00040047, 0x00000016, 0x00000021,
    0x00000000, 0x00020013, 0x00000002, 0x00030021, 0x00000003, 0x00000002, 0x00030016, 0x00000006,
    0x00000020, 0x00040017, 0x00000007, 0x00000006, 0x00000004, 0x00040020, 0x00000008, 0x00000003,
    0x00000007, 0x0004003b, 0x00000008, 0x00000009, 0x00000003, 0x00040017, 0x0000000a, 0x00000006,
    0x00000002, 0x0004001e, 0x0000000b, 0x00000007, 0x0000000a, 0x00040020, 0x0000000c, 0x00000001,
    0x0000000b, 0x0004003b, 0x0000000c, 0x0000000d, 0x00000001, 0x00040015, 0x0000000e, 0x00000020,
    0x00000001, 0x0004002b, 0x0000000e, 0x0000000f, 0x00000000, 0x00040020, 0x00000010, 0x00000001,
    0x00000007, 0x00090019, 0x00000013, 0x00000006, 0x00000001, 0x00000000, 0x00000000, 0x00000000,
    0x00000001, 0x00000000, 0x0003001b, 0x00000014, 0x00000013, 0x00040020, 0x00000015, 0x00000000,
    0x00000014, 0x0004003b, 0x00000015, 0x00000016, 0x00000000, 0x0004002b, 0x0000000e, 0x00000018,
    0x00000001, 0x00040020, 0x00000019, 0x00000001, 0x0000000a, 0x00050036, 0x00000002, 0x00000004,
    0x00000000, 0x00000003, 0x000200f8, 0x00000005, 0x00050041, 0x00000010, 0x00000011, 0x0000000d,
    0x0000000f, 0x0004003d, 0x00000007, 0x00000012, 0x00000011, 0x0004003d, 0x00000014, 0x00000017,
    0x00000016, 0x00050041, 0x00000019, 0x0000001a, 0x0000000d, 0x00000018, 0x0004003d, 0x0000000a,
    0x0000001b, 0x0000001a, 0x00050057, 0x00000007, 0x0000001c, 0x00000017, 0x0000001b, 0x00050085,
    0x00000007, 0x0000001d, 0x00000012, 0x0000001c, 0x0003003e, 0x00000009, 0x0000001d, 0x000100fd,
    0x00010038,
};

//-----------------------------------------------------------------------------
// FUNCTIONS
//-----------------------------------------------------------------------------

fn getMemoryType(ctx: *Context, properties: VkMemoryPropertyFlags, type_bits: u32) u32 {
    var prop: VkPhysicalDeviceMemoryProperties = undefined;
    vkGetPhysicalDeviceMemoryProperties(ctx.physicalDevice, &prop);
    var i: u32 = 0;
    while (i < prop.memoryTypeCount) : (i += 1) {
        const mask: u32 = @as(u32, 1) << @intCast(u5, i);
        if ((prop.memoryTypes[i].propertyFlags & properties) == properties and (type_bits & mask) != 0)
            return i;
    }
    return 0xFFFFFFFF; // Unable to find memoryType
}

fn createOrResizeBuffer(ctx: *Context, buffer: *VkBuffer, buffer_memory: *VkDeviceMemory, p_buffer_size: *VkDeviceSize, new_size: usize, usage: VkBufferUsageFlagBits) !void {
    var err: VkResult = undefined;

    if (buffer.* != null)
        vkDestroyBuffer(ctx.device, buffer.*, ctx.vk_allocator);
    if (buffer_memory.* != null)
        vkFreeMemory(ctx.device, buffer_memory.*, ctx.vk_allocator);

    const vertex_buffer_size_aligned: VkDeviceSize = ((new_size - 1) / ctx.bufferMemoryAlignment + 1) * ctx.bufferMemoryAlignment;
    const buffer_info = VkBufferCreateInfo{
        .sType = .VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .size = vertex_buffer_size_aligned,
        .usage = @intCast(u32, @enumToInt(usage)),
        .sharingMode = .VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
    };
    err = vkCreateBuffer(ctx.device, &buffer_info, ctx.vk_allocator, buffer);
    try check_vk_result(err);

    var req: VkMemoryRequirements = undefined;
    vkGetBufferMemoryRequirements(ctx.device, buffer.*, &req);
    ctx.bufferMemoryAlignment = if (ctx.bufferMemoryAlignment > req.alignment) ctx.bufferMemoryAlignment else req.alignment;
    const alloc_info = VkMemoryAllocateInfo{
        .sType = .VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = null,
        .allocationSize = req.size,
        .memoryTypeIndex = getMemoryType(ctx, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT, req.memoryTypeBits),
    };
    err = vkAllocateMemory(ctx.device, &alloc_info, ctx.vk_allocator, buffer_memory);
    try check_vk_result(err);

    err = vkBindBufferMemory(ctx.device, buffer.*, buffer_memory.*, 0);
    try check_vk_result(err);
    p_buffer_size.* = new_size;
}

const DisplayTransfo = struct {
    scale: [2]f32,
    translate: [2]f32,
    fb_width: u32,
    fb_height: u32,
};
fn setupRenderState(ctx: *Context, command_buffer: VkCommandBuffer, data: *const FrameRenderData.RenderData, imageView: VkImageView, displayTransfo: DisplayTransfo) void {

    // Update the Descriptor Set:
    {
        const desc_image = [_]VkDescriptorImageInfo{
            VkDescriptorImageInfo{
                .sampler = ctx.samplerTiling,
                .imageView = imageView,
                .imageLayout = .VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            },
        };
        const write_desc = [_]VkWriteDescriptorSet{
            VkWriteDescriptorSet{
                .sType = .VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .pNext = null,
                .dstSet = data.descriptorSet,
                .dstBinding = 0,
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = .VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .pImageInfo = &desc_image,
                .pBufferInfo = null,
                .pTexelBufferView = null,
            },
        };
        vkUpdateDescriptorSets(ctx.device, write_desc.len, &write_desc, 0, null);
    }

    // Bind pipeline and descriptor sets:
    {
        vkCmdBindPipeline(command_buffer, .VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.pipeline);
        const desc_set = [_]VkDescriptorSet{data.descriptorSet};
        vkCmdBindDescriptorSets(command_buffer, .VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.pipelineLayout, 0, desc_set.len, &desc_set, 0, null);
    }

    // Setup viewport:
    {
        const viewport = VkViewport{
            .x = 0,
            .y = 0,
            .width = @intToFloat(f32, displayTransfo.fb_width),
            .height = @intToFloat(f32, displayTransfo.fb_height),
            .minDepth = 0.0,
            .maxDepth = 1.0,
        };
        vkCmdSetViewport(command_buffer, 0, 1, &viewport);
    }

    // Bind Vertex And index Buffer:
    {
        const vertex_buffers = [_]VkBuffer{data.vertex};
        const vertex_offset = [_]VkDeviceSize{0};
        vkCmdBindVertexBuffers(command_buffer, 0, 1, &vertex_buffers, &vertex_offset);

        assert(@sizeOf(c.ImDrawIdx) == 2);
        vkCmdBindIndexBuffer(command_buffer, data.index, 0, .VK_INDEX_TYPE_UINT16);
    }

    // Setup scale and translation:
    {
        vkCmdPushConstants(command_buffer, ctx.pipelineLayout, VK_SHADER_STAGE_VERTEX_BIT, @sizeOf(f32) * 0, @sizeOf(f32) * 2, &displayTransfo.scale);
        vkCmdPushConstants(command_buffer, ctx.pipelineLayout, VK_SHADER_STAGE_VERTEX_BIT, @sizeOf(f32) * 2, @sizeOf(f32) * 2, &displayTransfo.translate);
    }
}

fn renderDrawData(ctx: *Context, frd: *FrameRenderData, displayTransfo: DisplayTransfo, draw_data: *c.ImDrawData, command_buffer: VkCommandBuffer) !void {
    var err: VkResult = undefined;

    // Create or resize the vertex/index buffers
    const vertex_size = @intCast(usize, draw_data.TotalVtxCount) * @sizeOf(c.ImDrawVert);
    const index_size = @intCast(usize, draw_data.TotalIdxCount) * @sizeOf(c.ImDrawIdx);
    if (frd.data[0].vertex == null or frd.data[0].vertexSize < vertex_size)
        try createOrResizeBuffer(ctx, &frd.data[0].vertex, &frd.data[0].vertexMemory, &frd.data[0].vertexSize, vertex_size, .VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
    if (frd.data[0].index == null or frd.data[0].indexSize < index_size)
        try createOrResizeBuffer(ctx, &frd.data[0].index, &frd.data[0].indexMemory, &frd.data[0].indexSize, index_size, .VK_BUFFER_USAGE_INDEX_BUFFER_BIT);

    // Upload vertex/index data into a single contiguous GPU buffer
    {
        var vtx_dst: [*]c.ImDrawVert = undefined;
        var idx_dst: [*]c.ImDrawIdx = undefined;

        err = vkMapMemory(ctx.device, frd.data[0].vertexMemory, 0, vertex_size, 0, @ptrCast([*c](?*c_void), &vtx_dst));
        try check_vk_result(err);
        err = vkMapMemory(ctx.device, frd.data[0].indexMemory, 0, index_size, 0, @ptrCast([*c](?*c_void), &idx_dst));
        try check_vk_result(err);

        var n: u32 = 0;
        while (n < @intCast(u32, draw_data.CmdListsCount)) : (n += 1) {
            const cmd_list = draw_data.CmdLists[n].*;
            const cVtx = @intCast(usize, cmd_list.VtxBuffer.Size);
            const cItx = @intCast(usize, cmd_list.IdxBuffer.Size);
            std.mem.copy(c.ImDrawVert, vtx_dst[0..cVtx], cmd_list.VtxBuffer.Data[0..cVtx]);
            std.mem.copy(c.ImDrawIdx, idx_dst[0..cItx], cmd_list.IdxBuffer.Data[0..cItx]);
            vtx_dst += @intCast(usize, cVtx);
            idx_dst += @intCast(usize, cItx);
        }
        const ranges = [_]VkMappedMemoryRange{
            VkMappedMemoryRange{
                .sType = .VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,
                .pNext = null,
                .memory = frd.data[0].vertexMemory,
                .size = VK_WHOLE_SIZE,
                .offset = 0,
            },
            VkMappedMemoryRange{
                .sType = .VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,
                .pNext = null,
                .memory = frd.data[0].indexMemory,
                .size = VK_WHOLE_SIZE,
                .offset = 0,
            },
        };
        err = vkFlushMappedMemoryRanges(ctx.device, ranges.len, &ranges);
        try check_vk_result(err);

        vkUnmapMemory(ctx.device, frd.data[0].vertexMemory);
        vkUnmapMemory(ctx.device, frd.data[0].indexMemory);
    }

    // Create Descriptor Set:
    if (frd.data[0].descriptorSet == null) {
        const alloc_info = VkDescriptorSetAllocateInfo{
            .sType = .VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .pNext = null,
            .descriptorPool = ctx.descriptorPool,
            .descriptorSetCount = 1,
            .pSetLayouts = &ctx.descriptorSetLayout,
        };
        err = vkAllocateDescriptorSets(ctx.device, &alloc_info, &frd.data[0].descriptorSet);
        try check_vk_result(err);
    }

    // Setup desired Vulkan state
    setupRenderState(ctx, command_buffer, &frd.data[0], ctx.fontTexture.view, displayTransfo);

    // Will project scissor/clipping rectangles into framebuffer space
    const clip_off = draw_data.DisplayPos; // (0,0) unless using multi-viewports
    const clip_scale = draw_data.FramebufferScale; // (1,1) unless using retina display which are often (2,2)

    // Render command lists
    // (Because we merged all buffers into a single one, we maintain our own offset into them)
    var global_vtx_offset: u32 = 0;
    var global_idx_offset: u32 = 0;
    var n: u32 = 0;
    while (n < @intCast(u32, draw_data.CmdListsCount)) : (n += 1) {
        const cmd_list = draw_data.CmdLists[n].*;
        var cmd_i: u32 = 0;
        while (cmd_i < @intCast(u32, cmd_list.CmdBuffer.Size)) : (cmd_i += 1) {
            const pcmd = &cmd_list.CmdBuffer.Data[cmd_i];
            assert(pcmd.UserCallback == null);

            // Project scissor/clipping rectangles into framebuffer space
            var clip_rect = c.ImVec4{
                .x = (pcmd.ClipRect.x - clip_off.x) * clip_scale.x,
                .y = (pcmd.ClipRect.y - clip_off.y) * clip_scale.y,
                .z = (pcmd.ClipRect.z - clip_off.x) * clip_scale.x,
                .w = (pcmd.ClipRect.w - clip_off.y) * clip_scale.y,
                .dummy = undefined,
            };

            if (clip_rect.x < @intToFloat(f32, displayTransfo.fb_width) and clip_rect.y < @intToFloat(f32, displayTransfo.fb_height) and clip_rect.z >= 0.0 and clip_rect.w >= 0.0) {
                // Negative offsets are illegal for vkCmdSetScissor
                if (clip_rect.x < 0.0)
                    clip_rect.x = 0.0;
                if (clip_rect.y < 0.0)
                    clip_rect.y = 0.0;

                // Apply scissor/clipping rectangle
                const scissor = VkRect2D{
                    .offset = VkOffset2D{
                        .x = @floatToInt(i32, clip_rect.x),
                        .y = @floatToInt(i32, clip_rect.y),
                    },
                    .extent = VkExtent2D{
                        .width = @floatToInt(u32, clip_rect.z - clip_rect.x),
                        .height = @floatToInt(u32, clip_rect.w - clip_rect.y),
                    },
                };
                vkCmdSetScissor(command_buffer, 0, 1, &scissor);

                // Draw
                vkCmdDrawIndexed(command_buffer, pcmd.ElemCount, 1, pcmd.IdxOffset + global_idx_offset, @intCast(i32, pcmd.VtxOffset + global_vtx_offset), 0);
            }
        }
        global_idx_offset += @intCast(u32, cmd_list.IdxBuffer.Size);
        global_vtx_offset += @intCast(u32, cmd_list.VtxBuffer.Size);
    }
}

fn vec2vec(v: Vec2) c.ImVec2 {
    return c.ImVec2{
        .x = v.x,
        .y = v.y,
        .dummy = undefined,
    };
}
fn renderQuad(ctx: *Context, frd: *FrameRenderData, displayTransfo: DisplayTransfo, quad: Quad, command_buffer: VkCommandBuffer) !void {
    var err: VkResult = undefined;

    const vtxData = [_]c.ImDrawVert{
        c.ImDrawVert{ .pos = vec2vec(quad.corners[0]), .uv = c.ImVec2{ .x = 0, .y = 0, .dummy = undefined }, .col = 0xFFFFFFFF },
        c.ImDrawVert{ .pos = vec2vec(quad.corners[1]), .uv = c.ImVec2{ .x = 1, .y = 0, .dummy = undefined }, .col = 0xFFFFFFFF },
        c.ImDrawVert{ .pos = vec2vec(quad.corners[2]), .uv = c.ImVec2{ .x = 1, .y = 1, .dummy = undefined }, .col = 0xFFFFFFFF },
        c.ImDrawVert{ .pos = vec2vec(quad.corners[3]), .uv = c.ImVec2{ .x = 0, .y = 1, .dummy = undefined }, .col = 0xFFFFFFFF },
    };
    const idxData = [_]c.ImDrawIdx{ 0, 1, 3, 1, 2, 3 };

    // Create or resize the vertex/index buffers
    const data = &frd.data[1];
    const vertex_size = vtxData.len * @sizeOf(c.ImDrawVert);
    const index_size = idxData.len * @sizeOf(c.ImDrawIdx);
    if (data.vertex == null or data.vertexSize < vertex_size)
        try createOrResizeBuffer(ctx, &data.vertex, &data.vertexMemory, &data.vertexSize, vertex_size, .VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
    if (data.index == null or data.indexSize < index_size)
        try createOrResizeBuffer(ctx, &data.index, &data.indexMemory, &data.indexSize, index_size, .VK_BUFFER_USAGE_INDEX_BUFFER_BIT);

    // Upload vertex/index data into a single contiguous GPU buffer
    {
        var vtx_dst: [*]c.ImDrawVert = undefined;
        var idx_dst: [*]c.ImDrawIdx = undefined;

        err = vkMapMemory(ctx.device, data.vertexMemory, 0, vertex_size, 0, @ptrCast([*c]?*c_void, &vtx_dst));
        try check_vk_result(err);
        err = vkMapMemory(ctx.device, data.indexMemory, 0, index_size, 0, @ptrCast([*c]?*c_void, &idx_dst));
        try check_vk_result(err);

        std.mem.copy(c.ImDrawVert, vtx_dst[0..vtxData.len], &vtxData);
        std.mem.copy(c.ImDrawIdx, idx_dst[0..idxData.len], &idxData);

        const ranges = [_]VkMappedMemoryRange{
            VkMappedMemoryRange{
                .sType = .VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,
                .pNext = null,
                .memory = data.vertexMemory,
                .size = VK_WHOLE_SIZE,
                .offset = 0,
            },
            VkMappedMemoryRange{
                .sType = .VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,
                .pNext = null,
                .memory = data.indexMemory,
                .size = VK_WHOLE_SIZE,
                .offset = 0,
            },
        };
        err = vkFlushMappedMemoryRanges(ctx.device, ranges.len, &ranges);
        try check_vk_result(err);

        vkUnmapMemory(ctx.device, data.vertexMemory);
        vkUnmapMemory(ctx.device, data.indexMemory);
    }

    // Create Descriptor Set:
    if (data.descriptorSet == null) {
        const alloc_info = VkDescriptorSetAllocateInfo{
            .sType = .VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .pNext = null,
            .descriptorPool = ctx.descriptorPool,
            .descriptorSetCount = 1,
            .pSetLayouts = &ctx.descriptorSetLayout,
        };
        err = vkAllocateDescriptorSets(ctx.device, &alloc_info, &data.descriptorSet);
        try check_vk_result(err);
    }

    // Setup desired Vulkan state
    setupRenderState(ctx, command_buffer, data, quad.texture.view, displayTransfo);

    {
        const scissor = VkRect2D{
            .offset = VkOffset2D{
                .x = 0,
                .y = 0,
            },
            .extent = VkExtent2D{
                .width = @intCast(u32, displayTransfo.fb_width),
                .height = @intCast(u32, displayTransfo.fb_height),
            },
        };
        vkCmdSetScissor(command_buffer, 0, 1, &scissor);

        // Draw
        const idxCount = idxData.len;
        const idxOffset: i32 = 0;
        const vtxOffset: i32 = 0;
        vkCmdDrawIndexed(command_buffer, idxData.len, 1, idxOffset, vtxOffset, 0);
    }
}

fn initTexture(ctx: *Context, texture: *Texture, width: u32, height: u32) !void {
    var err: VkResult = undefined;

    texture.extent = VkExtent3D{ .width = width, .height = height, .depth = 1 };

    // Create the image:
    {
        const info = VkImageCreateInfo{
            .sType = .VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .imageType = .VK_IMAGE_TYPE_2D,
            .format = .VK_FORMAT_R8G8B8A8_UNORM,
            .extent = texture.extent,
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = .VK_SAMPLE_COUNT_1_BIT,
            .tiling = .VK_IMAGE_TILING_OPTIMAL,
            .usage = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT,
            .sharingMode = .VK_SHARING_MODE_EXCLUSIVE,
            .initialLayout = .VK_IMAGE_LAYOUT_UNDEFINED,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
        };
        err = vkCreateImage(ctx.device, &info, ctx.vk_allocator, &texture.image);
        try check_vk_result(err);

        var req: VkMemoryRequirements = undefined;
        vkGetImageMemoryRequirements(ctx.device, texture.image, &req);
        const alloc_info = VkMemoryAllocateInfo{
            .sType = .VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = req.size,
            .memoryTypeIndex = getMemoryType(ctx, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, req.memoryTypeBits),
        };
        err = vkAllocateMemory(ctx.device, &alloc_info, ctx.vk_allocator, &texture.memory);
        try check_vk_result(err);

        err = vkBindImageMemory(ctx.device, texture.image, texture.memory, 0);
        try check_vk_result(err);
    }

    // Create the image view:
    {
        const info = VkImageViewCreateInfo{
            .sType = .VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .image = texture.image,
            .viewType = .VK_IMAGE_VIEW_TYPE_2D,
            .format = .VK_FORMAT_R8G8B8A8_UNORM,
            .components = VkComponentMapping{ .r = .VK_COMPONENT_SWIZZLE_R, .g = .VK_COMPONENT_SWIZZLE_G, .b = .VK_COMPONENT_SWIZZLE_B, .a = .VK_COMPONENT_SWIZZLE_A },
            .subresourceRange = VkImageSubresourceRange{
                .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
                .levelCount = 1,
                .layerCount = 1,
                .baseMipLevel = 0,
                .baseArrayLayer = 0,
            },
        };
        err = vkCreateImageView(ctx.device, &info, ctx.vk_allocator, &texture.view);
        try check_vk_result(err);
    }
}

fn destroyTexture(device: VkDevice, texture: *Texture, vk_allocator: ?*const VkAllocationCallbacks) void {
    if (texture.view != null) {
        vkDestroyImageView(device, texture.view, vk_allocator);
        texture.view = null;
    }
    if (texture.image != null) {
        vkDestroyImage(device, texture.image, vk_allocator);
        texture.image = null;
    }
    if (texture.memory != null) {
        vkFreeMemory(device, texture.memory, vk_allocator);
        texture.memory = null;
    }
}

fn initTextureUpload(ctx: *Context, textureUpload: *TextureUpload, pixels: []const u8, texture: *const Texture) !void {
    var err: VkResult = undefined;

    // Create the Upload Buffer:
    const offsetInMemory = 0;
    {
        const buffer_info = VkBufferCreateInfo{
            .sType = .VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .size = pixels.len,
            .usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            .sharingMode = .VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
        };
        err = vkCreateBuffer(ctx.device, &buffer_info, ctx.vk_allocator, &textureUpload.buffer);
        try check_vk_result(err);

        var req: VkMemoryRequirements = undefined;
        vkGetBufferMemoryRequirements(ctx.device, textureUpload.buffer, &req);
        ctx.bufferMemoryAlignment = if (ctx.bufferMemoryAlignment > req.alignment) ctx.bufferMemoryAlignment else req.alignment;
        const alloc_info = VkMemoryAllocateInfo{
            .sType = .VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = req.size,
            .memoryTypeIndex = getMemoryType(ctx, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT, req.memoryTypeBits),
        };
        err = vkAllocateMemory(ctx.device, &alloc_info, ctx.vk_allocator, &textureUpload.memory);
        try check_vk_result(err);

        err = vkBindBufferMemory(ctx.device, textureUpload.buffer, textureUpload.memory, offsetInMemory);
        try check_vk_result(err);
    }

    // Upload to Buffer:
    {
        var map: [*]u8 = undefined;
        err = vkMapMemory(ctx.device, textureUpload.memory, offsetInMemory, pixels.len, 0, @ptrCast([*c]?*c_void, &map));
        try check_vk_result(err);

        @memcpy(map, pixels.ptr, pixels.len);
        //std.mem.copy(u8, map[0..pixels.len], pixels); 2x slower in release-fast...  (performance restored if using noalias + no change with aligned ptrs)

        const ranges = [_]VkMappedMemoryRange{
            VkMappedMemoryRange{
                .sType = .VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,
                .pNext = null,
                .memory = textureUpload.memory,
                .size = pixels.len,
                .offset = offsetInMemory,
            },
        };
        err = vkFlushMappedMemoryRanges(ctx.device, ranges.len, &ranges);
        try check_vk_result(err);

        vkUnmapMemory(ctx.device, textureUpload.memory);
    }

    textureUpload.texture = texture;
}

fn flushTextureUpload(ctx: *Context, command_buffer: VkCommandBuffer, textureUpload: *const TextureUpload) void {
    // Copy to image:
    {
        const copy_barrier = [_]VkImageMemoryBarrier{
            VkImageMemoryBarrier{
                .sType = .VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                .pNext = null,
                .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
                .srcAccessMask = 0,
                .oldLayout = .VK_IMAGE_LAYOUT_UNDEFINED,
                .newLayout = .VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                .image = textureUpload.texture.image,
                .subresourceRange = VkImageSubresourceRange{ .layerCount = 1, .baseArrayLayer = 0, .levelCount = 1, .baseMipLevel = 0, .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT },
            },
        };
        vkCmdPipelineBarrier(command_buffer, VK_PIPELINE_STAGE_HOST_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, copy_barrier.len, &copy_barrier);

        const region = VkBufferImageCopy{
            .imageSubresource = VkImageSubresourceLayers{ .mipLevel = 0, .layerCount = 1, .baseArrayLayer = 0, .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT },
            .imageExtent = textureUpload.texture.extent,
            .imageOffset = VkOffset3D{ .x = 0, .y = 0, .z = 0 },
            .bufferOffset = 0,
            .bufferRowLength = 0,
            .bufferImageHeight = 0,
        };
        vkCmdCopyBufferToImage(command_buffer, textureUpload.buffer, textureUpload.texture.image, .VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

        const use_barrier = [_]VkImageMemoryBarrier{VkImageMemoryBarrier{
            .sType = .VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
            .dstAccessMask = VK_ACCESS_SHADER_READ_BIT,
            .oldLayout = .VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .newLayout = .VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .image = textureUpload.texture.image,
            .subresourceRange = VkImageSubresourceRange{
                .levelCount = 1,
                .baseMipLevel = 0,
                .layerCount = 1,
                .baseArrayLayer = 0,
                .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            },
        }};
        vkCmdPipelineBarrier(command_buffer, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, use_barrier.len, &use_barrier);
    }
}

fn destroyTextureUpload(device: VkDevice, textureUpload: *TextureUpload, vk_allocator: ?*const VkAllocationCallbacks) void {
    if (textureUpload.buffer != null) {
        vkDestroyBuffer(device, textureUpload.buffer, vk_allocator);
        textureUpload.buffer = null;
    }
    if (textureUpload.memory != null) {
        vkFreeMemory(device, textureUpload.memory, vk_allocator);
        textureUpload.memory = null;
    }
}

//-------------------------------------------------------------------------

fn createDeviceObjects(ctx: *Context) !void {
    var err: VkResult = undefined;
    var vert_module: VkShaderModule = undefined;
    var frag_module: VkShaderModule = undefined;

    // Create The Shader Modules:
    {
        const vert_info = VkShaderModuleCreateInfo{
            .sType = .VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .codeSize = __glsl_shader_vert_spv.len * 4,
            .pCode = &__glsl_shader_vert_spv,
        };
        err = vkCreateShaderModule(ctx.device, &vert_info, ctx.vk_allocator, &vert_module);
        try check_vk_result(err);
        const frag_info = VkShaderModuleCreateInfo{
            .sType = .VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .codeSize = __glsl_shader_frag_spv.len * 4,
            .pCode = &__glsl_shader_frag_spv,
        };
        err = vkCreateShaderModule(ctx.device, &frag_info, ctx.vk_allocator, &frag_module);
        try check_vk_result(err);
    }

    // Create the image sampler:
    {
        const info = VkSamplerCreateInfo{
            .sType = .VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .magFilter = .VK_FILTER_LINEAR,
            .minFilter = .VK_FILTER_LINEAR,
            .mipmapMode = .VK_SAMPLER_MIPMAP_MODE_LINEAR,
            .addressModeU = .VK_SAMPLER_ADDRESS_MODE_REPEAT,
            .addressModeV = .VK_SAMPLER_ADDRESS_MODE_REPEAT,
            .addressModeW = .VK_SAMPLER_ADDRESS_MODE_REPEAT,
            .minLod = -1000,
            .maxLod = 1000,
            .mipLodBias = 0,
            .maxAnisotropy = 1.0,
            .anisotropyEnable = 0,
            .compareEnable = 0,
            .compareOp = .VK_COMPARE_OP_NEVER,
            .borderColor = .VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK,
            .unnormalizedCoordinates = 0,
        };
        err = vkCreateSampler(ctx.device, &info, ctx.vk_allocator, &ctx.samplerTiling);
        try check_vk_result(err);
    }

    {
        const sampler = [_]VkSampler{ctx.samplerTiling};
        const binding = [_]VkDescriptorSetLayoutBinding{
            VkDescriptorSetLayoutBinding{
                .descriptorType = .VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .descriptorCount = 1,
                .binding = 0,
                .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT,
                .pImmutableSamplers = &sampler,
            },
        };
        const info = VkDescriptorSetLayoutCreateInfo{
            .sType = .VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .bindingCount = binding.len,
            .pBindings = &binding,
        };
        err = vkCreateDescriptorSetLayout(ctx.device, &info, ctx.vk_allocator, &ctx.descriptorSetLayout);
        try check_vk_result(err);
    }

    if (ctx.pipelineLayout == null) {
        // Constants: we are using 'vec2 offset' and 'vec2 scale' instead of a full 3d projection matrix
        const push_constants = [_]VkPushConstantRange{
            VkPushConstantRange{
                .stageFlags = VK_SHADER_STAGE_VERTEX_BIT,
                .offset = @sizeOf(f32) * 0,
                .size = @sizeOf(f32) * 4,
            },
        };
        const set_layout = [_]VkDescriptorSetLayout{ctx.descriptorSetLayout};
        const layout_info = VkPipelineLayoutCreateInfo{
            .sType = .VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .setLayoutCount = set_layout.len,
            .pSetLayouts = &set_layout,
            .pushConstantRangeCount = push_constants.len,
            .pPushConstantRanges = &push_constants,
        };
        err = vkCreatePipelineLayout(ctx.device, &layout_info, ctx.vk_allocator, &ctx.pipelineLayout);
        try check_vk_result(err);
    }

    const stages = [_]VkPipelineShaderStageCreateInfo{
        VkPipelineShaderStageCreateInfo{
            .sType = .VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stage = .VK_SHADER_STAGE_VERTEX_BIT,
            .module = vert_module,
            .pName = "main",
            .pSpecializationInfo = null,
        },
        VkPipelineShaderStageCreateInfo{
            .sType = .VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stage = .VK_SHADER_STAGE_FRAGMENT_BIT,
            .module = frag_module,
            .pName = "main",
            .pSpecializationInfo = null,
        },
    };

    const binding_desc = [_]VkVertexInputBindingDescription{
        VkVertexInputBindingDescription{ .binding = 0, .stride = @sizeOf(c.ImDrawVert), .inputRate = .VK_VERTEX_INPUT_RATE_VERTEX },
    };

    const attribute_desc = [_]VkVertexInputAttributeDescription{
        VkVertexInputAttributeDescription{ .location = 0, .binding = binding_desc[0].binding, .format = .VK_FORMAT_R32G32_SFLOAT, .offset = @byteOffsetOf(c.ImDrawVert, "pos") },
        VkVertexInputAttributeDescription{ .location = 1, .binding = binding_desc[0].binding, .format = .VK_FORMAT_R32G32_SFLOAT, .offset = @byteOffsetOf(c.ImDrawVert, "uv") },
        VkVertexInputAttributeDescription{ .location = 2, .binding = binding_desc[0].binding, .format = .VK_FORMAT_R8G8B8A8_UNORM, .offset = @byteOffsetOf(c.ImDrawVert, "col") },
    };

    const vertex_info = VkPipelineVertexInputStateCreateInfo{
        .sType = .VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .vertexBindingDescriptionCount = binding_desc.len,
        .pVertexBindingDescriptions = &binding_desc,
        .vertexAttributeDescriptionCount = attribute_desc.len,
        .pVertexAttributeDescriptions = &attribute_desc,
    };

    const ia_info = VkPipelineInputAssemblyStateCreateInfo{
        .sType = .VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .topology = .VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        .primitiveRestartEnable = 0,
    };

    const viewport_info = VkPipelineViewportStateCreateInfo{
        .sType = .VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .viewportCount = 1,
        .scissorCount = 1,
        .pViewports = null,
        .pScissors = null,
    };

    const raster_info = VkPipelineRasterizationStateCreateInfo{
        .sType = .VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .polygonMode = .VK_POLYGON_MODE_FILL,
        .cullMode = VK_CULL_MODE_NONE,
        .frontFace = .VK_FRONT_FACE_COUNTER_CLOCKWISE,
        .lineWidth = 1.0,
        .rasterizerDiscardEnable = 0,
        .depthBiasEnable = 0,
        .depthBiasConstantFactor = 0,
        .depthBiasClamp = 0,
        .depthBiasSlopeFactor = 0,
        .depthClampEnable = 0,
    };

    const ms_info = VkPipelineMultisampleStateCreateInfo{
        .sType = .VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .rasterizationSamples = if (@enumToInt(ctx.MSAASamples) != 0) ctx.MSAASamples else .VK_SAMPLE_COUNT_1_BIT,
        .sampleShadingEnable = 0,
        .minSampleShading = 0,
        .pSampleMask = 0,
        .alphaToCoverageEnable = 0,
        .alphaToOneEnable = 0,
    };

    const color_attachment = [_]VkPipelineColorBlendAttachmentState{
        VkPipelineColorBlendAttachmentState{
            .blendEnable = VK_TRUE,
            .srcColorBlendFactor = .VK_BLEND_FACTOR_SRC_ALPHA,
            .dstColorBlendFactor = .VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .colorBlendOp = .VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = .VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .dstAlphaBlendFactor = .VK_BLEND_FACTOR_ZERO,
            .alphaBlendOp = .VK_BLEND_OP_ADD,
            .colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT | VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT,
        },
    };

    const depth_info = VkPipelineDepthStencilStateCreateInfo{
        .sType = .VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .depthTestEnable = 0,
        .depthWriteEnable = 0,
        .depthCompareOp = .VK_COMPARE_OP_NEVER,
        .depthBoundsTestEnable = 0,
        .stencilTestEnable = 0,
        .front = VkStencilOpState{
            .failOp = .VK_STENCIL_OP_KEEP,
            .passOp = .VK_STENCIL_OP_KEEP,
            .depthFailOp = .VK_STENCIL_OP_KEEP,
            .compareOp = .VK_COMPARE_OP_NEVER,
            .compareMask = 0,
            .writeMask = 0,
            .reference = 0,
        },
        .back = VkStencilOpState{
            .failOp = .VK_STENCIL_OP_KEEP,
            .passOp = .VK_STENCIL_OP_KEEP,
            .depthFailOp = .VK_STENCIL_OP_KEEP,
            .compareOp = .VK_COMPARE_OP_NEVER,
            .compareMask = 0,
            .writeMask = 0,
            .reference = 0,
        },
        .minDepthBounds = 0,
        .maxDepthBounds = 0,
    };

    const blend_info = VkPipelineColorBlendStateCreateInfo{
        .sType = .VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .attachmentCount = color_attachment.len,
        .pAttachments = &color_attachment,
        .logicOpEnable = 0,
        .logicOp = .VK_LOGIC_OP_CLEAR,
        .blendConstants = [_]f32{ 0, 0, 0, 0 },
    };

    const dynamic_states = [_]VkDynamicState{ .VK_DYNAMIC_STATE_VIEWPORT, .VK_DYNAMIC_STATE_SCISSOR };
    const dynamic_state = VkPipelineDynamicStateCreateInfo{
        .sType = .VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .dynamicStateCount = dynamic_states.len,
        .pDynamicStates = &dynamic_states,
    };

    const info = VkGraphicsPipelineCreateInfo{
        .sType = .VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .pNext = null,
        .flags = ctx.pipelineCreateFlags,
        .stageCount = stages.len,
        .pStages = &stages,
        .pVertexInputState = &vertex_info,
        .pInputAssemblyState = &ia_info,
        .pViewportState = &viewport_info,
        .pRasterizationState = &raster_info,
        .pMultisampleState = &ms_info,
        .pDepthStencilState = &depth_info,
        .pColorBlendState = &blend_info,
        .pDynamicState = &dynamic_state,
        .layout = ctx.pipelineLayout,
        .renderPass = ctx.mainWindowData.renderPass,
        .pTessellationState = null,
        .subpass = 0,
        .basePipelineHandle = null,
        .basePipelineIndex = 0,
    };
    err = vkCreateGraphicsPipelines(ctx.device, ctx.pipelineCache, 1, &info, ctx.vk_allocator, &ctx.pipeline);
    try check_vk_result(err);

    vkDestroyShaderModule(ctx.device, vert_module, ctx.vk_allocator);
    vkDestroyShaderModule(ctx.device, frag_module, ctx.vk_allocator);
}

fn destroyDeviceObjects(ctx: *Context) void {
    for (ctx.drawTextureUploads.items) |*texupload| {
        destroyTextureUpload(ctx.device, texupload, ctx.vk_allocator);
    }
    ctx.drawTextureUploads.resize(0) catch unreachable;

    // for (ctx.texturePool.items) |*tex| {
    //     destroyTexture(ctx.device, tex, ctx.vk_allocator);
    // }
    // ctx.texturePool.resize(0) catch unreachable;
    ctx.drawQuads.resize(0) catch unreachable;

    destroyTexture(ctx.device, &ctx.fontTexture, ctx.vk_allocator);

    if (ctx.descriptorSetLayout != null) {
        vkDestroyDescriptorSetLayout(ctx.device, ctx.descriptorSetLayout, ctx.vk_allocator);
        ctx.descriptorSetLayout = null;
    }
    if (ctx.samplerTiling != null) {
        vkDestroySampler(ctx.device, ctx.samplerTiling, ctx.vk_allocator);
        ctx.samplerTiling = null;
    }
    if (ctx.pipelineLayout != null) {
        vkDestroyPipelineLayout(ctx.device, ctx.pipelineLayout, ctx.vk_allocator);
        ctx.pipelineLayout = null;
    }

    if (ctx.pipeline != null) {
        vkDestroyPipeline(ctx.device, ctx.pipeline, ctx.vk_allocator);
        ctx.pipeline = null;
    }
}

//-------------------------------------------------------------------------

export fn ImGui_ImplVulkan_Init(ctx: *Context) bool {
    return _Init(ctx) catch |err| return false;
}
fn _Init(ctx: *Context) !bool {
    // Setup back-end capabilities flags
    const io: *c.ImGuiIO = c.igGetIO();
    io.BackendRendererName = "imgui_impl_vulkan";
    io.BackendFlags |= c.ImGuiBackendFlags_RendererHasVtxOffset; // We can honor the ImDrawCmd::VtxOffset field, allowing for large meshes.

    assert(ctx.instance != null);
    assert(ctx.physicalDevice != null);
    assert(ctx.device != null);
    assert(ctx.queue != null);
    assert(ctx.descriptorPool != null);
    assert(ctx.minImageCount >= 2);
    assert(ctx.mainWindowData.frames.len >= ctx.minImageCount);
    assert(ctx.mainWindowData.renderPass != null);

    try createDeviceObjects(ctx);

    // Upload Fonts
    {
        var pixels: [*c]u8 = undefined;
        var width: c_int = undefined;
        var height: c_int = undefined;
        var bpp: c_int = undefined;
        c.ImFontAtlas_GetTexDataAsRGBA32(io.Fonts, &pixels, &width, &height, &bpp);
        assert(bpp == 4);
        const upload_size: usize = @intCast(usize, width * height * bpp) * @sizeOf(u8);

        try initTexture(ctx, &ctx.fontTexture, @intCast(u32, width), @intCast(u32, height));
        c.ImFontAtlas_SetTexID(io.Fonts, @ptrCast(c.ImTextureID, ctx.fontTexture.image));

        const texupload = try ctx.drawTextureUploads.addOne();
        try initTextureUpload(ctx, texupload, pixels[0..upload_size], &ctx.fontTexture);
    }

    return true;
}

export fn ImGui_ImplVulkan_Shutdown(ctx: *Context) void {
    _Shutdown(ctx) catch unreachable;
}
fn _Shutdown(ctx: *Context) !void {
    var err: VkResult = undefined;
    err = vkDeviceWaitIdle(ctx.device);
    try check_vk_result(err);

    destroyDeviceObjects(ctx);
}

pub fn blitPixels(ctx: *Context, corners: [4]Vec2, pixels: []const u8, width: u32, height: u32) !void {
    //const t = try ctx.texturePool.addOne();
    const t = try ctx.allocator.create(Texture);
    try initTexture(ctx, t, width, height);
    const texupload = try ctx.drawTextureUploads.addOne();
    try initTextureUpload(ctx, texupload, pixels, t);

    const q = try ctx.drawQuads.addOne();
    q.corners = corners;
    q.texture = t;
}

//-------------------------------------------------------------------------

fn selectSurfaceFormat(physical_device: VkPhysicalDevice, surface: VkSurfaceKHR, request_formats: []const VkFormat, request_color_space: VkColorSpaceKHR) VkSurfaceFormatKHR {
    assert(request_formats.len != 0);

    var err: VkResult = undefined;

    // Per Spec Format and view Format are expected to be the same unless VK_IMAGE_CREATE_MUTABLE_BIT was set at image creation
    // Assuming that the default behavior is without setting this bit, there is no need for separate swapchain image and image view format
    // Additionally several new color spaces were introduced with Vulkan Spec v1.0.40,
    // hence we must make sure that a format with the mostly available color space, VK_COLOR_SPACE_SRGB_NONLINEAR_KHR, is found and used.
    var storage: [100]VkSurfaceFormatKHR = undefined;
    var avail_count: u32 = undefined;
    err = vkGetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &avail_count, null);
    const avail_format = storage[0..avail_count];
    err = vkGetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &avail_count, avail_format.ptr);

    // First check if only one format, VK_FORMAT_UNDEFINED, is available, which would imply that any format is available
    if (avail_count == 1) {
        if (avail_format[0].format == .VK_FORMAT_UNDEFINED) {
            const ret = VkSurfaceFormatKHR{
                .format = request_formats[0],
                .colorSpace = request_color_space,
            };
            return ret;
        } else {
            // No point in searching another format
            return avail_format[0];
        }
    } else {
        // Request several formats, the first found will be used
        for (request_formats) |req| {
            for (avail_format) |avail| {
                if (avail.format == req and avail.colorSpace == request_color_space)
                    return avail;
            }
        }

        // If none of the requested image formats could be found, use the first available
        return avail_format[0];
    }
}

fn selectPresentMode(physical_device: VkPhysicalDevice, surface: VkSurfaceKHR, request_modes: []const VkPresentModeKHR) VkPresentModeKHR {
    assert(request_modes.len != 0);

    var err: VkResult = undefined;

    // Request a certain mode and confirm that it is available. If not use VK_PRESENT_MODE_FIFO_KHR which is mandatory
    var avail_count: u32 = 0;
    var storage: [100]VkPresentModeKHR = undefined;
    err = vkGetPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, &avail_count, null);
    assert(avail_count < 100);
    const avail_modes = storage[0..avail_count];
    err = vkGetPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, &avail_count, avail_modes.ptr);

    for (request_modes) |req| {
        for (avail_modes) |avail| {
            if (req == avail)
                return req;
        }
    }

    return .VK_PRESENT_MODE_FIFO_KHR; // Always available
}

fn createWindowCommandBuffers(physical_device: VkPhysicalDevice, device: VkDevice, wd: *VulkanWindow, queue_family: u32, vk_allocator: ?*const VkAllocationCallbacks) !void {
    assert(physical_device != null and device != null);

    var err: VkResult = undefined;

    // Create Command Buffers
    for (wd.frames) |*fd| {
        {
            const info = VkCommandPoolCreateInfo{
                .sType = .VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
                .pNext = null,
                .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
                .queueFamilyIndex = queue_family,
            };
            err = vkCreateCommandPool(device, &info, vk_allocator, &fd.commandPool);
            try check_vk_result(err);
        }
        {
            const info = VkCommandBufferAllocateInfo{
                .sType = .VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
                .pNext = null,
                .commandPool = fd.commandPool,
                .level = .VK_COMMAND_BUFFER_LEVEL_PRIMARY,
                .commandBufferCount = 1,
            };
            err = vkAllocateCommandBuffers(device, &info, &fd.commandBuffer);
            try check_vk_result(err);
        }
        {
            const info = VkFenceCreateInfo{
                .sType = .VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
                .pNext = null,
                .flags = VK_FENCE_CREATE_SIGNALED_BIT,
            };
            err = vkCreateFence(device, &info, vk_allocator, &fd.fence);
            try check_vk_result(err);
        }
    }

    for (wd.frameSemaphores) |*fsd| {
        {
            const info = VkSemaphoreCreateInfo{
                .sType = .VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
            };

            err = vkCreateSemaphore(device, &info, vk_allocator, &fsd.imageAcquiredSemaphore);
            try check_vk_result(err);
            err = vkCreateSemaphore(device, &info, vk_allocator, &fsd.renderCompleteSemaphore);
            try check_vk_result(err);
        }
    }
}

// Also destroy old swap chain and in-flight frames data, if any.
fn createWindowSwapChain(physical_device: VkPhysicalDevice, device: VkDevice, wd: *VulkanWindow, descriptorPool: VkDescriptorPool, allocator: *Allocator, vk_allocator: ?*const VkAllocationCallbacks, w: u32, h: u32, min_image_count: u32) !void {
    var err: VkResult = undefined;
    const old_swapchain = wd.swapchain;
    err = vkDeviceWaitIdle(device);
    try check_vk_result(err);

    // We don't use destroyWindow() because we want to preserve the old swapchain to create the new one.
    // Destroy old framebuffer
    for (wd.frameSemaphores) |*frameSemaphore| {
        destroySwapchainSemaphores(device, frameSemaphore, vk_allocator);
    }
    for (wd.frames) |*frame| {
        destroyFrame(device, frame, vk_allocator);
    }
    for (wd.frameRenderData) |*frd| {
        destroyFrameRenderData(device, frd, descriptorPool, vk_allocator);
    }
    allocator.free(wd.frameRenderData);
    allocator.free(wd.frames);
    allocator.free(wd.frameSemaphores);
    wd.frames = &[0]SwapchainFrame{};
    wd.frameSemaphores = &[0]SwapchainSemaphores{};
    wd.frameRenderData = &[0]FrameRenderData{};
    if (wd.renderPass != null)
        vkDestroyRenderPass(device, wd.renderPass, vk_allocator);

    // If min image count was not specified, request different count of images dependent on selected present mode
    var image_count = min_image_count;
    if (image_count == 0) {
        image_count = mincount: {
            if (wd.presentMode == .VK_PRESENT_MODE_MAILBOX_KHR) break :mincount 3;
            if (wd.presentMode == .VK_PRESENT_MODE_FIFO_KHR or wd.presentMode == .VK_PRESENT_MODE_FIFO_RELAXED_KHR) break :mincount 2;
            if (wd.presentMode == .VK_PRESENT_MODE_IMMEDIATE_KHR) break :mincount 1;
            unreachable;
        };
    }

    // Create swapchain
    var swapchainImageCount: u32 = undefined;
    var backbuffers = [_]VkImage{null} ** 16;
    {
        var cap: VkSurfaceCapabilitiesKHR = undefined;
        err = vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, wd.surface, &cap);
        try check_vk_result(err);

        wd.width = if (cap.currentExtent.width == 0xffffffff) w else cap.currentExtent.width;
        wd.height = if (cap.currentExtent.height == 0xffffffff) h else cap.currentExtent.height;

        const info = VkSwapchainCreateInfoKHR{
            .sType = .VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .pNext = null,
            .flags = 0,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .surface = wd.surface,
            .minImageCount = if (image_count < cap.minImageCount) cap.minImageCount else if (cap.maxImageCount != 0 and image_count > cap.maxImageCount) cap.maxImageCount else image_count,
            .imageFormat = wd.surfaceFormat.format,
            .imageColorSpace = wd.surfaceFormat.colorSpace,
            .imageArrayLayers = 1,
            .imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            .imageSharingMode = .VK_SHARING_MODE_EXCLUSIVE, // Assume that graphics family == present famil,
            .preTransform = .VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR,
            .compositeAlpha = .VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            .presentMode = wd.presentMode,
            .clipped = VK_TRUE,
            .oldSwapchain = old_swapchain,
            .imageExtent = VkExtent2D{ .width = wd.width, .height = wd.height },
        };

        err = vkCreateSwapchainKHR(device, &info, vk_allocator, &wd.swapchain);
        try check_vk_result(err);
        err = vkGetSwapchainImagesKHR(device, wd.swapchain, &swapchainImageCount, null);
        try check_vk_result(err);

        assert(swapchainImageCount >= image_count);
        assert(swapchainImageCount < backbuffers.len);
        err = vkGetSwapchainImagesKHR(device, wd.swapchain, &swapchainImageCount, &backbuffers);
        try check_vk_result(err);
    }

    {
        assert(wd.frames.len == 0 and wd.frameSemaphores.len == 0 and wd.frameRenderData.len == 0);
        wd.frames = try allocator.alloc(SwapchainFrame, swapchainImageCount);
        wd.frameSemaphores = try allocator.alloc(SwapchainSemaphores, swapchainImageCount);
        std.mem.set(SwapchainSemaphores, wd.frameSemaphores, SwapchainSemaphores{});
        for (wd.frames) |*frame, i| {
            frame.* = SwapchainFrame{ .backbuffer = backbuffers[i] };
        }

        wd.renderDataIndex = 0;
        wd.frameRenderData = try allocator.alloc(FrameRenderData, swapchainImageCount);
        for (wd.frameRenderData) |*frd| {
            frd.* = FrameRenderData{
                .activeTextureUploads = ArrayList(TextureUpload).init(allocator),
                .activeTranscientTexture = ArrayList(*Texture).init(allocator),
            };
        }
    }
    if (old_swapchain != null)
        vkDestroySwapchainKHR(device, old_swapchain, vk_allocator);

    // Create the Render Pass
    {
        const attachment = VkAttachmentDescription{
            .format = wd.surfaceFormat.format,
            .flags = 0,
            .samples = .VK_SAMPLE_COUNT_1_BIT,
            .loadOp = if (wd.clearEnable) .VK_ATTACHMENT_LOAD_OP_CLEAR else .VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .storeOp = .VK_ATTACHMENT_STORE_OP_STORE,
            .stencilLoadOp = .VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = .VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = .VK_IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = .VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        };
        const color_attachment = VkAttachmentReference{
            .attachment = 0,
            .layout = .VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        };
        const subpass = VkSubpassDescription{
            .pipelineBindPoint = .VK_PIPELINE_BIND_POINT_GRAPHICS,
            .colorAttachmentCount = 1,
            .pColorAttachments = &color_attachment,
            .flags = 0,
            .inputAttachmentCount = 0,
            .pInputAttachments = null,
            .pResolveAttachments = null,
            .pDepthStencilAttachment = null,
            .preserveAttachmentCount = 0,
            .pPreserveAttachments = null,
        };
        const dependency = VkSubpassDependency{
            .srcSubpass = VK_SUBPASS_EXTERNAL,
            .dstSubpass = 0,
            .srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .srcAccessMask = 0,
            .dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .dependencyFlags = 0,
        };
        const info = VkRenderPassCreateInfo{
            .sType = .VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .attachmentCount = 1,
            .pAttachments = &attachment,
            .subpassCount = 1,
            .pSubpasses = &subpass,
            .dependencyCount = 1,
            .pDependencies = &dependency,
        };
        err = vkCreateRenderPass(device, &info, vk_allocator, &wd.renderPass);
        try check_vk_result(err);
    }

    // Create The image Views
    {
        var info = VkImageViewCreateInfo{
            .sType = .VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .viewType = .VK_IMAGE_VIEW_TYPE_2D,
            .format = wd.surfaceFormat.format,
            .components = VkComponentMapping{ .r = .VK_COMPONENT_SWIZZLE_R, .g = .VK_COMPONENT_SWIZZLE_G, .b = .VK_COMPONENT_SWIZZLE_B, .a = .VK_COMPONENT_SWIZZLE_A },
            .subresourceRange = VkImageSubresourceRange{ .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 },
            .image = undefined,
        };
        for (wd.frames) |*fd| {
            info.image = fd.backbuffer;
            err = vkCreateImageView(device, &info, vk_allocator, &fd.backbufferView);
            try check_vk_result(err);
        }
    }

    // Create framebuffer
    {
        var attachment: [1]VkImageView = undefined;
        const info = VkFramebufferCreateInfo{
            .sType = .VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .renderPass = wd.renderPass,
            .attachmentCount = attachment.len,
            .pAttachments = &attachment,
            .width = wd.width,
            .height = wd.height,
            .layers = 1,
        };
        for (wd.frames) |*fd| {
            attachment[0] = fd.backbufferView;
            err = vkCreateFramebuffer(device, &info, vk_allocator, &fd.framebuffer);
            try check_vk_result(err);
        }
    }
}

fn createWindow(instance: VkInstance, physical_device: VkPhysicalDevice, device: VkDevice, wd: *VulkanWindow, queue_family: u32, descriptorPool: VkDescriptorPool, allocator: *Allocator, vk_allocator: ?*const VkAllocationCallbacks, width: u32, height: u32, min_image_count: u32) !void {
    try createWindowSwapChain(physical_device, device, wd, descriptorPool, allocator, vk_allocator, width, height, min_image_count);
    try createWindowCommandBuffers(physical_device, device, wd, queue_family, vk_allocator);
}

fn destroyWindow(instance: VkInstance, device: VkDevice, wd: *VulkanWindow, descriptorPool: VkDescriptorPool, allocator: *Allocator, vk_allocator: ?*const VkAllocationCallbacks) void {
    var err: VkResult = undefined;
    err = vkDeviceWaitIdle(device); // FIXME: We could wait on the queue if we had the queue in wd. (otherwise VulkanH functions can't use globals)
    //vkQueueWaitIdle(g_Queue);

    for (wd.frameRenderData) |*frd| {
        destroyFrameRenderData(device, frd, descriptorPool, vk_allocator);
    }
    for (wd.frameSemaphores) |*frameSemaphore| {
        destroySwapchainSemaphores(device, frameSemaphore, vk_allocator);
    }
    for (wd.frames) |*frame| {
        destroyFrame(device, frame, vk_allocator);
    }
    allocator.free(wd.frameRenderData);
    allocator.free(wd.frames);
    allocator.free(wd.frameSemaphores);
    wd.frames = &[0]SwapchainFrame{};
    wd.frameSemaphores = &[0]SwapchainSemaphores{};
    wd.frameRenderData = &[0]FrameRenderData{};

    vkDestroyRenderPass(device, wd.renderPass, vk_allocator);
    vkDestroySwapchainKHR(device, wd.swapchain, vk_allocator);
    vkDestroySurfaceKHR(instance, wd.surface, vk_allocator);
}

fn destroyFrame(device: VkDevice, fd: *SwapchainFrame, vk_allocator: ?*const VkAllocationCallbacks) void {
    vkDestroyFence(device, fd.fence, vk_allocator);
    vkFreeCommandBuffers(device, fd.commandPool, 1, &fd.commandBuffer);
    vkDestroyCommandPool(device, fd.commandPool, vk_allocator);
    fd.fence = null;
    fd.commandBuffer = null;
    fd.commandPool = null;

    vkDestroyImageView(device, fd.backbufferView, vk_allocator);
    vkDestroyFramebuffer(device, fd.framebuffer, vk_allocator);
}

fn destroySwapchainSemaphores(device: VkDevice, fsd: *SwapchainSemaphores, vk_allocator: ?*const VkAllocationCallbacks) void {
    vkDestroySemaphore(device, fsd.imageAcquiredSemaphore, vk_allocator);
    vkDestroySemaphore(device, fsd.renderCompleteSemaphore, vk_allocator);
    fsd.imageAcquiredSemaphore = null;
    fsd.renderCompleteSemaphore = null;
}

fn destroyFrameRenderData(device: VkDevice, frd: *FrameRenderData, descriptorPool: VkDescriptorPool, vk_allocator: ?*const VkAllocationCallbacks) void {
    for (frd.data) |*data| {
        if (data.descriptorSet != null) {
            _ = vkFreeDescriptorSets(device, descriptorPool, 1, &data.descriptorSet);
            data.descriptorSet = null;
        }
        if (data.vertex != null) {
            vkDestroyBuffer(device, data.vertex, vk_allocator);
            data.vertex = null;
        }
        if (data.vertexMemory != null) {
            vkFreeMemory(device, data.vertexMemory, vk_allocator);
            data.vertexMemory = null;
        }
        if (data.index != null) {
            vkDestroyBuffer(device, data.index, vk_allocator);
            data.index = null;
        }
        if (data.indexMemory != null) {
            vkFreeMemory(device, data.indexMemory, vk_allocator);
            data.indexMemory = null;
        }
        data.vertexSize = 0;
        data.indexSize = 0;
    }

    for (frd.activeTextureUploads.items) |*texupload| {
        destroyTextureUpload(device, texupload, vk_allocator);
    }
    frd.activeTextureUploads.deinit();

    for (frd.activeTranscientTexture.items) |tex| {
        destroyTexture(device, tex, vk_allocator);
    }
    frd.activeTranscientTexture.deinit();
}

//---------------------------------

extern fn imguiImpl_Init(title: [*:0]const u8, width: c_int, height: c_int, ctx: *Context) bool;
extern fn imguiImpl_Destroy(ctx: *Context) void;
extern fn imguiImpl_GetWindowSize(ctx: *Context, width: *u32, height: *u32) void;
extern fn imguiImpl_NewFrameSDL(ctx: *Context) void;

pub fn init(title: [*:0]const u8, width: c_int, height: c_int, allocator: *Allocator) !*Context {
    const ctx = try allocator.create(Context);
    errdefer allocator.destroy(ctx);
    ctx.* = Context{
        .allocator = allocator,
        .drawTextureUploads = ArrayList(TextureUpload).init(allocator),
        // .texturePool = ArrayList(Texture).init(allocator),
        .drawQuads = ArrayList(Quad).init(allocator),
    };

    const ok = imguiImpl_Init(title, width, height, ctx);
    if (!ok)
        return error.SDLInitializationFailed;

    return ctx;
}

pub fn destroy(ctx: *Context) void {
    imguiImpl_Destroy(ctx);
    ctx.drawTextureUploads.deinit();
    //ctx.texturePool.deinit();
    ctx.drawQuads.deinit();

    ctx.allocator.destroy(ctx);
}

pub const getWindowSize = imguiImpl_GetWindowSize;

pub fn beginFrame(ctx: *Context) void {
    imguiImpl_NewFrameSDL(ctx);
    c.igNewFrame();
}

fn findInSlice(comptime T: type, slice: []const T, ptr: *const T) usize {
    // return ptr - slice.ptr;
    const start = @ptrToInt(slice.ptr);
    const elem = @ptrToInt(ptr);
    assert(elem >= start);
    const offset = elem - start;
    const i = offset / @sizeOf(T);
    assert(i < slice.len);
    return i;
}

fn frameRender(ctx: *Context, wd: *VulkanWindow) !void {
    const u64max = std.math.maxInt(u64);

    const image_acquired_semaphore = wd.frameSemaphores[wd.semaphoreIndex].imageAcquiredSemaphore;
    const render_complete_semaphore = wd.frameSemaphores[wd.semaphoreIndex].renderCompleteSemaphore;
    var err = vkAcquireNextImageKHR(ctx.device, wd.swapchain, u64max, image_acquired_semaphore, null, &wd.frameIndex);
    if (err == .VK_ERROR_OUT_OF_DATE_KHR or err == .VK_SUBOPTIMAL_KHR) {
        return error.SwapchainOutOfDate;
    }
    try check_vk_result(err);

    const fd = &wd.frames[wd.frameIndex];
    {
        err = vkWaitForFences(ctx.device, 1, &fd.fence, VK_TRUE, u64max); // wait indefinitely instead of periodically checking
        try check_vk_result(err);

        err = vkResetFences(ctx.device, 1, &fd.fence);
        try check_vk_result(err);
    }
    {
        err = vkResetCommandPool(ctx.device, fd.commandPool, 0);
        try check_vk_result(err);

        const info = VkCommandBufferBeginInfo{
            .pNext = null,
            .pInheritanceInfo = null,
            .sType = .VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        };
        err = vkBeginCommandBuffer(fd.commandBuffer, &info);
        try check_vk_result(err);
    }

    wd.renderDataIndex = @intCast(u32, (wd.renderDataIndex + 1) % wd.frameRenderData.len);
    const frd = &wd.frameRenderData[wd.renderDataIndex];

    // clean previous texture uploads form the previousb use of frd + flush new ones
    {
        for (frd.activeTextureUploads.items) |*texupload| {
            destroyTextureUpload(ctx.device, texupload, ctx.vk_allocator);
        }
        frd.activeTextureUploads.resize(0) catch unreachable;

        for (frd.activeTranscientTexture.items) |t| {
            destroyTexture(ctx.device, t, ctx.vk_allocator);
            //const i = findInSlice(Texture, ctx.texturePool.toSliceConst(), t);
            //_ = ctx.texturePool.swapRemove(i);
            ctx.allocator.destroy(t);
        }
        frd.activeTranscientTexture.resize(0) catch unreachable;

        for (ctx.drawTextureUploads.items) |*texupload| {
            flushTextureUpload(ctx, fd.commandBuffer, texupload);
            try frd.activeTextureUploads.append(texupload.*);
        }
        ctx.drawTextureUploads.resize(0) catch unreachable;
    }

    {
        const info = VkRenderPassBeginInfo{
            .pNext = null,
            .sType = .VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            .renderPass = wd.renderPass,
            .framebuffer = fd.framebuffer,
            .renderArea = VkRect2D{ .offset = VkOffset2D{ .x = 0, .y = 0 }, .extent = VkExtent2D{ .width = wd.width, .height = wd.height } },
            .clearValueCount = 1,
            .pClearValues = &wd.clearValue,
        };
        vkCmdBeginRenderPass(fd.commandBuffer, &info, .VK_SUBPASS_CONTENTS_INLINE);
    }

    // Avoid rendering when minimized, scale coordinates for retina displays (screen coordinates != framebuffer coordinates)
    const draw_data: *c.ImDrawData = c.igGetDrawData();
    if (wd.width > 0 and wd.height > 0 and draw_data.TotalVtxCount > 0) {

        // Our visible imgui space lies from draw_data.DisplayPps (top left) to draw_data.DisplayPos+data_data.DisplaySize (bottom right). DisplayPos is (0,0) for single viewport apps.
        const scale = [2]f32{
            2.0 / draw_data.DisplaySize.x,
            2.0 / draw_data.DisplaySize.y,
        };
        const displayTransfo = DisplayTransfo{
            .scale = scale,
            .translate = [2]f32{
                -1.0 - draw_data.DisplayPos.x * scale[0],
                -1.0 - draw_data.DisplayPos.y * scale[1],
            },
            .fb_width = wd.width,
            .fb_height = wd.height,
        };

        for (ctx.drawQuads.items) |quad| {
            try renderQuad(ctx, frd, displayTransfo, quad, fd.commandBuffer);
        }
        try renderDrawData(ctx, frd, displayTransfo, draw_data, fd.commandBuffer);
    }

    vkCmdEndRenderPass(fd.commandBuffer);

    {
        for (ctx.drawQuads.items) |*quad| {
            try frd.activeTranscientTexture.append(quad.texture);
        }
        ctx.drawQuads.resize(0) catch unreachable;
    }

    {
        err = vkEndCommandBuffer(fd.commandBuffer);
        try check_vk_result(err);

        const wait_stage = [_]u32{VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT};
        const info = VkSubmitInfo{
            .pNext = null,
            .sType = .VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &image_acquired_semaphore,
            .pWaitDstStageMask = &wait_stage,
            .commandBufferCount = 1,
            .pCommandBuffers = &fd.commandBuffer,
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = &render_complete_semaphore,
        };
        err = vkQueueSubmit(ctx.queue, 1, &info, fd.fence);
        try check_vk_result(err);
    }
}

fn framePresent(queue: VkQueue, wd: *VulkanWindow) !void {
    var render_complete_semaphore = wd.frameSemaphores[wd.semaphoreIndex].renderCompleteSemaphore;
    const info = VkPresentInfoKHR{
        .pNext = null,
        .pResults = null,
        .sType = .VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &render_complete_semaphore,
        .swapchainCount = 1,
        .pSwapchains = &wd.swapchain,
        .pImageIndices = &wd.frameIndex,
    };
    var err = vkQueuePresentKHR(queue, &info);
    if (err == .VK_ERROR_OUT_OF_DATE_KHR or err == .VK_SUBOPTIMAL_KHR)
        return error.SwapchainOutOfDate;
    try check_vk_result(err);

    wd.semaphoreIndex = (wd.semaphoreIndex + 1) % @intCast(u32, wd.frameSemaphores.len); // Now we can use the next set of semaphores
}

fn frameRebuildSwapchain(ctx: *Context) !void {
    var w: u32 = undefined;
    var h: u32 = undefined;
    getWindowSize(ctx, &w, &h);

    try createWindow(ctx.instance, ctx.physicalDevice, ctx.device, &ctx.mainWindowData, ctx.queueFamily, ctx.descriptorPool, ctx.allocator, ctx.vk_allocator, w, h, ctx.minImageCount);
    ctx.mainWindowData.frameIndex = 0;
}

pub fn endFrame(ctx: *Context) !void {
    c.igRender();

    var swapchain_ok = true;
    while (true) {
        frameRender(ctx, &ctx.mainWindowData) catch |err| switch (err) {
            error.SwapchainOutOfDate => {
                try frameRebuildSwapchain(ctx);
                continue;
            }, // try again
            error.VulkanError => return error.VulkanError,
            error.OutOfMemory => return error.OutOfMemory,
        };

        framePresent(ctx.queue, &ctx.mainWindowData) catch |err| switch (err) {
            error.SwapchainOutOfDate => {
                try frameRebuildSwapchain(ctx);
                continue;
            }, // try again
            error.VulkanError => return error.VulkanError,
        };

        return; // success
    }
}

// -------------------------------------------------------------------------------------------

pub export fn debug_report(flags: VkDebugReportFlagsEXT, objectType: VkDebugReportObjectTypeEXT, object: u64, location: usize, messageCode: i32, pLayerPrefix: [*c]const u8, pMessage: [*c]const u8, pUserData: ?*c_void) u32 {
    warn("[vulkan] ObjectType: {}\nMessage: {s}\n\n", .{ objectType, pMessage });
    return 0;
}

pub export fn Viewport_SetupVulkan(ctx: *Context, extensions: [*][*]const u8, extensions_count: u32) VkInstance {
    return _SetupVulkan(ctx, extensions[0..extensions_count]) catch unreachable;
}
fn _SetupVulkan(ctx: *Context, extensions: [][*]const u8) !VkInstance {
    var err: VkResult = undefined;

    // Create Vulkan instance
    {
        if (DVULKAN_DEBUG_REPORT) {
            // Enabling multiple validation layers grouped as LunarG standard validation
            const layers = [_][*]const u8{"VK_LAYER_KHRONOS_validation"};

            // Enable debug report extension (we need additional storage, so we duplicate the user array to add our new extension to it)
            var storage: [100][*]const u8 = undefined;
            var extensions_ext = storage[0 .. extensions.len + 1];
            std.mem.copy([*]const u8, extensions_ext[0..extensions.len], extensions[0..extensions.len]);
            extensions_ext[extensions.len] = "VK_EXT_debug_report";

            const create_info = VkInstanceCreateInfo{
                .sType = .VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .enabledExtensionCount = @intCast(u32, extensions_ext.len),
                .ppEnabledExtensionNames = extensions_ext.ptr,
                .enabledLayerCount = @intCast(u32, layers.len),
                .ppEnabledLayerNames = &layers,
                .pApplicationInfo = null,
            };

            // Create Vulkan instance
            err = vkCreateInstance(&create_info, ctx.vk_allocator, &ctx.instance);
            try check_vk_result(err);

            // Get the function pointer (required for any extensions)
            const _vkCreateDebugReportCallbackEXT = @ptrCast(PFN_vkCreateDebugReportCallbackEXT, vkGetInstanceProcAddr(ctx.instance, "vkCreateDebugReportCallbackEXT"));

            // Setup the debug report callback
            const debug_report_ci = VkDebugReportCallbackCreateInfoEXT{
                .sType = .VK_STRUCTURE_TYPE_DEBUG_REPORT_CALLBACK_CREATE_INFO_EXT,
                .pNext = null,
                .flags = VK_DEBUG_REPORT_ERROR_BIT_EXT | VK_DEBUG_REPORT_WARNING_BIT_EXT | VK_DEBUG_REPORT_PERFORMANCE_WARNING_BIT_EXT,
                .pfnCallback = debug_report,
                .pUserData = null,
            };
            err = _vkCreateDebugReportCallbackEXT.?(ctx.instance, &debug_report_ci, ctx.vk_allocator, &ctx.debugReport);
            try check_vk_result(err);

            warn("Vulkan: debug layers enabled\n", .{});
        } else {
            const create_info = VkInstanceCreateInfo{
                .sType = .VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .enabledExtensionCount = extensions_count,
                .ppEnabledExtensionNames = extensions,
                .enabledLayerCount = 0,
                .ppEnabledLayerNames = null,
                .pApplicationInfo = null,
            };
            // Create Vulkan instance without any debug feature
            err = vkCreateInstance(&create_info, ctx.vk_allocator, &ctx.instance);
            try check_vk_result(err);
        }
    }

    // Select GPU
    {
        var gpu_count: u32 = undefined;
        err = vkEnumeratePhysicalDevices(ctx.instance, &gpu_count, null);
        try check_vk_result(err);
        assert(gpu_count > 0);
        var gpus: [100]VkPhysicalDevice = undefined;
        err = vkEnumeratePhysicalDevices(ctx.instance, &gpu_count, &gpus);
        try check_vk_result(err);

        // If a number >1 of GPUs got reported, you should find the best fit GPU for your purpose
        // e.g. VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU if available, or with the greatest memory available, etc.
        // for sake of simplicity we'll just take the first one, assuming it has a graphics queue family.
        ctx.physicalDevice = gpus[0];
    }

    // Select graphics queue family
    {
        var count: u32 = undefined;
        vkGetPhysicalDeviceQueueFamilyProperties(ctx.physicalDevice, &count, null);
        var queues: [100]VkQueueFamilyProperties = undefined;
        vkGetPhysicalDeviceQueueFamilyProperties(ctx.physicalDevice, &count, &queues);
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            if (queues[i].queueFlags & @intCast(u32, VK_QUEUE_GRAPHICS_BIT) != 0) {
                ctx.queueFamily = i;
                break;
            }
        }
        assert(ctx.queueFamily != 0xFFFFFFFF);
    }

    // Create Logical device (with 1 queue)
    {
        const device_extensions = [_][*]const u8{"VK_KHR_swapchain"};
        const queue_priority = [_]f32{1.0};
        const queue_info = [_]VkDeviceQueueCreateInfo{
            VkDeviceQueueCreateInfo{
                .sType = .VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .queueFamilyIndex = ctx.queueFamily,
                .queueCount = 1,
                .pQueuePriorities = &queue_priority,
            },
        };
        const create_info = VkDeviceCreateInfo{
            .sType = .VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueCreateInfoCount = queue_info.len,
            .pQueueCreateInfos = &queue_info,
            .enabledExtensionCount = device_extensions.len,
            .ppEnabledExtensionNames = &device_extensions,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .pEnabledFeatures = null,
        };
        err = vkCreateDevice(ctx.physicalDevice, &create_info, ctx.vk_allocator, &ctx.device);
        try check_vk_result(err);
        vkGetDeviceQueue(ctx.device, ctx.queueFamily, 0, &ctx.queue);
    }

    // Create Descriptor Pool
    {
        const pool_sizes = [_]VkDescriptorPoolSize{
            VkDescriptorPoolSize{ .type = .VK_DESCRIPTOR_TYPE_SAMPLER, .descriptorCount = 1000 },
            VkDescriptorPoolSize{ .type = .VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1000 },
            VkDescriptorPoolSize{ .type = .VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .descriptorCount = 1000 },
            VkDescriptorPoolSize{ .type = .VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1000 },
            VkDescriptorPoolSize{ .type = .VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, .descriptorCount = 1000 },
            VkDescriptorPoolSize{ .type = .VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER, .descriptorCount = 1000 },
            VkDescriptorPoolSize{ .type = .VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 1000 },
            VkDescriptorPoolSize{ .type = .VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1000 },
            VkDescriptorPoolSize{ .type = .VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC, .descriptorCount = 1000 },
            VkDescriptorPoolSize{ .type = .VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC, .descriptorCount = 1000 },
            VkDescriptorPoolSize{ .type = .VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT, .descriptorCount = 1000 },
        };
        const pool_info = VkDescriptorPoolCreateInfo{
            .sType = .VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .pNext = null,
            .flags = VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT,
            .maxSets = 1000 * pool_sizes.len,
            .poolSizeCount = pool_sizes.len,
            .pPoolSizes = &pool_sizes,
        };
        err = vkCreateDescriptorPool(ctx.device, &pool_info, ctx.vk_allocator, &ctx.descriptorPool);
        try check_vk_result(err);
    }

    return ctx.instance;
}

pub export fn Viewport_CleanupVulkan(ctx: *Context) void {
    vkDestroyDescriptorPool(ctx.device, ctx.descriptorPool, ctx.vk_allocator);

    if (DVULKAN_DEBUG_REPORT) {
        // Remove the debug report callback
        const _vkDestroyDebugReportCallbackEXT = @ptrCast(PFN_vkDestroyDebugReportCallbackEXT, vkGetInstanceProcAddr(ctx.instance, "vkDestroyDebugReportCallbackEXT"));
        _vkDestroyDebugReportCallbackEXT.?(ctx.instance, ctx.debugReport, ctx.vk_allocator);
    }

    vkDestroyDevice(ctx.device, ctx.vk_allocator);
    vkDestroyInstance(ctx.instance, ctx.vk_allocator);
}

pub export fn Viewport_SetupWindow(ctx: *Context, surface: VkSurfaceKHR, width: u32, height: u32, ms: VkSampleCountFlagBits, min_image_count: u32, clear_enable: bool) void {
    _SetupWindow(ctx, surface, width, height, ms, min_image_count, clear_enable) catch unreachable;
}
fn _SetupWindow(ctx: *Context, surface: VkSurfaceKHR, width: u32, height: u32, ms: VkSampleCountFlagBits, min_image_count: u32, clear_enable: bool) !void {
    var err: VkResult = undefined;

    ctx.MSAASamples = ms;

    const wd = &ctx.mainWindowData;
    wd.surface = surface;
    wd.clearEnable = clear_enable;

    // Check for WSI support
    var res: u32 = undefined;
    err = vkGetPhysicalDeviceSurfaceSupportKHR(ctx.physicalDevice, ctx.queueFamily, wd.surface, &res);
    try check_vk_result(err);
    if (res == 0) {
        warn("Error no WSI support on physical device 0\n", .{});
        unreachable;
    }

    // Select surface Format
    const requestSurfaceImageFormat = [_]VkFormat{ .VK_FORMAT_B8G8R8A8_UNORM, .VK_FORMAT_R8G8B8A8_UNORM, .VK_FORMAT_B8G8R8_UNORM, .VK_FORMAT_R8G8B8_UNORM };
    wd.surfaceFormat = selectSurfaceFormat(ctx.physicalDevice, wd.surface, &requestSurfaceImageFormat, .VK_COLOR_SPACE_SRGB_NONLINEAR_KHR);

    // Select Present Mode
    //const present_modes = [_]VkPresentModeKHR{ .VK_PRESENT_MODE_MAILBOX_KHR, .VK_PRESENT_MODE_IMMEDIATE_KHR, .VK_PRESENT_MODE_FIFO_KHR };
    const present_modes = [_]VkPresentModeKHR{.VK_PRESENT_MODE_FIFO_KHR}; //v-sync
    wd.presentMode = selectPresentMode(ctx.physicalDevice, wd.surface, &present_modes);

    // Create SwapChain, renderPass, framebuffer, etc.
    try createWindow(ctx.instance, ctx.physicalDevice, ctx.device, wd, ctx.queueFamily, ctx.descriptorPool, ctx.allocator, ctx.vk_allocator, width, height, min_image_count);
}

pub export fn Viewport_CleanupWindow(ctx: *Context) void {
    destroyWindow(ctx.instance, ctx.device, &ctx.mainWindowData, ctx.descriptorPool, ctx.allocator, ctx.vk_allocator);
}
