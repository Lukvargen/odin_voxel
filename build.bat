@echo off
setlocal
cd /d "%~dp0"

set DXC=C:\dev\vulkanSDK\Bin\dxc.exe

echo Compiling shaders...
%DXC% -T cs_6_0 -E main -I shaders shaders\voxel_tracer.hlsl -spirv -fspv-target-env=vulkan1.1 -Fo shaders\voxel_tracer.spv
if %errorlevel% neq 0 ( echo voxel_tracer shader failed! & exit /b 1 )
%DXC% -T cs_6_0 -E main -I shaders shaders\volumetric.hlsl -spirv -fspv-target-env=vulkan1.1 -Fo shaders\volumetric.spv
if %errorlevel% neq 0 ( echo volumetric shader failed! & exit /b 1 )
%DXC% -T cs_6_0 -E main -I shaders shaders\composite.hlsl -spirv -fspv-target-env=vulkan1.1 -Fo shaders\composite.spv
if %errorlevel% neq 0 ( echo composite shader failed! & exit /b 1 )
%DXC% -T cs_6_0 -E main -I shaders shaders\gi_update.hlsl -spirv -fspv-target-env=vulkan1.1 -Fo shaders\gi_update.spv
if %errorlevel% neq 0 ( echo gi_update shader failed! & exit /b 1 )
%DXC% -T cs_6_0 -E main -I shaders shaders\gi_clear.hlsl -spirv -fspv-target-env=vulkan1.1 -Fo shaders\gi_clear.spv
if %errorlevel% neq 0 ( echo gi_clear shader failed! & exit /b 1 )
%DXC% -T cs_6_0 -E main -I shaders shaders\bloom_prefilter.hlsl -spirv -fspv-target-env=vulkan1.1 -Fo shaders\bloom_prefilter.spv
if %errorlevel% neq 0 ( echo bloom_prefilter shader failed! & exit /b 1 )
%DXC% -T cs_6_0 -E main -DHORIZONTAL=1 -I shaders shaders\bloom_blur.hlsl -spirv -fspv-target-env=vulkan1.1 -Fo shaders\bloom_blur_h.spv
if %errorlevel% neq 0 ( echo bloom_blur_h shader failed! & exit /b 1 )
%DXC% -T cs_6_0 -E main -I shaders shaders\bloom_blur.hlsl -spirv -fspv-target-env=vulkan1.1 -Fo shaders\bloom_blur_v.spv
if %errorlevel% neq 0 ( echo bloom_blur_v shader failed! & exit /b 1 )
echo Shaders compiled OK.

echo Building Odin...
odin build . -debug -out:odin_raytrace.exe
if %errorlevel% neq 0 (
    echo Odin build failed!
    exit /b 1
)
echo Build OK.
