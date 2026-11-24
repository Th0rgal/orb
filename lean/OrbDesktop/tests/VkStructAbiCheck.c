/* VkStructAbiCheck.c — CI-only ABI verification of every Vulkan 1.3 LP64 struct
 * serialized by `LeanUI/VulkanStructs.lean` against `<vulkan/vulkan.h>`.
 *
 * Not linked into `orb-desktop-native`; compiled and executed by test scripts when
 * `<vulkan/vulkan.h>` (libvulkan-dev or Nix vulkan-headers) is present.
 */
#define VK_USE_PLATFORM_WAYLAND_KHR 1
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <vulkan/vulkan.h>

static int failures = 0;

#define CHECK_SIZE(T, expected)                                                          \
  do {                                                                                   \
    if (sizeof(T) != (size_t)(expected)) {                                               \
      fprintf(stderr, "FAIL sizeof(%s) = %zu, expected %zu\n", #T, sizeof(T),            \
              (size_t)(expected));                                                       \
      failures++;                                                                        \
    }                                                                                    \
  } while (0)

#define CHECK_OFF(T, F, expected)                                                        \
  do {                                                                                   \
    if (offsetof(T, F) != (size_t)(expected)) {                                          \
      fprintf(stderr, "FAIL offsetof(%s, %s) = %zu, expected %zu\n", #T, #F,             \
              offsetof(T, F), (size_t)(expected));                                       \
      failures++;                                                                        \
    }                                                                                    \
  } while (0)

