// Per-frame uniforms shared by every pass (Camera_Uniform in gpu.odin).
// Each float3 is padded to a float4 (cbuffer packing rules).
#ifndef CAMERA_UNIFORMS_HLSL
#define CAMERA_UNIFORMS_HLSL

cbuffer CameraUniforms : register(b0, space2) {
    float3 u_cam_pos;
    float  _pad0;
    float3 u_cam_fwd;
    float  _pad1;
    float3 u_cam_right;
    float  _pad2;
    float3 u_cam_up;
    float  _pad3;
    float3 u_light_dir_raw;
    float  _pad4;
    int    u_reflect_amount;
    int    u_quality;        // AA*10 + shadow mode (1 hard, 3 soft)
    int    u_vol;            // enabled*100 + steps
    int    u_entity_count;
    float  u_time;
    float  u_exposure;
    float  u_fog_density;
    float  u_cave_factor;
    float  u_sun_intensity;
    int    u_far_enabled;
    float2 _pad5;
    float4 u_near_circle;    // near (voxel) region: XZ center, radius in voxels, unused
};

#endif // CAMERA_UNIFORMS_HLSL
