
in vec4 uvcoordsvar;

out vec4 FragColor;

uniform sampler1D sssTexProfile;
uniform sampler2D sssRadius;

uniform sampler2DArray sssShadowCubes;
uniform sampler2DArray sssShadowCascades;

#define MAX_SSS_SAMPLES 65
#define SSS_LUT_SIZE 64.0
#define SSS_LUT_SCALE ((SSS_LUT_SIZE - 1.0) / float(SSS_LUT_SIZE))
#define SSS_LUT_BIAS (0.5 / float(SSS_LUT_SIZE))

layout(std140) uniform sssProfile
{
  vec4 kernel[MAX_SSS_SAMPLES];
  vec4 radii_max_radius;
  int sss_samples;
};

vec3 sss_profile(float s)
{
  s /= radii_max_radius.w;
  return texture(sssTexProfile, saturate(s) * SSS_LUT_SCALE + SSS_LUT_BIAS).rgb;
}

#ifndef UTIL_TEX
#  define UTIL_TEX
uniform sampler2DArray utilTex;
#  define texelfetch_noise_tex(coord) texelFetch(utilTex, ivec3(ivec2(coord) % LUT_SIZE, 2.0), 0)
#endif /* UTIL_TEX */

float light_translucent_power_with_falloff(LightData ld, vec3 N, vec4 l_vector)
{
  float power, falloff;
  /* XXX : Removing Area Power. */
  /* TODO : put this out of the shader. */
  if (ld.l_type >= AREA_RECT) {
    power = (ld.l_sizex * ld.l_sizey * 4.0 * M_PI) * (1.0 / 80.0);
    if (ld.l_type == AREA_ELLIPSE) {
      power *= M_PI * 0.25;
    }
    power *= 0.3 * 20.0 *
             max(0.0, dot(-ld.l_forward, l_vector.xyz / l_vector.w)); /* XXX ad hoc, empirical */
    power /= (l_vector.w * l_vector.w);
    falloff = dot(N, l_vector.xyz / l_vector.w);
  }
  else if (ld.l_type == SUN) {
    power = 1.0 / (1.0 + (ld.l_radius * ld.l_radius * 0.5));
    power *= ld.l_radius * ld.l_radius * M_PI; /* Removing area light power*/
    power *= M_2PI * 0.78;                     /* Matching cycles with point light. */
    power *= 0.082;                            /* XXX ad hoc, empirical */
    falloff = dot(N, -ld.l_forward);
  }
  else {
    power = (4.0 * ld.l_radius * ld.l_radius) * (1.0 / 10.0);
    power *= 1.5; /* XXX ad hoc, empirical */
    power /= (l_vector.w * l_vector.w);
    falloff = dot(N, l_vector.xyz / l_vector.w);
  }
  /* No transmittance at grazing angle (hide artifacts) */
  return power * saturate(falloff * 2.0);
}

/* Some driver poorly optimize this code. Use direct reference to matrices. */
#define sd(x) shadows_data[x]
#define scube(x) shadows_cube_data[x]
#define scascade(x) shadows_cascade_data[x]

vec3 light_translucent(LightData ld, vec3 W, vec3 N, vec4 l_vector, vec2 rand, float sss_scale)
{
  int shadow_id = int(ld.l_shadowid);

  vec4 L = (ld.l_type != SUN) ? l_vector : vec4(-ld.l_forward, 1.0);

  /* We use the full l_vector.xyz so that the spread is minimize
   * if the shading point is further away from the light source */
  /* TODO(fclem) do something better than this. */
  // vec3 T, B;
  // make_orthonormal_basis(L.xyz / L.w, T, B);
  // rand.xy *= data.sh_blur;
  // W = W + T * rand.x + B * rand.y;

  float s, dist;
  int data_id = int(sd(shadow_id).sh_data_index);
  if (ld.l_type == SUN) {
    vec4 view_z = vec4(dot(W - cameraPos, cameraForward));

    vec4 weights = step(scascade(data_id).split_end_distances, view_z);
    float id = abs(4.0 - dot(weights, weights));
    if (id > 3.0) {
      return vec3(0.0);
    }

    /* Same factor as in get_cascade_world_distance(). */
    float range = abs(sd(shadow_id).sh_far - sd(shadow_id).sh_near);

    vec4 shpos = scascade(data_id).shadowmat[int(id)] * vec4(W, 1.0);
    dist = shpos.z * range;

    if (shpos.z > 1.0 || shpos.z < 0.0) {
      return vec3(0.0);
    }

    float tex_id = scascade(data_id).sh_tex_index;
    s = sample_cascade(sssShadowCascades, shpos.xy, tex_id + id).r;
    s *= range;
  }
  else {
    vec3 cubevec = transform_point(scube(data_id).shadowmat, W);
    dist = length(cubevec);
    cubevec /= dist;
    /* tex_id == data_id for cube shadowmap */
    float tex_id = float(data_id);
    s = sample_cube(sssShadowCubes, cubevec, tex_id).r;
    s = length(cubevec / max_v3(abs(cubevec))) *
        linear_depth(true, s, sd(shadow_id).sh_far, sd(shadow_id).sh_near);
  }
  float delta = dist - s;

  float power = light_translucent_power_with_falloff(ld, N, l_vector);

  return power * sss_profile(abs(delta) / sss_scale);
}

#undef sd
#undef scube
#undef scsmd

void main(void)
{
  vec2 uvs = uvcoordsvar.xy;
  float sss_scale = texture(sssRadius, uvs).r;
  vec3 W = get_world_space_from_depth(uvs, texture(depthBuffer, uvs).r);
  vec3 N = normalize(cross(dFdx(W), dFdy(W)));

  vec3 rand = texelfetch_noise_tex(gl_FragCoord.xy).zwy;
  rand.xy *= fast_sqrt(rand.z);

  vec3 accum = vec3(0.0);
  for (int i = 0; i < MAX_LIGHT && i < laNumLight; i++) {
    LightData ld = lights_data[i];

    /* Only shadowed light can produce translucency */
    if (ld.l_shadowid < 0.0) {
      continue;
    }

    vec4 l_vector; /* Non-Normalized Light Vector with length in last component. */
    l_vector.xyz = ld.l_position - W;
    l_vector.w = length(l_vector.xyz);

    float att = light_attenuation(ld, l_vector);
    if (att < 1e-8) {
      continue;
    }

    accum += att * ld.l_color * light_translucent(ld, W, -N, l_vector, rand.xy, sss_scale);
  }

  FragColor = vec4(accum, 1.0);
}
