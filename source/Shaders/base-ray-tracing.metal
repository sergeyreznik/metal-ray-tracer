//
//  base-ray-tracing.metal
//  Metal ray-tracer
//
//  Created by Sergey Reznik on 9/15/18.
//  Copyright © 2018 Serhii Rieznik. All rights reserved.
//

#include <metal_stdlib>
#include "structures.h"

using namespace metal;

kernel void generateRays(device Ray* rays [[buffer(0)]],
                         uint2 coordinates [[thread_position_in_grid]],
                         uint2 size [[threads_per_grid]])
{
    const float3 origin = float3(0.0f, 1.0f, 2.1f);

    float aspect = float(size.x) / float(size.y);
    float2 uv = float2(coordinates) / float2(size - 1) * 2.0f - 1.0f;
    float3 direction = normalize(float3(aspect * uv.x, uv.y, -1.0f));

    uint rayIndex = coordinates.x + coordinates.y * size.x;
    rays[rayIndex].origin = origin;
    rays[rayIndex].direction = direction;
    rays[rayIndex].minDistance = DISTANCE_EPSILON;
    rays[rayIndex].maxDistance = INFINITY;
}

kernel void handleIntersections(texture2d<float, access::write> image [[texture(0)]],
                                device const Intersection* intersections [[buffer(0)]],
                                device const Material* materials [[buffer(1)]],
                                device const Triangle* triangles [[buffer(2)]],
                                uint2 coordinates [[thread_position_in_grid]],
                                uint2 size [[threads_per_grid]])
{
    uint rayIndex = coordinates.x + coordinates.y * size.x;
    device const Intersection& i = intersections[rayIndex];
    if (i.distance < DISTANCE_EPSILON)
        return;

    device const Triangle& triangle = triangles[i.primitiveIndex];
    device const Material& material = materials[triangle.materialIndex];
    image.write(float4(material.diffuse, 1.0), coordinates);
}
