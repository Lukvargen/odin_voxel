// pipestats <shader.spv> <layout.txt>: compile a compute shader on the first
// NVIDIA GPU and print the driver's statistics for it (registers per thread,
// spills, instructions...) via VK_KHR_pipeline_executable_properties.
// layout.txt: one "set binding TYPE" line per resource, TYPE one of
// SAMPLED_IMAGE STORAGE_IMAGE STORAGE_BUFFER UNIFORM_BUFFER.
package pipestats

import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import vk "vendor:vulkan"

check :: proc(r: vk.Result, what: string) {
    if r != .SUCCESS { fmt.eprintln(what, "failed:", r); os.exit(1) }
}

main :: proc() {
    if len(os.args) < 3 { fmt.eprintln("usage: pipestats <shader.spv> <layout.txt>"); os.exit(2) }
    spv, e1 := os.read_entire_file(os.args[1], context.allocator)
    lay, e2 := os.read_entire_file(os.args[2], context.allocator)
    if e1 != nil || e2 != nil { fmt.eprintln("can't read inputs:", e1, e2); os.exit(1) }

    lib, lok := dynlib.load_library("vulkan-1.dll")
    if !lok { fmt.eprintln("no vulkan-1.dll"); os.exit(1) }
    gipa, _ := dynlib.symbol_address(lib, "vkGetInstanceProcAddr")
    vk.load_proc_addresses_global(gipa)

    app := vk.ApplicationInfo{sType = .APPLICATION_INFO, apiVersion = vk.API_VERSION_1_2}
    ici := vk.InstanceCreateInfo{sType = .INSTANCE_CREATE_INFO, pApplicationInfo = &app}
    inst: vk.Instance
    check(vk.CreateInstance(&ici, nil, &inst), "CreateInstance")
    vk.load_proc_addresses_instance(inst)

    n: u32
    vk.EnumeratePhysicalDevices(inst, &n, nil)
    pds := make([]vk.PhysicalDevice, n)
    vk.EnumeratePhysicalDevices(inst, &n, raw_data(pds))
    pd: vk.PhysicalDevice
    for d in pds {
        props: vk.PhysicalDeviceProperties
        vk.GetPhysicalDeviceProperties(d, &props)
        if props.vendorID == 0x10DE && props.deviceType == .DISCRETE_GPU {
            pd = d
            name := props.deviceName
            fmt.println("device:", strings.truncate_to_byte(string(name[:]), 0))
            break
        }
    }
    if pd == nil { fmt.eprintln("no NVIDIA GPU"); os.exit(1) }

    qn: u32
    vk.GetPhysicalDeviceQueueFamilyProperties(pd, &qn, nil)
    qfs := make([]vk.QueueFamilyProperties, qn)
    vk.GetPhysicalDeviceQueueFamilyProperties(pd, &qn, raw_data(qfs))
    qf := u32(0)
    for q, i in qfs { if .COMPUTE in q.queueFlags { qf = u32(i); break } }

    prio := f32(1)
    qci := vk.DeviceQueueCreateInfo{sType = .DEVICE_QUEUE_CREATE_INFO, queueFamilyIndex = qf, queueCount = 1, pQueuePriorities = &prio}
    exec_feat := vk.PhysicalDevicePipelineExecutablePropertiesFeaturesKHR{
        sType = .PHYSICAL_DEVICE_PIPELINE_EXECUTABLE_PROPERTIES_FEATURES_KHR, pipelineExecutableInfo = true}
    feats := vk.PhysicalDeviceFeatures{shaderStorageImageReadWithoutFormat = true, shaderStorageImageWriteWithoutFormat = true, shaderInt64 = true}
    exts := []cstring{vk.KHR_PIPELINE_EXECUTABLE_PROPERTIES_EXTENSION_NAME}
    dci := vk.DeviceCreateInfo{
        sType = .DEVICE_CREATE_INFO, pNext = &exec_feat,
        queueCreateInfoCount = 1, pQueueCreateInfos = &qci,
        enabledExtensionCount = u32(len(exts)), ppEnabledExtensionNames = raw_data(exts),
        pEnabledFeatures = &feats,
    }
    dev: vk.Device
    check(vk.CreateDevice(pd, &dci, nil, &dev), "CreateDevice")
    vk.load_proc_addresses_device(dev)

    // Descriptor set layouts from layout.txt.
    sets: [4][dynamic]vk.DescriptorSetLayoutBinding
    max_set := -1
    for line in strings.split_lines(string(lay)) {
        f := strings.fields(line)
        if len(f) < 3 { continue }
        s, _ := strconv.parse_int(f[0])
        b, _ := strconv.parse_int(f[1])
        t: vk.DescriptorType
        switch f[2] {
        case "SAMPLED_IMAGE":  t = .SAMPLED_IMAGE
        case "STORAGE_IMAGE":  t = .STORAGE_IMAGE
        case "STORAGE_BUFFER": t = .STORAGE_BUFFER
        case "UNIFORM_BUFFER": t = .UNIFORM_BUFFER
        case: fmt.eprintln("bad type", f[2]); os.exit(1)
        }
        append(&sets[s], vk.DescriptorSetLayoutBinding{binding = u32(b), descriptorType = t, descriptorCount = 1, stageFlags = {.COMPUTE}})
        max_set = max(max_set, int(s))
    }
    dsls := make([]vk.DescriptorSetLayout, max_set + 1)
    for i in 0 ..= max_set {
        ci := vk.DescriptorSetLayoutCreateInfo{sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            bindingCount = u32(len(sets[i])), pBindings = raw_data(sets[i])}
        check(vk.CreateDescriptorSetLayout(dev, &ci, nil, &dsls[i]), "CreateDescriptorSetLayout")
    }
    plci := vk.PipelineLayoutCreateInfo{sType = .PIPELINE_LAYOUT_CREATE_INFO, setLayoutCount = u32(len(dsls)), pSetLayouts = raw_data(dsls)}
    pl: vk.PipelineLayout
    check(vk.CreatePipelineLayout(dev, &plci, nil, &pl), "CreatePipelineLayout")

    smci := vk.ShaderModuleCreateInfo{sType = .SHADER_MODULE_CREATE_INFO, codeSize = len(spv), pCode = cast(^u32)raw_data(spv)}
    sm: vk.ShaderModule
    check(vk.CreateShaderModule(dev, &smci, nil, &sm), "CreateShaderModule")

    cpci := vk.ComputePipelineCreateInfo{
        sType = .COMPUTE_PIPELINE_CREATE_INFO,
        flags = {.CAPTURE_STATISTICS_KHR},
        stage = {sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.COMPUTE}, module = sm, pName = "main"},
        layout = pl,
    }
    pipe: vk.Pipeline
    check(vk.CreateComputePipelines(dev, 0, 1, &cpci, nil, &pipe), "CreateComputePipelines")

    pinfo := vk.PipelineInfoKHR{sType = .PIPELINE_INFO_KHR, pipeline = pipe}
    en: u32
    check(vk.GetPipelineExecutablePropertiesKHR(dev, &pinfo, &en, nil), "GetPipelineExecutableProperties")
    eps := make([]vk.PipelineExecutablePropertiesKHR, en)
    for &e in eps { e.sType = .PIPELINE_EXECUTABLE_PROPERTIES_KHR }
    check(vk.GetPipelineExecutablePropertiesKHR(dev, &pinfo, &en, raw_data(eps)), "GetPipelineExecutableProperties")
    for e, i in eps {
        name, desc := e.name, e.description
        fmt.printf("executable %d: %s (%s), subgroup %d\n", i,
            strings.truncate_to_byte(string(name[:]), 0), strings.truncate_to_byte(string(desc[:]), 0), e.subgroupSize)
        einfo := vk.PipelineExecutableInfoKHR{sType = .PIPELINE_EXECUTABLE_INFO_KHR, pipeline = pipe, executableIndex = u32(i)}
        sn: u32
        check(vk.GetPipelineExecutableStatisticsKHR(dev, &einfo, &sn, nil), "GetPipelineExecutableStatistics")
        st := make([]vk.PipelineExecutableStatisticKHR, sn)
        for &s in st { s.sType = .PIPELINE_EXECUTABLE_STATISTIC_KHR }
        check(vk.GetPipelineExecutableStatisticsKHR(dev, &einfo, &sn, raw_data(st)), "GetPipelineExecutableStatistics")
        for s in st {
            sname, sdesc := s.name, s.description
            val: string
            switch s.format {
            case .BOOL32:  val = fmt.tprint(s.value.b32)
            case .INT64:   val = fmt.tprint(s.value.i64)
            case .UINT64:  val = fmt.tprint(s.value.u64)
            case .FLOAT64: val = fmt.tprint(s.value.f64)
            }
            fmt.printf("  %-32s %12s   %s\n", strings.truncate_to_byte(string(sname[:]), 0), val,
                strings.truncate_to_byte(string(sdesc[:]), 0))
        }
    }
}
