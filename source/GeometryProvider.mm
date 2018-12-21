//
//  GeometryProvider.mm
//  Metal ray-tracer
//
//  Created by Sergey Reznik on 9/17/18.
//  Copyright © 2018 Serhii Rieznik. All rights reserved.
//

#include "GeometryProvider.h"
#include "Spectrum.h"
#include "../external/tinyobjloader/tiny_obj_loader.h"
#include <fstream>

#define VALIDATE_SAMPLING_FUNCTION 0

#if (VALIDATE_SAMPLING_FUNCTION)
#   include <set>
#endif

GeometryProvider::GeometryProvider(const char* fileName, id<MTLDevice> device)
{
    if ((fileName == nullptr) || (strlen(fileName) == 0))
        return;

    NSLog(@"Loading .obj file `%s`...", fileName);
    
    tinyobj::attrib_t attrib;
    std::vector<tinyobj::shape_t> shapes;
    std::vector<tinyobj::material_t> materials;
    std::string errors;
    std::string warnings;

    std::string baseDir = fileName;
    size_t slash = baseDir.find_last_of('/');
    if (slash != std::string::npos)
        baseDir.erase(slash);

    const char* fileNamePtr = fileName;
    const char* baseDirPtr = baseDir.c_str();
    if (strncmp(fileNamePtr, "file://", 7) == 0)
    {
        fileNamePtr += 7;
        baseDirPtr += 7;
    }
    else if (strncmp(fileNamePtr, "file:", 5) == 0)
    {
        fileNamePtr += 5;
        baseDirPtr += 5;
    }

    if (!tinyobj::LoadObj(&attrib, &shapes, &materials, &warnings, &errors, fileNamePtr, baseDirPtr))
    {
        NSLog(@"Failed to load .obj file `%s`", fileName);
        NSLog(@"Warnings:\n%s", warnings.c_str());
        NSLog(@"Errors:\n%s", errors.c_str());

        Vertex vertices[3] = {
            { { 0.25f, 0.25f, 0.0f }, {}, {} },
            { { 0.75f, 0.25f, 0.0f }, {}, {} },
            { { 0.50f, 0.75f, 0.0f }, {}, {} }
        };
        uint32_t indices[3] = { 0, 1, 2 };

        _vertexBuffer = [device newBufferWithBytes:vertices length:sizeof(vertices) options:MTLResourceStorageModeManaged];
        _indexBuffer = [device newBufferWithBytes:indices length:sizeof(indices) options:MTLResourceStorageModeManaged];
        return;
    }

    if (!warnings.empty())
    {
        NSLog(@"Warnings:\n%s", warnings.c_str());
    }

    std::vector<Material> materialBuffer;
    for (const tinyobj::material_t& mtl : materials)
    {
        materialBuffer.emplace_back();
        Material& material = materialBuffer.back();
        material.diffuse = SampledSpectrum::fromRGB(RGBToSpectrumClass::Reflectance, mtl.diffuse).toGPUSpectrum();
        material.specular = SampledSpectrum::fromRGB(RGBToSpectrumClass::Reflectance, mtl.specular).toGPUSpectrum();
        material.transmittance = SampledSpectrum::fromRGB(RGBToSpectrumClass::Reflectance, mtl.transmittance).toGPUSpectrum();
        material.emissive = SampledSpectrum::fromRGB(RGBToSpectrumClass::Illuminant, mtl.emission).toGPUSpectrum();

        if (mtl.unknown_parameter.count("blackbody_t") > 0.0f)
        {
            double temperature = std::atof(mtl.unknown_parameter.at("blackbody_t").c_str());
            material.emissive = SampledSpectrum::fromBlackbodyWithTemperature(temperature, false).toGPUSpectrum();
        }

        if (mtl.unknown_parameter.count("spectrum_Ke") > 0.0f)
        {
            std::string spd = mtl.unknown_parameter.at("spectrum_Ke");
            material.emissive = loadSampledSpectrum("lights/" + spd, "spd").toGPUSpectrum();
        }

        if (mtl.unknown_parameter.count("scale_Ke") > 0.0f)
        {
            double scale = std::atof(mtl.unknown_parameter.at("scale_Ke").c_str());
            material.emissive = material.emissive * float(scale);
        }

        /*
        if (GPUSpectrumMax(material.emissive) > 0.0f)
        {
            mId = 2;
            float temp[] = { 2700.0f, 4000.0f, 6500.0f, 12000.0f };
            float scl[] = { 5.0e-2f, 1.0e-2f, 1.0e-3f, 1.0e-2f };
            material.emissive = SampledSpectrum::fromBlackbodyWithTemperature(temp[mId], false).toGPUSpectrum();
            material.emissive = material.emissive * scl[mId];
            mId = (mId + 1) % 4;
        }
        */
        
        material.type = mtl.illum;
        material.intIOR_eta = GPUSpectrumConst(mtl.ior);
        material.intIOR_k = GPUSpectrumConst(0.0f);
        material.extIOR = GPUSpectrumConst(1.0f);

        if ((mtl.roughness == 0.0f) && (mtl.shininess > 0.0f))
        {
            material.roughness = (2.0f / (2.0f + mtl.shininess));
            NSLog(@"Shininess remapped to roughness: %.3f -> %.3f", mtl.shininess, material.roughness);
        }
        material.roughness = std::max(mtl.roughness, 0.005f);

        if (mtl.unknown_parameter.count("Ne") > 0.0f)
        {
            double extIOR = std::atof(mtl.unknown_parameter.at("Ne").c_str());
            material.extIOR = GPUSpectrumConst((extIOR < 1.0) ? 1.0f : float(extIOR));
        }

        if (mtl.unknown_parameter.count("spectrum_Ni") > 0)
        {
            std::string spd = mtl.unknown_parameter.at("spectrum_Ni");
            material.intIOR_eta = loadSampledSpectrum(spd + ".eta", "spd").toGPUSpectrum();
            material.intIOR_k = loadSampledSpectrum(spd + ".k", "spd").toGPUSpectrum();
        }

        if (mtl.name == "environment")
        {
            _environment.textureName = mtl.ambient_texname;
            _environment.uniformColor = material.emissive;
        }
        else
        {
            NSLog(@" + material: %s, r: %.3f - %s (%.3f, %.3f, %.3f)", materialTypeToString(material.type), mtl.roughness, mtl.name.c_str(),
                  mtl.diffuse[0], mtl.diffuse[1], mtl.diffuse[2]);
        }
    }

    bool useDefaultMaterial = materialBuffer.empty();
    if (useDefaultMaterial)
    {
        materialBuffer.emplace_back();
        _environment.uniformColor = { 0.3f, 0.4f, 0.5f };
    }

    std::vector<uint32_t> indexBuffer;
    std::vector<Vertex> vertexBuffer;
    std::vector<Triangle> triangleBuffer;
    std::vector<EmitterTriangle> emitterTriangleBuffer;

    _boundsMin = { std::numeric_limits<float>::max(), std::numeric_limits<float>::max(), std::numeric_limits<float>::max() };
    _boundsMax = -_boundsMin;

    uint32_t globalTriangleIndex = 0;
    float totalLightArea = 0.0f;
    float totalLightScaledArea = 0.0f;
    for (const tinyobj::shape_t& shape : shapes)
    {
        NSLog(@" + shape: %s", shape.name.c_str());
        size_t triangleCount = shape.mesh.num_face_vertices.size();
        _triangleCount += static_cast<uint32_t>(triangleCount);

        size_t triangleBufferOffset = triangleBuffer.size();

        indexBuffer.resize(indexBuffer.size() + triangleCount * 3);
        triangleBuffer.resize(triangleBuffer.size() + triangleCount);

        size_t index = 0;
        for (size_t f = 0; f < triangleCount; ++f)
        {
            assert(shape.mesh.num_face_vertices[f] == 3);
            for (size_t j = 0; j < 3; ++j)
            {
                vertexBuffer.emplace_back();
                Vertex& vertex = vertexBuffer.back();
                const tinyobj::index_t& i = shape.mesh.indices[index];
                vertex.v.x = attrib.vertices[3 * i.vertex_index + 0];
                vertex.v.y = attrib.vertices[3 * i.vertex_index + 1];
                vertex.v.z = attrib.vertices[3 * i.vertex_index + 2];
                if (i.normal_index >= 0)
                {
                    vertex.n.x = attrib.normals[3 * i.normal_index + 0];
                    vertex.n.y = attrib.normals[3 * i.normal_index + 1];
                    vertex.n.z = attrib.normals[3 * i.normal_index + 2];
                }
                if (i.texcoord_index >= 0)
                {
                    vertex.t.x = attrib.texcoords[2 * i.texcoord_index + 0];
                    vertex.t.y = attrib.texcoords[2 * i.texcoord_index + 1];
                }

                _boundsMin = simd_min(_boundsMin, vertex.v);
                _boundsMax = simd_max(_boundsMax, vertex.v);

                ++index;
            }

            const Vertex& v0 = vertexBuffer[vertexBuffer.size() - 3];
            const Vertex& v1 = vertexBuffer[vertexBuffer.size() - 2];
            const Vertex& v2 = vertexBuffer[vertexBuffer.size() - 1];

            const Material& material = useDefaultMaterial ? materialBuffer.front() : materialBuffer[shape.mesh.material_ids[f]];
            float emissiveScale = SampledSpectrum::fromGPUSpectrum(material.emissive).toLuminance();

            float area = 0.5f * simd_length(simd_cross(v2.v - v0.v, v1.v - v0.v));
            float scaledArea = area * emissiveScale;

            triangleBuffer[triangleBufferOffset].materialIndex = useDefaultMaterial ? 0 : shape.mesh.material_ids[f];
            triangleBuffer[triangleBufferOffset].area = area;

            if (GPUSpectrumMax(material.emissive) > 0.0f)
            {
                emitterTriangleBuffer.emplace_back();
                emitterTriangleBuffer.back().area = area;
                emitterTriangleBuffer.back().scaledArea = scaledArea;
                emitterTriangleBuffer.back().globalIndex = globalTriangleIndex;
                emitterTriangleBuffer.back().v0 = v0;
                emitterTriangleBuffer.back().v1 = v1;
                emitterTriangleBuffer.back().v2 = v2;
                emitterTriangleBuffer.back().emissive = material.emissive;
                totalLightArea += emitterTriangleBuffer.back().area;
                totalLightScaledArea += emitterTriangleBuffer.back().scaledArea;
            }

            ++triangleBufferOffset;
            ++globalTriangleIndex;
        }
    }

    // std::random_shuffle(std::begin(emitterTriangleBuffer), std::end(emitterTriangleBuffer));

    //*
    std::sort(std::begin(emitterTriangleBuffer), std::end(emitterTriangleBuffer), [](const EmitterTriangle& l, const EmitterTriangle& r){
        return l.scaledArea < r.scaledArea;
    });
    // */

    _emitterTriangleCount = static_cast<uint32_t>(emitterTriangleBuffer.size());
    float emittersCDFIntegral = 0.0f;

    for (EmitterTriangle& t : emitterTriangleBuffer)
    {
        t.cdf = emittersCDFIntegral;
        t.discretePdf = (t.scaledArea / totalLightScaledArea);
        triangleBuffer[t.globalIndex].discretePdf = t.discretePdf;
        emittersCDFIntegral += t.scaledArea;

#   if (VALIDATE_SAMPLING_FUNCTION)
        NSLog(@"E: a - %.3f, sa - %.3f, cdf - %.3f, pdf - %.3f, global: %.3f",
            t.area, t.scaledArea, t.cdf, t.discretePdf, 0.0f);
#   endif
    }

    emitterTriangleBuffer.emplace_back();
    emitterTriangleBuffer.back().cdf = emittersCDFIntegral;

    for (EmitterTriangle& t : emitterTriangleBuffer)
    {
        t.cdf /= emittersCDFIntegral;
    }

#if (VALIDATE_SAMPLING_FUNCTION)
    if (_emitterTriangleCount > 0)
    {
        NSLog(@"Total CDF: %.3f, total area: %.3f", emittersCDFIntegral, totalLightScaledArea);

        auto sampleEmitterTriangle = [&emitterTriangleBuffer](float xi) {
            uint l = 0;
            uint r = uint(emitterTriangleBuffer.size() - 1);

            bool continueSearch = true;
            do
            {
                uint m = (l + r) / 2;
                float c = emitterTriangleBuffer[m + 1].cdf;
                uint setRight = uint32_t(c > xi);
                uint setLeft = uint32_t(c < xi);
                r -= setRight * (r - m);
                l += setLeft * ((m + 1) - l);
                continueSearch = (l < r) && (setRight + setLeft > 0);
            } while (continueSearch);
            return l;
        };

        std::map<uint32_t, std::pair<float, float>> sampledIndices;
        std::map<uint32_t, uint32_t> sampledCount;
        for (uint32_t i = 0; i < 1000000; ++i)
        {
            float xi = float(rand()) / float(RAND_MAX);
            uint t = sampleEmitterTriangle(xi);
            if (sampledIndices.count(t) == 0)
            {
                sampledIndices[t] = { xi, xi };
            }
            else
            {
                sampledIndices[t].first = std::min(sampledIndices[t].first, xi);
                sampledIndices[t].second = std::max(sampledIndices[t].second, xi);
            }
            sampledCount[t] += 1;
        }
        assert(sampledIndices.size() + 1 == emitterTriangleBuffer.size());

        NSLog(@"----------------");

        for (const auto& p : sampledIndices)
        {
            NSLog(@"[%2u] CDF: %.4f, xi: [%.4f ... %.4f], size: %.4f, sampled: %u", p.first, emitterTriangleBuffer[p.first].cdf,
                  p.second.first, p.second.second, p.second.second - p.second.first, sampledCount[p.first]);
        }
    }
#endif

    for (uint32_t i = 0; i < indexBuffer.size(); ++i)
        indexBuffer[i] = i;

    BufferConstructor makeBuffer(device);
    _vertexBuffer = makeBuffer(vertexBuffer, @"Geometry vertex buffer");
    _indexBuffer = makeBuffer(indexBuffer, @"Geometry index buffer");
    _materialBuffer = makeBuffer(materialBuffer, @"Geometry material buffer");
    _triangleBuffer = makeBuffer(triangleBuffer, @"Geometry triangle buffer");
    _emitterTriangleBuffer = makeBuffer(emitterTriangleBuffer, @"Emitter triangle buffer");

    NSLog(@".obj file loaded: %zu vertices, %zu normals, %zu tex coords, %u triangles, %zu materials", attrib.vertices.size(),
          attrib.normals.size(), attrib.texcoords.size(), _triangleCount, materials.size());
}

