// Copyright 2009 Intel Corporation
// SPDX-License-Identifier: Apache-2.0

#include "common/Instance.ih"
#include "common/World.ih"
#include "math/random.ih"
#include "math/sampling.ih"
#include "openvkl/openvkl.isph"
#include "render/materials/OBJ.ih"
#include "render/scivis/surfaces.ih"
#include "render/scivis/volumes.ih"
#include "render/util.ih"
#include "rkcommon/math/box.ih"
#include "volume/VolumetricModel.ih"
// c++ shared
#include "../../common/DistributedWorldShared.h"
#include "DistributedRaycastShared.h"
#include "fb/FrameBufferShared.h"
#include "fb/SparseFBShared.h"

// The distributed raycast renderer uses its own volume interval integration
// because we want to apply the jitter before offsetting our step size to stay
// inside the region, not after.
vec4f DRR_integrateVolumeInterval(const ScreenSample &sample,
    const VolumeInterval &interval,
    Ray &ray,
    uniform float samplingRate)
{
  VolumetricModel *varying volModel = interval.volumetricModel;

  Ray transformedRay = ray;
  transformRay(transformedRay, interval.instance->rcp_xfm);

  uniform unsigned int8 intervalIteratorBuffer[VKL_MAX_INTERVAL_ITERATOR_SIZE];

  vec3f color = make_vec3f(0.f);
  float alpha = 0.f;
  foreach_unique (vm in volModel) {
    Volume *uniform volume = vm->volume;
    TransferFunction *uniform tf = vm->transferFunction;

    float time = 0.5f;
    VKLIntervalIterator intervalIterator =
        vklInitIntervalIteratorV(vm->vklIntervalContext,
            (varying vkl_vec3f *)&transformedRay.org,
            (varying vkl_vec3f *)&transformedRay.dir,
            (varying vkl_range1f *)&interval.interval,
            &time,
            intervalIteratorBuffer);

    VKLInterval interval;
    while (vklIterateIntervalV(intervalIterator, &interval) && alpha < 0.99f) {
      const float nominalSamplingDt = interval.nominalDeltaT / samplingRate;

      // initial sub interval, based on our renderer-defined sampling rate
      // and the volume's nominal dt
      box1f subInterval = make_box1f(interval.tRange.lower,
          min(interval.tRange.lower + nominalSamplingDt,
              interval.tRange.upper));

      while (subInterval.upper - subInterval.lower > 0.f && alpha < 0.99f) {
        transformedRay.t0 =
            subInterval.lower + (subInterval.upper - subInterval.lower);
        const float dt = subInterval.upper - subInterval.lower;

        // Get volume sample
        vec3f p = transformedRay.org + transformedRay.t0 * transformedRay.dir;
        const float sample = vklComputeSampleV(
            volume->vklSampler, (const varying vkl_vec3f *uniform) & p);

        if (!isnan(sample)) {
          vec4f sampleColorOpacity = tf->get(tf, sample);

          sampleColorOpacity.w = 1.f
              - pow(1.f - sampleColorOpacity.w * vm->densityScale,
                  dt / interval.nominalDeltaT);
          const float clampedOpacity = clamp(sampleColorOpacity.w);
          color = color
              + ((1.f - alpha) * clampedOpacity
                  * make_vec3f(sampleColorOpacity));
          alpha = alpha + ((1.f - alpha) * clampedOpacity);
        }

        // compute next sub interval
        subInterval.lower = subInterval.upper;
        subInterval.upper =
            min(subInterval.lower + nominalSamplingDt, interval.tRange.upper);
      }
    }
  }

  return make_vec4f(color, alpha);
}