int main(void) {
  CHECK_SIZE(VkApplicationInfo, 48);
  CHECK_OFF(VkApplicationInfo, pApplicationName, 16);
  CHECK_OFF(VkApplicationInfo, apiVersion, 44);

  CHECK_SIZE(VkInstanceCreateInfo, 64);
  CHECK_OFF(VkInstanceCreateInfo, pApplicationInfo, 24);
  CHECK_OFF(VkInstanceCreateInfo, enabledLayerCount, 32);
  CHECK_OFF(VkInstanceCreateInfo, ppEnabledLayerNames, 40);
  CHECK_OFF(VkInstanceCreateInfo, enabledExtensionCount, 48);
  CHECK_OFF(VkInstanceCreateInfo, ppEnabledExtensionNames, 56);

  CHECK_SIZE(VkWaylandSurfaceCreateInfoKHR, 40);
  CHECK_OFF(VkWaylandSurfaceCreateInfoKHR, display, 24);
  CHECK_OFF(VkWaylandSurfaceCreateInfoKHR, surface, 32);

  CHECK_SIZE(VkDeviceQueueCreateInfo, 40);
  CHECK_OFF(VkDeviceQueueCreateInfo, queueFamilyIndex, 20);
  CHECK_OFF(VkDeviceQueueCreateInfo, queueCount, 24);
  CHECK_OFF(VkDeviceQueueCreateInfo, pQueuePriorities, 32);

  CHECK_SIZE(VkPhysicalDeviceVulkan13Features, 80);
  CHECK_OFF(VkPhysicalDeviceVulkan13Features, synchronization2, 52);
  CHECK_OFF(VkPhysicalDeviceVulkan13Features, dynamicRendering, 64);

  CHECK_SIZE(VkDeviceCreateInfo, 72);
  CHECK_OFF(VkDeviceCreateInfo, queueCreateInfoCount, 20);
  CHECK_OFF(VkDeviceCreateInfo, pQueueCreateInfos, 24);
  CHECK_OFF(VkDeviceCreateInfo, enabledExtensionCount, 48);
  CHECK_OFF(VkDeviceCreateInfo, ppEnabledExtensionNames, 56);

  CHECK_SIZE(VkSurfaceCapabilitiesKHR, 52);
  CHECK_OFF(VkSurfaceCapabilitiesKHR, minImageCount, 0);
  CHECK_OFF(VkSurfaceCapabilitiesKHR, maxImageCount, 4);
  CHECK_OFF(VkSurfaceCapabilitiesKHR, currentExtent, 8);
  CHECK_OFF(VkSurfaceCapabilitiesKHR, minImageExtent, 16);
  CHECK_OFF(VkSurfaceCapabilitiesKHR, maxImageExtent, 24);
  CHECK_OFF(VkSurfaceCapabilitiesKHR, currentTransform, 40);
  CHECK_OFF(VkSurfaceCapabilitiesKHR, supportedCompositeAlpha, 44);
  CHECK_OFF(VkSurfaceCapabilitiesKHR, supportedUsageFlags, 48);

  CHECK_SIZE(VkSwapchainCreateInfoKHR, 104);
  CHECK_OFF(VkSwapchainCreateInfoKHR, surface, 24);
  CHECK_OFF(VkSwapchainCreateInfoKHR, minImageCount, 32);
  CHECK_OFF(VkSwapchainCreateInfoKHR, imageFormat, 36);
  CHECK_OFF(VkSwapchainCreateInfoKHR, imageColorSpace, 40);
  CHECK_OFF(VkSwapchainCreateInfoKHR, imageExtent, 44);
  CHECK_OFF(VkSwapchainCreateInfoKHR, imageArrayLayers, 52);
  CHECK_OFF(VkSwapchainCreateInfoKHR, imageUsage, 56);
  CHECK_OFF(VkSwapchainCreateInfoKHR, preTransform, 80);
  CHECK_OFF(VkSwapchainCreateInfoKHR, compositeAlpha, 84);
  CHECK_OFF(VkSwapchainCreateInfoKHR, presentMode, 88);
  CHECK_OFF(VkSwapchainCreateInfoKHR, clipped, 92);
  CHECK_OFF(VkSwapchainCreateInfoKHR, oldSwapchain, 96);

  CHECK_SIZE(VkRenderingAttachmentInfo, 72);
  CHECK_OFF(VkRenderingAttachmentInfo, imageView, 16);
  CHECK_OFF(VkRenderingAttachmentInfo, imageLayout, 24);
  CHECK_OFF(VkRenderingAttachmentInfo, loadOp, 44);
  CHECK_OFF(VkRenderingAttachmentInfo, storeOp, 48);
  CHECK_OFF(VkRenderingAttachmentInfo, clearValue, 52);

  CHECK_SIZE(VkRenderingInfo, 72);
  CHECK_OFF(VkRenderingInfo, renderArea, 20);
  CHECK_OFF(VkRenderingInfo, layerCount, 36);
  CHECK_OFF(VkRenderingInfo, colorAttachmentCount, 44);
  CHECK_OFF(VkRenderingInfo, pColorAttachments, 48);

  CHECK_SIZE(VkSemaphoreSubmitInfo, 48);
  CHECK_OFF(VkSemaphoreSubmitInfo, semaphore, 16);
  CHECK_OFF(VkSemaphoreSubmitInfo, stageMask, 32);

  CHECK_SIZE(VkCommandBufferSubmitInfo, 32);
  CHECK_OFF(VkCommandBufferSubmitInfo, commandBuffer, 16);

  CHECK_SIZE(VkSubmitInfo2, 64);
  CHECK_OFF(VkSubmitInfo2, waitSemaphoreInfoCount, 20);
  CHECK_OFF(VkSubmitInfo2, pWaitSemaphoreInfos, 24);
  CHECK_OFF(VkSubmitInfo2, commandBufferInfoCount, 32);
  CHECK_OFF(VkSubmitInfo2, pCommandBufferInfos, 40);
  CHECK_OFF(VkSubmitInfo2, signalSemaphoreInfoCount, 48);
  CHECK_OFF(VkSubmitInfo2, pSignalSemaphoreInfos, 56);

  CHECK_SIZE(VkPresentInfoKHR, 64);
  CHECK_OFF(VkPresentInfoKHR, waitSemaphoreCount, 16);
  CHECK_OFF(VkPresentInfoKHR, pWaitSemaphores, 24);
  CHECK_OFF(VkPresentInfoKHR, swapchainCount, 32);
  CHECK_OFF(VkPresentInfoKHR, pSwapchains, 40);
  CHECK_OFF(VkPresentInfoKHR, pImageIndices, 48);

  CHECK_SIZE(VkRectLayerKHR, 20);
  CHECK_SIZE(VkPresentRegionKHR, 16);
  CHECK_SIZE(VkPresentRegionsKHR, 32);
  CHECK_OFF(VkPresentRegionsKHR, swapchainCount, 16);
  CHECK_OFF(VkPresentRegionsKHR, pRegions, 24);

  CHECK_SIZE(VkImageMemoryBarrier2, 96);
  CHECK_OFF(VkImageMemoryBarrier2, srcStageMask, 16);
  CHECK_OFF(VkImageMemoryBarrier2, srcAccessMask, 24);
  CHECK_OFF(VkImageMemoryBarrier2, dstStageMask, 32);
  CHECK_OFF(VkImageMemoryBarrier2, dstAccessMask, 40);
  CHECK_OFF(VkImageMemoryBarrier2, oldLayout, 48);
  CHECK_OFF(VkImageMemoryBarrier2, newLayout, 52);
  CHECK_OFF(VkImageMemoryBarrier2, srcQueueFamilyIndex, 56);
  CHECK_OFF(VkImageMemoryBarrier2, dstQueueFamilyIndex, 60);
  CHECK_OFF(VkImageMemoryBarrier2, image, 64);
  CHECK_OFF(VkImageMemoryBarrier2, subresourceRange, 72);

  CHECK_SIZE(VkDependencyInfo, 64);
  CHECK_OFF(VkDependencyInfo, imageMemoryBarrierCount, 48);
  CHECK_OFF(VkDependencyInfo, pImageMemoryBarriers, 56);

  CHECK_SIZE(VkBufferImageCopy2, 72);
  CHECK_OFF(VkBufferImageCopy2, bufferOffset, 16);
  CHECK_OFF(VkBufferImageCopy2, imageSubresource, 32);
  CHECK_OFF(VkBufferImageCopy2, imageOffset, 48);
  CHECK_OFF(VkBufferImageCopy2, imageExtent, 60);

  CHECK_SIZE(VkCopyBufferToImageInfo2, 48);
  CHECK_OFF(VkCopyBufferToImageInfo2, srcBuffer, 16);
  CHECK_OFF(VkCopyBufferToImageInfo2, dstImage, 24);
  CHECK_OFF(VkCopyBufferToImageInfo2, dstImageLayout, 32);
  CHECK_OFF(VkCopyBufferToImageInfo2, regionCount, 36);
  CHECK_OFF(VkCopyBufferToImageInfo2, pRegions, 40);

  CHECK_SIZE(VkCopyImageToBufferInfo2, 56);
  CHECK_OFF(VkCopyImageToBufferInfo2, srcImage, 16);
  CHECK_OFF(VkCopyImageToBufferInfo2, srcImageLayout, 24);
  CHECK_OFF(VkCopyImageToBufferInfo2, dstBuffer, 32);
  CHECK_OFF(VkCopyImageToBufferInfo2, regionCount, 40);
  CHECK_OFF(VkCopyImageToBufferInfo2, pRegions, 48);

  CHECK_SIZE(VkImageBlit2, 96);
  CHECK_OFF(VkImageBlit2, srcSubresource, 16);
  CHECK_OFF(VkImageBlit2, srcOffsets, 32);
  CHECK_OFF(VkImageBlit2, dstSubresource, 56);
  CHECK_OFF(VkImageBlit2, dstOffsets, 72);

  CHECK_SIZE(VkBlitImageInfo2, 64);
  CHECK_OFF(VkBlitImageInfo2, srcImage, 16);
  CHECK_OFF(VkBlitImageInfo2, srcImageLayout, 24);
  CHECK_OFF(VkBlitImageInfo2, dstImage, 32);
  CHECK_OFF(VkBlitImageInfo2, dstImageLayout, 40);
  CHECK_OFF(VkBlitImageInfo2, regionCount, 44);
  CHECK_OFF(VkBlitImageInfo2, pRegions, 48);
  CHECK_OFF(VkBlitImageInfo2, filter, 56);

  CHECK_SIZE(VkImageCopy2, 88);
  CHECK_OFF(VkImageCopy2, srcSubresource, 16);
  CHECK_OFF(VkImageCopy2, srcOffset, 32);
  CHECK_OFF(VkImageCopy2, dstSubresource, 44);
  CHECK_OFF(VkImageCopy2, dstOffset, 60);
  CHECK_OFF(VkImageCopy2, extent, 72);

  CHECK_SIZE(VkCopyImageInfo2, 56);
  CHECK_OFF(VkCopyImageInfo2, srcImage, 16);
  CHECK_OFF(VkCopyImageInfo2, srcImageLayout, 24);
  CHECK_OFF(VkCopyImageInfo2, dstImage, 32);
  CHECK_OFF(VkCopyImageInfo2, dstImageLayout, 40);
  CHECK_OFF(VkCopyImageInfo2, regionCount, 44);
  CHECK_OFF(VkCopyImageInfo2, pRegions, 48);

  CHECK_SIZE(VkBufferCreateInfo, 56);
  CHECK_OFF(VkBufferCreateInfo, size, 24);
  CHECK_OFF(VkBufferCreateInfo, usage, 32);

  CHECK_SIZE(VkImageCreateInfo, 88);
  CHECK_OFF(VkImageCreateInfo, imageType, 20);
  CHECK_OFF(VkImageCreateInfo, format, 24);
  CHECK_OFF(VkImageCreateInfo, extent, 28);
  CHECK_OFF(VkImageCreateInfo, mipLevels, 40);
  CHECK_OFF(VkImageCreateInfo, arrayLayers, 44);
  CHECK_OFF(VkImageCreateInfo, samples, 48);
  CHECK_OFF(VkImageCreateInfo, tiling, 52);
  CHECK_OFF(VkImageCreateInfo, usage, 56);
  CHECK_OFF(VkImageCreateInfo, initialLayout, 80);

  CHECK_SIZE(VkImageViewCreateInfo, 80);
  CHECK_OFF(VkImageViewCreateInfo, image, 24);
  CHECK_OFF(VkImageViewCreateInfo, viewType, 32);
  CHECK_OFF(VkImageViewCreateInfo, format, 36);
  CHECK_OFF(VkImageViewCreateInfo, subresourceRange, 56);

  CHECK_SIZE(VkGraphicsPipelineCreateInfo, 144);
  CHECK_OFF(VkGraphicsPipelineCreateInfo, stageCount, 20);
  CHECK_OFF(VkGraphicsPipelineCreateInfo, pStages, 24);
  CHECK_OFF(VkGraphicsPipelineCreateInfo, pVertexInputState, 32);
  CHECK_OFF(VkGraphicsPipelineCreateInfo, pInputAssemblyState, 40);
  CHECK_OFF(VkGraphicsPipelineCreateInfo, pViewportState, 56);
  CHECK_OFF(VkGraphicsPipelineCreateInfo, pRasterizationState, 64);
  CHECK_OFF(VkGraphicsPipelineCreateInfo, pMultisampleState, 72);
  CHECK_OFF(VkGraphicsPipelineCreateInfo, pColorBlendState, 88);
  CHECK_OFF(VkGraphicsPipelineCreateInfo, pDynamicState, 96);
  CHECK_OFF(VkGraphicsPipelineCreateInfo, layout, 104);

  CHECK_SIZE(VkComputePipelineCreateInfo, 96);
  CHECK_OFF(VkComputePipelineCreateInfo, stage, 24);
  CHECK_OFF(VkComputePipelineCreateInfo, layout, 72);

  CHECK_SIZE(VkPipelineRenderingCreateInfo, 40);
  CHECK_OFF(VkPipelineRenderingCreateInfo, colorAttachmentCount, 20);
  CHECK_OFF(VkPipelineRenderingCreateInfo, pColorAttachmentFormats, 24);

  if (failures) {
    fprintf(stderr, "VkStructAbiCheck: %d failure(s)\n", failures);
    return 1;
  }
  printf("VkStructAbiCheck: all Vulkan 1.3 LP64 struct layouts verified\n");
  return 0;
}
