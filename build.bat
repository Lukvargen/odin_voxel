@echo off
setlocal
cd /d "%~dp0"

set DXC=C:\dev\vulkanSDK\Bin\dxc.exe

echo Compiling shader...
%DXC% -T cs_6_0 -E main shaders\voxel_tracer.hlsl -spirv -fspv-target-env=vulkan1.1 -Fo shaders\voxel_tracer.spv
if %errorlevel% neq 0 (
    echo Shader compilation failed!
    exit /b 1
)
echo Shader compiled OK.

echo Building Odin...
odin build . -debug -out:odin_raytrace.exe
if %errorlevel% neq 0 (
    echo Odin build failed!
    exit /b 1
)
echo Build OK.
