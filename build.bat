@echo off
setlocal
cd /d "%~dp0"

rem DXC with SPIR-V output: the Vulkan SDK's, or a release from
rem github.com/microsoft/DirectXShaderCompiler (the Windows SDK's can't emit SPIR-V).
if not defined DXC set DXC=C:\dev\vulkanSDK\Bin\dxc.exe
if not exist "%DXC%" set DXC=C:\dev\dxc\bin\x64\dxc.exe

echo Compiling shaders...
"%DXC%" -T cs_6_0 -E main -I shaders shaders\voxel_tracer.hlsl -spirv -fspv-target-env=vulkan1.1 -Fo shaders\voxel_tracer.spv
if %errorlevel% neq 0 ( echo voxel_tracer shader failed! & exit /b 1 )
"%DXC%" -T cs_6_0 -E main -I shaders shaders\volumetric.hlsl -spirv -fspv-target-env=vulkan1.1 -Fo shaders\volumetric.spv
if %errorlevel% neq 0 ( echo volumetric shader failed! & exit /b 1 )
"%DXC%" -T cs_6_0 -E main -I shaders shaders\composite.hlsl -spirv -fspv-target-env=vulkan1.1 -Fo shaders\composite.spv
if %errorlevel% neq 0 ( echo composite shader failed! & exit /b 1 )
"%DXC%" -T cs_6_0 -E main -I shaders shaders\bloom_prefilter.hlsl -spirv -fspv-target-env=vulkan1.1 -Fo shaders\bloom_prefilter.spv
if %errorlevel% neq 0 ( echo bloom_prefilter shader failed! & exit /b 1 )
"%DXC%" -T cs_6_0 -E main -DHORIZONTAL=1 -I shaders shaders\bloom_blur.hlsl -spirv -fspv-target-env=vulkan1.1 -Fo shaders\bloom_blur_h.spv
if %errorlevel% neq 0 ( echo bloom_blur_h shader failed! & exit /b 1 )
"%DXC%" -T cs_6_0 -E main -I shaders shaders\bloom_blur.hlsl -spirv -fspv-target-env=vulkan1.1 -Fo shaders\bloom_blur_v.spv
if %errorlevel% neq 0 ( echo bloom_blur_v shader failed! & exit /b 1 )
"%DXC%" -T cs_6_0 -E main -I shaders shaders\gi_probes.hlsl -spirv -fspv-target-env=vulkan1.1 -Fo shaders\gi_probes.spv
if %errorlevel% neq 0 ( echo gi_probes shader failed! & exit /b 1 )
echo Shaders compiled OK.
rem `build.bat shaders`: only the shaders (package.bat builds the exe its own way).
if /i "%~1"=="shaders" exit /b 0

rem `build.bat fast`: optimized (-o:speed), for playing. -debug alone means
rem -o:none: quick to build, but terrain, light and streaming run 4-10x
rem slower on the CPU (world loads in ~26 s instead of ~6). GPU time is the same.
set OPT=
if /i "%~1"=="fast" set OPT=-o:speed
echo Building Odin... %OPT%
odin build . -debug %OPT% -out:odin_raytrace.exe
if %errorlevel% neq 0 (
    echo Odin build failed!
    exit /b 1
)
echo Build OK.