inline float computeAO(const DistributedRaycastRenderer *uniform self,
    const FrameBuffer *uniform fb,
    const World *uniform world,
    const varying vec3i &sampleID,
    const varying DifferentialGeometry &dg)
{
  const uniform int &sampleCnt = self->aoSamples;
  const uniform int accumID = reduce_max(sampleID.z) * sampleCnt;

  // init TEA RNG //
  RandomTEA rng_state;
  varying RandomTEA *const uniform rng = &rng_state;
  RandomTEA__Constructor(rng, 0x290374, (fb->size.x * sampleID.y) + sampleID.x);
  const vec2f rot = RandomTEA__getFloats(rng);

  int hits = 0;

  const linear3f localToWorld = frame(dg.Ns);

  for (uniform int i = 0; i < sampleCnt; i++) {
    const vec2f halton = HaltonSequence_get2D(accumID + i);
    const vec2f r = CranleyPattersonRotation(halton, rot);
    const vec3f local_ao_dir = cosineSampleHemisphere(r);
    const vec3f ao_dir = localToWorld * local_ao_dir;

    if (dot(ao_dir, dg.Ns) < 0.05f) { // check below surface
      hits++;
      continue;
    }

    Ray ao_ray;
    setRay(ao_ray, dg.P, ao_dir, dg.epsilon, self->aoRadius);
    if (isOccluded(world, ao_ray))
      hits++;
  }

  // the cosTheta of cosineSampleHemispherePDF and dot(shadingNormal, ao_dir)
  // cancel
  return 1.0f - (hits / (float)sampleCnt);
}

vec4f DRR_shadeSurface(const DistributedRaycastRenderer *uniform self,
    const FrameBuffer *uniform fb,
    const DistributedWorld *uniform world,
    const vec3i &sampleID,
    const Ray &ray,
    const DifferentialGeometry &dg)
{
  // TODO: DRR should have its own support for OBJ material and lighting model

  vec3f surfaceColor = make_vec3f(dg.color);
  float opacity = 1.f;
  const OBJ *mat = (const OBJ *)dg.material;
  if (mat) {
    foreach_unique (m in mat) {
      surfaceColor = surfaceColor * m->Kd;
      opacity = m->d;
      if (valid(m->KdMap)) {
        vec4f kdFromMap = get4f(m->KdMap, dg);
        surfaceColor = surfaceColor * make_vec3f(kdFromMap);
      }
    }
  }

  // Just eyelight for now...
  const float eyeLightIntensity = absf(dot(dg.Ns, ray.dir));
  vec3f color = surfaceColor * eyeLightIntensity;
  if (self->aoSamples > 0) {
    float ao = computeAO(self, fb, &world->super, sampleID, dg);
    color = color * ao;
  }
  return make_vec4f(color, opacity);

#if 0
  // TODO LIGHTS
  // Calculate shading for all lights
  for (uniform int i = 0; self->lights && i < self->numLights; i++) {
    const uniform Light *uniform l = self->lights[i];
    const vec2f s = make_vec2f(0.0f); // sample center of area lights
    const Light_SampleRes light = l->sample(l, dg, s);

    // any potential contribution?
    if (reduce_max(light.weight) > 0.f) {
      float cosNL = dot(light.dir, info.shadingNormal);
      if (cosNL < 0.0f)
        continue;

      cosNL = abs(cosNL);

      const vec3f H = normalize(light.dir - ray.dir);
      const float cosNH = dot(H, info.shadingNormal);
      const vec3f specular = info.Ks * powf(cosNH, info.Ns);
      const vec3f diffuse = info.Kd * cosNL;
      const vec3f light_contrib =
        info.local_opacity * (diffuse + specular) * light.weight;

      if (self->shadowsEnabled) {
        const float max_contrib = reduce_max(light_contrib);
        if (max_contrib > self->super.minContribution) {
          vec3f P = dg.P;
          if (dot(dg.Ng, light.dir) < 0.0f) {
            P = P - (2.f * dg.epsilon) * dg.Ng;
          }

          Ray shadowRay;
          setRay(shadowRay, P, light.dir, 0.0f, light.dist, 0.5f);
          if (!isOccluded(model, shadowRay)
              && !(ghostModel && isOccluded(ghostModel, shadowRay)))
          {
            color = color + light_contrib;
          }
        }
      } else {
        color = color + light_contrib;
      }
    }
  }
#endif
  return color;
}

