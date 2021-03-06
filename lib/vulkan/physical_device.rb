module Vulkan
  class PhysicalDevice
    include Vulkan::Checks
    include Vulkan::Conversions

    def initialize(instance, handle)
      @handle = handle
      @instance = instance
      @vk = Vulkan[instance, nil]
    end

    def inspect
      # force lazy instance variables to be initialized
      to_hash
      super
    end

    def to_ptr
      @handle
    end

    def to_hash
      {
        extensions: extensions,
        properties: properties,
        features: features_hash,
        queue_families: queue_families
      }
    end

    def supported_features
      struct_to_hash(features).reject! { |k, v| v != VK_TRUE }.keys
    end

    def unsupported_features
      struct_to_hash(features).reject! { |k, v| v == VK_TRUE }.keys
    end

    def max_samples
      [max_color_samples, max_depth_samples].min
    end

    def sample_counts_to_max(counts)
      return VK_SAMPLE_COUNT_64_BIT if counts & VK_SAMPLE_COUNT_64_BIT != 0
      return VK_SAMPLE_COUNT_32_BIT if counts & VK_SAMPLE_COUNT_32_BIT != 0
      return VK_SAMPLE_COUNT_16_BIT if counts & VK_SAMPLE_COUNT_16_BIT != 0
      return VK_SAMPLE_COUNT_8_BIT  if counts & VK_SAMPLE_COUNT_8_BIT  != 0
      return VK_SAMPLE_COUNT_4_BIT  if counts & VK_SAMPLE_COUNT_4_BIT  != 0
      return VK_SAMPLE_COUNT_2_BIT  if counts & VK_SAMPLE_COUNT_2_BIT  != 0
      return VK_SAMPLE_COUNT_1_BIT
    end

    def max_color_samples
      sample_counts_to_max properties[:limits][:framebuffer_color_sample_counts]
    end

    def max_depth_samples
      sample_counts_to_max properties[:limits][:framebuffer_depth_sample_counts]
    end

    def detect_supported_format(*candidates, usage:, tiling: :optimal)
      usage  = syms_to_format_feature_flags(usage)
      tiling = sym_to_image_tiling(tiling)
      candidates.flatten.each do |candidate|
        props = VkFormatProperties.malloc
        @vk.vkGetPhysicalDeviceFormatProperties(to_ptr, sym_to_format(candidate), props)
        if tiling == VK_IMAGE_TILING_LINEAR && (props.linearTilingFeatures & usage) == usage
          return candidate
        elsif tiling == VK_IMAGE_TILING_OPTIMAL && (props.optimalTilingFeatures & usage) == usage
          return candidate
        end
      end
      nil
    end

    # Returns the swapchain surface info if the `"VK_KHR_swapchain"` extension
    # is supported, `nil` otherwise.
    def swapchain_surface_info(surface)
      if extension_names.include?('VK_KHR_swapchain')
        SwapchainSurfaceInfo.new(@instance, self, surface)
      else
        nil
      end
    end

    def extension_names
      extensions.map { |ext| ext[:extension_name] }
    end

    def create_logical_device(**args)
      Vulkan::LogicalDevice.new(@instance, self, **args)
    end

    alias create create_logical_device

    def memory_properties
      @memory_properties ||= begin
        memory_properties = VkPhysicalDeviceMemoryProperties.malloc
        @vk.vkGetPhysicalDeviceMemoryProperties(to_ptr, memory_properties)
        struct_to_hash(memory_properties)
      end
    end

    def queue_families
      @queue_families ||= begin
        count_ptr = Vulkan.create_value("uint32_t", 0)
        @vk.vkGetPhysicalDeviceQueueFamilyProperties(@handle, count_ptr, nil)

        container_struct = Vulkan.struct("queues[#{count_ptr.value}]" => VkQueueFamilyProperties)
        container = container_struct.malloc
        @vk.vkGetPhysicalDeviceQueueFamilyProperties(@handle, count_ptr, container)
        container.queues.each_with_index.map do |prop, index|
          info = struct_to_hash(prop, Vulkan::QueueFamily.new(@vk.instance, self, index))
          info[:supports] = flags_to_symbols(info[:queue_flags], /^VK_QUEUE_(.*?)_BIT$/)
          info[:index] = index
          info[:queues] = [1.0]
          info
        end
      end
    end

    def supports_feature?(feature_name)
      features_hash[feature_name] == VK_TRUE
    end

    def features_hash
      struct_to_hash features
    end

    def features
      @features ||= begin
        features = VkPhysicalDeviceFeatures.malloc
        @vk.vkGetPhysicalDeviceFeatures(@handle, features)
        features
      end
    end

    def properties
      @properties ||= begin
        properties = VkPhysicalDeviceProperties.malloc
        @vk.vkGetPhysicalDeviceProperties(@handle, properties)
        properties = struct_to_hash(properties)
        properties[:device_type] = const_to_symbol(properties[:device_type], /^VK_PHYSICAL_DEVICE_TYPE_(.*?)$/)
        properties
      end
    end

    def extensions
      @extensions ||= begin
        # get properties count
        count_ptr = Vulkan.create_value("uint32_t", 0)
        check_result @vk.vkEnumerateDeviceExtensionProperties(@handle, nil, count_ptr, nil)
        count = count_ptr.value
        # allocate n devices
        container_struct = Vulkan.struct("handles[#{count}]" => VkExtensionProperties)
        container = container_struct.malloc
        check_result @vk.vkEnumerateDeviceExtensionProperties(@handle, nil, count_ptr, container)
        container.handles.map { |handle| struct_to_hash(handle) }
      end
    end
  end
end
