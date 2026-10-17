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
    int    u_ent_debug;      // bench: 1 = skip entity view rays, 2 = skip entity shadows, 4 = no cumulus
    float  _pad5;
    float4 u_near_circle;    // near (voxel) region: XZ center, radius in voxels, unused
    float4 u_sun_true;       // xyz = real sun direction (u_light_dir_raw is the moon at night), w = night 0..1
    float4 u_atmos;          // x = valley mist amount
    float4 u_thermals[16];   // cumulus over thermals: XZ centre at cloud base, radius, strength (MAX_SKY_THERMALS)
    int4   u_thermal_count;  // x = count
    float4 u_cloud_puffs[64];// per thermal 4 cumulus towers: offset (cloud radii), radius
    float4 u_hand_light;     // torch in hand: xyz = position, w = light level (0 = none)
    int4   u_gi_origin;      // bounce-light probe grid (gi_common.hlsl): min corner in probe coords, w = enabled
    int4   u_gi_frame;       // x = first probe slot updated this frame, y = frame counter
    int4   u_torch;          // torch shadows (torch.odin): xyz = the box's min chunk, w = emitters listed (0 = off)
    float4 u_torch_params;   // x = share of torch light left in its shadow
};

#endif // CAMERA_UNIFORMS_HLSL