void DRR_renderRegionSample(DistributedRenderer *uniform _self,
    SparseFB *uniform fb,
    DistributedWorld *uniform world,
    const box3f *uniform region,
    const vec2f &regionInterval,
    void *uniform perFrameData,
    varying ScreenSample &sample)
{
  DistributedRaycastRenderer *uniform self =
      (DistributedRaycastRenderer * uniform) _self;

  Ray &geomRay = sample.ray;
  Ray volumeRay = sample.ray;

  VolumeInterval volumeInterval;

  traceRay(&world->super, geomRay);
  traceVolumeRay(&world->super, volumeRay, volumeInterval);
  volumeInterval.interval.lower =
      max(volumeInterval.interval.lower, regionInterval.x);
  volumeInterval.interval.upper =
      min(volumeInterval.interval.upper, regionInterval.y);

  sample.z = min(geomRay.t, volumeInterval.interval.lower);

  // TODO: Doesn't seem like much jittering happens with the volume integration
  vec4f outputColor = make_vec4f(0.f);
  while (outputColor.w < 0.99f) {
    const bool haveGeometryHit = hadHit(geomRay)
        && geomRay.t >= regionInterval.x && geomRay.t <= regionInterval.y;

    const bool haveVolumeHit = hasInterval(volumeInterval);

    const bool bothHit = haveGeometryHit && haveVolumeHit;
    const bool eitherHit = haveGeometryHit || haveVolumeHit;

    const bool volumeFirst = volumeInterval.interval.lower < geomRay.t;

    if (!eitherHit) {
      break;
    }

    vec4f volumeColor = make_vec4f(0.f);
    vec4f surfaceColor = make_vec4f(0.f);
    DifferentialGeometry dg;
    if (haveGeometryHit) {
      postIntersect(&world->super,
          &self->super.super,
          dg,
          geomRay,
          DG_NG | DG_NS | DG_NORMALIZE | DG_FACEFORWARD | DG_COLOR
              | DG_TEXCOORD);
      surfaceColor = DRR_shadeSurface(
          self, &fb->super, world, sample.sampleID, geomRay, dg);
    }

    // Always just integrate the volume when it comes in front of the geometry
    if (haveVolumeHit && volumeFirst) {
      volumeInterval.interval.upper =
          min(geomRay.t, volumeInterval.interval.upper);

      // Keep the interval within the region
      volumeInterval.interval.lower =
          max(volumeInterval.interval.lower, regionInterval.x);
      volumeInterval.interval.upper =
          min(volumeInterval.interval.upper, regionInterval.y);

      // Offset the volume interval start to align to the same sampling steps
      // across each rank, and apply the same jitter for each pixel on all ranks
      float dt = 1.f /*was 'volModel->samplingStep*/ / self->volumeSamplingRate;
      float t0 = volumeInterval.interval.lower;
      volumeInterval.interval.lower = floor(t0 / dt) * dt;

      float jitter = Halton_sample2(sample.sampleID.z);
      int ix = sample.sampleID.x % 4;
      int iy = sample.sampleID.y % 4;

      int patternID = ix + 4 * iy;
      jitter += Halton_sample3(patternID);
      if (jitter > 1.f) {
        jitter -= 1.f;
      }
      volumeInterval.interval.lower += jitter * dt;

      if (volumeInterval.interval.lower < t0) {
        volumeInterval.interval.lower += dt;
      }

      // TODO: At edges when coloring all bricks the same I do still see
      // some edge/border artifacts

      setRay(volumeRay,
          volumeInterval.interval.lower,
          volumeInterval.interval.upper);
      volumeColor = DRR_integrateVolumeInterval(
          sample, volumeInterval, volumeRay, self->volumeSamplingRate);
    }

    vec4f blendedColor = make_vec4f(0.f);
    if (bothHit) {
      blendedColor = volumeColor + (1.0f - volumeColor.w) * surfaceColor;
    } else {
      if (haveGeometryHit)
        blendedColor = surfaceColor;
      else
        blendedColor = volumeColor;
    }

    outputColor = outputColor + (1.0f - outputColor.w) * blendedColor;

    if (haveGeometryHit)
      setRay(geomRay, geomRay.t + dg.epsilon, regionInterval.y + 0.0001);
    else
      setRay(geomRay, geomRay.t, geomRay.t0);

    // Step the volume ray forwards as well
    volumeRay = geomRay;

    traceRay(&world->super, geomRay);
    traceVolumeRay(&world->super, volumeRay, volumeInterval);
  }
  sample.rgb = make_vec3f(outputColor);
  sample.alpha = outputColor.w;
}

// Exported functions /////////////////////////////////////////////////////////

export void *uniform DRR_renderRegionSample_addr()
{
  return DRR_renderRegionSample;
}