SampledSpectrum GeometryProvider::loadSampledSpectrum(const std::string& material, const std::string& ext)
{
    NSURL* url = [[NSBundle mainBundle] URLForResource:[NSString stringWithFormat:@"media/spectrum/%s", material.c_str()]
        withExtension:[NSString stringWithUTF8String:ext.c_str()]];

    std::vector<float> wavelengths;
    std::vector<float> values;

    NSString* path = [url path];
    std::ifstream fIn([path cStringUsingEncoding:NSUTF8StringEncoding]);
    while (fIn.good() && !fIn.eof())
    {
        std::string line;
        std::getline(fIn, line);
        if (line.empty() || (line[0] == '#'))
            continue;

        float wavelength = 0.0f;
        float value = 0.0f;
        sscanf(line.c_str(), "%f %f", &wavelength, &value);
        NSLog(@"%f %f", wavelength, value);
        wavelengths.emplace_back(wavelength);
        values.emplace_back(value);
    }

    return SampledSpectrum::fromSamples(wavelengths.data(), values.data(), uint32_t(wavelengths.size()));
}

const char* GeometryProvider::materialTypeToString(uint32_t t)
{
#define CASE(x) case x: return #x
    switch (t)
    {
        CASE(MATERIAL_DIFFUSE);
        CASE(MATERIAL_CONDUCTOR);
        CASE(MATERIAL_PLASTIC);
        CASE(MATERIAL_DIELECTRIC);
        default:
            return "unknown material, defaulted to diffuse";
    }
#undef CASE
}
