module Vulkan
  class Instance
    extend  Vulkan::Checks
    extend  Vulkan::Conversions
    include Vulkan::Checks
    include Vulkan::Conversions
    include Vulkan::Finalizer

    class << self
      def extensions
        @extensions ||= begin
          property_count_ptr = Vulkan.create_value("uint32_t", 0)
          check_result Vulkan[nil, nil].vkEnumerateInstanceExtensionProperties(nil, property_count_ptr, nil)
          property_count = property_count_ptr.value
          container = Vulkan.struct("properties[#{property_count}]" => VkExtensionProperties).malloc
          check_result Vulkan[nil, nil].vkEnumerateInstanceExtensionProperties(nil, property_count_ptr, container)
          container.properties.map { |prop| struct_to_hash(prop) }
        end
      end

      def layers
        @layers ||= begin
          property_count_ptr = Vulkan.create_value("uint32_t", 0)
          check_result Vulkan[nil, nil].vkEnumerateInstanceLayerProperties(property_count_ptr, nil)
          property_count = property_count_ptr.value
          container_struct = Vulkan.struct("properties[#{property_count}]" => VkLayerProperties)
          container = container_struct.malloc
          check_result Vulkan[nil, nil].vkEnumerateInstanceLayerProperties(property_count_ptr, container)
          container.properties.map { |prop| struct_to_hash(prop) }
        end
      end

      def extension_names
        extensions.map { |ext| ext[:extension_name] }
      end

      def layer_names
        layers.map { |layer| layer[:layer_name] }
      end
    end

    def initialize(application_name: $0,         application_version: '1.0.0',
                   engine_name: 'vulkan-ruby',   engine_version: Vulkan::VERSION,
                   api_version: Vulkan::VERSION, extensions: ,
                   layers: [])
      if ENV['DEBUG']
        extension_names = self.class.extension_names
        extensions << 'VK_EXT_debug_utils'  if extension_names.include?('VK_EXT_debug_utils')
        extensions << 'VK_EXT_debug_report' if extension_names.include?('VK_EXT_debug_report')
      end

      extensions_p = Vulkan.struct("names[#{extensions.size}]" => ['char *name']).malloc
      extensions.each_with_index do |ext, i|
        extname = ext.kind_of?(String) ? ext : ext[:extension_name]
        extensions_p.names[i].name = Fiddle::Pointer[extname.b + "\x00"]
      end

      layers << 'VK_LAYER_LUNARG_standard_validation' if ENV['DEBUG'] && self.class.layer_names.include?('VK_LAYER_LUNARG_standard_validation')
      layers_p = Vulkan.struct("names[#{layers.size}]" => ['char *name']).malloc
      layers.each_with_index do |layer, i|
        layer_name = layer.kind_of?(String) ? layer : layer[:layer_name]
        layers_p.names[i].name = Fiddle::Pointer[layer_name.b + "\x00"]
      end

      application_info = VkApplicationInfo.malloc
      application_info.sType               = VK_STRUCTURE_TYPE_APPLICATION_INFO
      application_info.pNext               = nil
      application_info.pApplicationName    = application_name
      application_info.applicationVersion  = vk_make_version(application_version)
      application_info.pEngineName         = 'vulkan-ruby'
      application_info.engineVersion       = vk_make_version(engine_version)
      application_info.apiVersion          = vk_make_version(api_version)

      instance_info = VkInstanceCreateInfo.malloc
      instance_info.sType                   = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
      instance_info.pNext                   = nil
      instance_info.flags                   = 0
      instance_info.pApplicationInfo        = application_info
      instance_info.enabledLayerCount       = layers.size
      instance_info.ppEnabledLayerNames     = layers_p
      instance_info.enabledExtensionCount   = extensions.size
      instance_info.ppEnabledExtensionNames = extensions_p

      instance_wrapper = Vulkan.create_value("void *", nil)
      check_result Vulkan[nil, nil].vkCreateInstance(instance_info, nil, instance_wrapper)
      @handle = instance_wrapper.value
      @vk = Vulkan[self, nil]
      finalize_with @vk, :vkDestroyInstance, @handle, nil

      hook_debug_utils_callback if extensions.include?('VK_EXT_debug_utils')
      hook_debug_report_callback if extensions.include?('VK_EXT_debug_report')
    end

    def hook_debug_utils_callback
      name, return_type, param_types = Vulkan.parse_signature('VkBool32 debug_callback(int   messageSeverity,' +
                                                                                      'int   messageType,' +
                                                                                      'void *pCallbackData,' +
                                                                                      'void *pUserData)')
      @debug_util_callback = Fiddle::Closure::BlockCaller.new(return_type, param_types) do |msg_severity, msg_type, cb_data_addr, user_arg_addr|
        data     = VkDebugUtilsMessengerCallbackDataEXT.new(cb_data_addr)
        type     = const_to_symbol(msg_type,     /^VK_DEBUG_UTILS_MESSAGE_TYPE_(.*?)_BIT_EXT$/)
        severity = const_to_symbol(msg_severity, /^VK_DEBUG_UTILS_MESSAGE_SEVERITY_(.*?)_BIT_EXT$/)
        puts [type, severity, data.pMessage].join("\t")
        VK_FALSE # don't bail
      end

      create_info = VkDebugUtilsMessengerCreateInfoEXT.malloc
      create_info.sType           = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT
      create_info.messageSeverity = VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT |
                                    VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
                                    VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT
      create_info.messageType     = VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT    |
                                    VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
                                    VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT
      create_info.pUserData       = nil
      create_info.pfnUserCallback = @debug_util_callback

      callback_p = Vulkan.create_value('void *', nil)
      check_result @vk.vkCreateDebugUtilsMessengerEXT(to_ptr, create_info, nil, callback_p)
      finalize_with @vk, :vkDestroyDebugUtilsMessengerEXT, to_ptr, callback_p.value, nil
    end

    def hook_debug_report_callback
      name, return_type, param_types = Vulkan.parse_signature('VkBool32 debug_callback(VkDebugReportFlagsEXT      flags,' +
                                                                                      'VkDebugReportObjectTypeEXT objectType,' +
                                                                                      'uint64_t                   object,' +
                                                                                      'size_t                     location,' +
                                                                                      'int32_t                    messageCode,' +
                                                                                      'const char *               pLayerPrefix,'+
                                                                                      'const char *               pMessage,' +
                                                                                      'void       *               pUserData)')

      @debug_report_callback = Fiddle::Closure::BlockCaller.new(return_type, param_types) do |flags, objectType, object, location, messageCode, pLayerPrefix, pMessage, pUserData|
        puts [cstr_to_rbstr(layer_prefix), cstr_to_rbstr(message)].join(": ")
        VK_FALSE # don't abort the call
      end

      callback = VkDebugReportCallbackCreateInfoEXT.malloc
      callback.sType = VK_STRUCTURE_TYPE_DEBUG_REPORT_CALLBACK_CREATE_INFO_EXT,
      callback.flags = VK_DEBUG_REPORT_ERROR_BIT_EXT | VK_DEBUG_REPORT_WARNING_BIT_EXT
      callback.pfnCallback = @debug_report_callback
      callback_p = Vulkan.create_value('void *', nil)
      check_result @vk.vkCreateDebugReportCallbackEXT(to_ptr, callback, nil, callback_p)
      @debug_report_callback = callback_p.value
      finalize_with @vk, :vkDestroyDebugReportCallbackEXT, to_ptr, @debug_report_callback
    end

    def create_window_surface(window)
      WindowSurface.new(self, window)
    end

    # Returns an array of physical device handles. Use these to query the
    # capabilities of each physical device, and to create logical devices
    # based on the results.
    def physical_device_handles
      @physical_device_handles ||= begin
        # get device count
        device_count_ptr = Vulkan.create_value("uint32_t", 0)
        # check_result func.call(@handle, device_count_ptr, nil)
        check_result @vk.vkEnumeratePhysicalDevices(@handle, device_count_ptr, nil)
        device_count = device_count_ptr.value
        # allocate n devices
        container_struct = Vulkan.struct("handles[#{device_count}]" => ['VkPhysicalDevice handle'])
        container = container_struct.malloc
        # check_result func.call(@handle, device_count_ptr, container)
        check_result @vk.vkEnumeratePhysicalDevices(@handle, device_count_ptr, container)
        container.handles
      end
    end

    def physical_devices
      @physical_devices ||= physical_device_handles.map { |dev| PhysicalDevice.new(self, dev.handle) }
    end
  end
end
