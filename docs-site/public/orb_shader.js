// Auto-bundled WebGL2 Liquid-Chrome Orb Shader from Th0rgal/orb-shader
(function() {
  if (typeof window === "undefined") return;
  window.initOrbShaderCanvas = function(canvasShader, opts) {
    if (!canvasShader || typeof ORB_SPEC_F32_B64 === "undefined") return null;
    opts = opts || {};
    const customW = opts.width || canvasShader.width || 480;
    const customH = opts.height || canvasShader.height || 480;
    const customRad = opts.radius || 0.42;
    const fixedTime = null;
    canvasShader.width = customW;
    canvasShader.height = customH;
    const state = {
      paused: false,
      time: 0.0,
      speed: opts.speed ?? 1.15,
      flowAmp: opts.flowAmp ?? 1.55,
      metalAmp: opts.metalAmp ?? 1.35,
      relightAmp: opts.relightAmp ?? 1.50,
      iridAmp: opts.iridAmp ?? 1.45,
      haloAmp: opts.haloAmp ?? 1.40,
      pointerX: 0.0,
      pointerY: 0.0,
      targetPointerX: 0.0,
      targetPointerY: 0.0
    };
    const gl = canvasShader.getContext("webgl2", { antialias: true, alpha: false, preserveDrawingBuffer: false });
    if (!gl) return null;
    const extFloat = gl.getExtension("EXT_color_buffer_float");
    gl.getExtension("OES_texture_float_linear");
    if (!extFloat) return null;

    function compileShader(type, src) {
      const sh = gl.createShader(type);
      gl.shaderSource(sh, src);
      gl.compileShader(sh);
      if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) {
        console.error("Shader compile error:", gl.getShaderInfoLog(sh));
      }
      return sh;
    }

    function createProgram(vsSrc, fsSrc) {
      const p = gl.createProgram();
      gl.attachShader(p, compileShader(gl.VERTEX_SHADER, vsSrc));
      gl.attachShader(p, compileShader(gl.FRAGMENT_SHADER, fsSrc));
      gl.linkProgram(p);
      if (!gl.getProgramParameter(p, gl.LINK_STATUS)) {
        console.error("Program link error:", gl.getProgramInfoLog(p));
      }
      return p;
    }

const vsFbo = `#version 300 es
        in vec2 aPosition;
        out vec2 vUv;
        void main() {
          vUv = aPosition * 0.5 + 0.5;
          gl_Position = vec4(aPosition, 0.0, 1.0);
        }
      `;

      const vsScreen = `#version 300 es
        in vec2 aPosition;
        out vec2 vUv;
        void main() {
          vUv = vec2(aPosition.x * 0.5 + 0.5, 0.5 - aPosition.y * 0.5);
          gl_Position = vec4(aPosition, 0.0, 1.0);
        }
      `;

      // Pass 1A: Synthesize 1D Fourier Angular Harmonics F_k(theta) on a (1024 x 60) GPU texture
      const fsSynthAng = `#version 300 es
        precision highp float;
        in vec2 vUv;
        out vec4 fragColor;
        uniform sampler2D uSpecTex;

        void main() {
          int k = int(gl_FragCoord.y);
          float theta = vUv.x * 6.28318530718;
          float kf = float(k);

          vec3 sum = vec3(0.0);
          float sumSmooth = 0.0;

          for (int m = 1; m <= 60; ++m) {
            float mf = float(m);
            float ang = mf * theta;
            float cs = cos(ang);
            float sn = sin(ang);
            vec3 wc = texelFetch(uSpecTex, ivec2(2 * m - 1, k), 0).rgb;
            vec3 ws = texelFetch(uSpecTex, ivec2(2 * m,     k), 0).rgb;
            vec3 term = wc * cs + ws * sn;
            sum += term;
            float w_s = exp(-0.5 * pow((mf * mf) / 196.0 + (kf * kf) / 256.0, 2.0));
            sumSmooth += term.r * w_s;
          }
          fragColor = vec4(sum, sumSmooth);
        }
      `;

      // Pass 1B: Synthesize 2D Orthogonal Cosine Radial Series on a (2048 x 2048) GPU texture
      const fsSynthRad = `#version 300 es
        precision highp float;
        in vec2 vUv;
        out vec4 fragColor;
        uniform sampler2D uAngTex;
        uniform sampler2D uSpecTex;

        const float S_CORE_FIT = 0.9365;

        void main() {
          vec2 p = (vUv - 0.5) * 2.0;
          float s = min(length(p), S_CORE_FIT);
          float theta = mod(atan(p.y, p.x) + 6.28318530718, 6.28318530718);
          float u_th = theta / 6.28318530718;
          float s_norm = s / S_CORE_FIT;

          // Guarantee C-infinity smoothness at the polar origin s = 0 without altering central basin luminance
          float originTaper = smoothstep(0.0, 0.035, s);

          vec3 m0Sum = vec3(0.0);
          float m0Smooth = 0.0;
          vec4 angTotal = vec4(0.0);

          for (int k = 0; k < 60; ++k) {
            float kf = float(k);
            float radCos = cos(kf * 3.14159265359 * s_norm);
            vec3 w0 = texelFetch(uSpecTex, ivec2(0, k), 0).rgb;
            m0Sum += w0 * radCos;
            m0Smooth += w0.r * exp(-0.5 * pow(kf / 16.0, 4.0)) * radCos;

            float v_k = (kf + 0.5) / 60.0;
            vec4 angVal = texture(uAngTex, vec2(u_th, v_k));
            angTotal += angVal * radCos;
          }

          vec3 totalRGB = m0Sum + angTotal.rgb * originTaper;
          float totalSmooth = m0Smooth + angTotal.a * originTaper;

          float L = totalRGB.r;
          float CR = totalRGB.g;
          float CB = totalRGB.b;
          float CG = -(0.2126 * CR + 0.0722 * CB) / 0.7152;
          vec3 rgb = clamp(vec3(L + CR, L + CG, L + CB), 0.0, 1.0);
          fragColor = vec4(rgb, totalSmooth);
        }
      `;

      // Pass 2: 2D Isotropic Osher-Rudin Shock-Wave Ridge Steepening on (2048 x 2048) GPU texture
      const fsShock = `#version 300 es
        precision highp float;
        in vec2 vUv;
        out vec4 fragColor;
        uniform sampler2D uInTex;

        void main() {
          vec2 p = (vUv - 0.5) * 2.0;
          float s = length(p);
          vec4 center = texture(uInTex, vUv);
          if (s >= 0.935 || s <= 0.14) {
            fragColor = center;
            return;
          }
          const float eps = 4.0 / 2048.0;
          const vec3 lumaW = vec3(0.2126, 0.7152, 0.0722);
          float lC = dot(center.rgb, lumaW);
          float lR = dot(texture(uInTex, vUv + vec2(eps, 0.0)).rgb, lumaW);
          float lL = dot(texture(uInTex, vUv - vec2(eps, 0.0)).rgb, lumaW);
          float lU = dot(texture(uInTex, vUv + vec2(0.0, eps)).rgb, lumaW);
          float lD = dot(texture(uInTex, vUv - vec2(0.0, eps)).rgb, lumaW);

          vec2 grad = vec2(lR - lL, lU - lD);
          float lap = (lR + lL + lU + lD - 4.0 * lC);
          float gMag = length(grad) + 1e-6;
          float interiorW = smoothstep(0.935, 0.900, s) * smoothstep(0.14, 0.26, s);
          float ridgeMask = smoothstep(0.004, 0.024, gMag);
          vec2 shift = -0.0014 * interiorW * ridgeMask * tanh(lap * 26.0) * (grad / gMag);
          vec3 rgbSharp = texture(uInTex, vUv + shift).rgb;
          fragColor = vec4(rgbSharp, center.a);
        }
      `;

      // Pass 3: Analytical 32-bit Surface Normal & Dispersion Mask Extraction on (2048 x 2048) GPU texture
      const fsNorm = `#version 300 es
        precision highp float;
        in vec2 vUv;
        out vec4 fragColor;
        uniform sampler2D uCoreTex;

        void main() {
          vec2 p = (vUv - 0.5) * 2.0;
          float r = length(p);
          const float eps = 12.0 / 2048.0;
          float hC = texture(uCoreTex, vUv).a;
          float hR = texture(uCoreTex, vUv + vec2(eps, 0.0)).a;
          float hL = texture(uCoreTex, vUv - vec2(eps, 0.0)).a;
          float hU = texture(uCoreTex, vUv + vec2(0.0, eps)).a;
          float hD = texture(uCoreTex, vUv - vec2(0.0, eps)).a;

          vec2 gradH = vec2(hR - hL, hU - hD) * 0.5;
          vec2 nSphere = p * 0.58;
          vec2 nxy = clamp(nSphere - gradH * 2.8, -0.86, 0.86);

          vec3 rgb = texture(uCoreTex, vUv).rgb;
          float luma = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
          float gMag = length(gradH);
          float dispMask = clamp(smoothstep(0.42, 0.88, luma) * 0.50 + smoothstep(0.015, 0.09, gMag) * 0.45, 0.0, 1.0);

          fragColor = vec4(nxy, dispMask, luma);
        }
      `;

      // Pass 4: Real-Time 4K Animated Liquid-Chrome & Per-Pixel Analytical Rim/Bezel/Halo Shader
      const fsRender = `#version 300 es
        precision highp float;

        in vec2 vUv;
        out vec4 fragColor;

        uniform sampler2D uCoreTex;
        uniform sampler2D uNormTex;
        uniform float uTime;
        uniform float uFlowAmp;
        uniform float uMetalAmp;
        uniform float uRelightAmp;
        uniform float uIridAmp;
        uniform float uHaloAmp;
        uniform vec2 uPointer;
        uniform vec2 uOrbCenter;
        uniform vec2 uOrbRadius;
        uniform vec4 uBezelL[17];
        uniform vec4 uBezelCR[17];
        uniform vec4 uBezelCB[17];
        uniform vec2 uHaloR[13];
        uniform vec2 uHaloG[13];
        uniform vec2 uHaloB[13];

        const float W24 = 0.2617993878; // 2.0 * PI / 24.0

        float evalStudioEnv(vec2 p) {
          float u = p.x;
          float v = p.y;
          float u2 = u * u;
          float v2 = v * v;
          return 0.5468
               + 0.2844 * u + 0.0884 * v
               + 0.0175 * u2 + 0.0027 * u * v + 0.1152 * v2
               - 0.4393 * u2 * u - 0.2080 * u2 * v - 0.3023 * u * v2 - 0.3974 * v2 * v;
        }

        float hash12(vec2 p) {
          vec3 p3 = fract(vec3(p.xyx) * 0.1031);
          p3 += dot(p3, p3.yzx + 33.33);
          return fract((p3.x + p3.y) * p3.z);
        }

        vec2 hash22(vec2 p) {
          vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
          p3 += dot(p3, p3.yzx + 33.33);
          return fract((p3.xx + p3.yz) * p3.zy);
        }

        // Quintic C2-continuous value noise returning vec3(dVal/dx, dVal/dy, val in [-1, 1])
        vec3 valueNoiseGrad(vec2 x) {
          vec2 i = floor(x);
          vec2 f = fract(x);
          vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
          vec2 du = 30.0 * f * f * (f * (f - 2.0) + 1.0);

          float a = hash12(i + vec2(0.0, 0.0));
          float b = hash12(i + vec2(1.0, 0.0));
          float c = hash12(i + vec2(0.0, 1.0));
          float d = hash12(i + vec2(1.0, 1.0));

          float k0 = a;
          float k1 = b - a;
          float k2 = c - a;
          float k3 = a - b - c + d;

          float val = (k0 + k1 * u.x + k2 * u.y + k3 * u.x * u.y) * 2.0 - 1.0;
          vec2 grad = 2.0 * du * vec2(k1 + k3 * u.y, k2 + k3 * u.x);
          return vec3(grad, val);
        }

        // High-frequency spatial blue-noise / triangular-PDF metallic crystal grain in [-1, 1]
        float blueMetallicDither(vec2 fragCoord) {
          float n0 = hash12(fragCoord);
          float nX = hash12(fragCoord + vec2(1.0, 0.0));
          float nY = hash12(fragCoord + vec2(0.0, 1.0));
          float nD = hash12(fragCoord + vec2(1.0, 1.0));
          // High-pass blue-noise shaping + triangular PDF
          float hp = n0 - 0.25 * (nX + nY + nD + hash12(fragCoord - vec2(1.0, 0.0)));
          float tri = (n0 + nD - 1.0);
          return clamp(hp * 1.15 + tri * 0.65, -1.0, 1.0);
        }

        // Ultra-fine advected isotropic crystalline metallic micro-grain (zero coarse orange-peel or concentric rings)
        // Returns vec3(microNormalX, microNormalY, microAlbedoGrain)
        vec3 evalMetallicMicroGrain(vec2 p_adv) {
          const mat2 rot1 = mat2(0.80, -0.60, 0.60, 0.80);
          const mat2 rot2 = mat2(-0.60, -0.80, 0.80, -0.60);
          const mat2 rot3 = mat2(0.92,  0.39, -0.39, 0.92);

          // Anti-aliased band-limiting weights based on local screen-space footprint (pxFootprint ~ 0.0036 at 1080p, ~0.0009 at 4K)
          float pxFootprint = max(length(fwidth(p_adv)), 0.00025);
          float wOct1 = smoothstep(0.0095, 0.0022, pxFootprint);
          float wOct2 = smoothstep(0.0062, 0.0014, pxFootprint);
          float wOct3 = smoothstep(0.0036, 0.0007, pxFootprint);

          // Fine bead-blasted anodized silver micro-crystals across 3 isotropic rotated scales
          vec3 n1 = valueNoiseGrad(rot1 * p_adv * 290.0 + vec2(17.3, 41.9)) * wOct1;
          vec3 n2 = valueNoiseGrad(rot2 * p_adv * 540.0 + vec2(83.1, 19.7)) * wOct2;
          vec3 n3 = valueNoiseGrad(rot3 * p_adv * 1020.0 + vec2(31.4, 67.8)) * wOct3;

          vec2 microNormal = n1.xy * 0.45 + n2.xy * 0.38 + n3.xy * 0.28;
          float microGrain = n1.z * 0.46 + n2.z * 0.38 + n3.z * 0.28;
          return vec3(microNormal, microGrain);
        }

        float evalStreamPsi(vec2 p, float t, vec2 ptr) {
          float r2 = dot(p, p);
          float r2Norm = r2 / (0.934 * 0.934);
          if (r2Norm >= 1.0) return 0.0;

          float oneMinusR4 = 1.0 - r2Norm * r2Norm;
          float env = oneMinusR4 * oneMinusR4 * oneMinusR4;

          float u = p.x;
          float v = p.y;
          float w = t * W24;

          float swirl = (0.048 * sin(2.0 * w) + 0.032 * cos(5.0 * w) + 0.020 * sin(9.0 * w)) * (1.0 - 0.30 * r2);

          float dipX = 0.046 * sin(3.0 * w) + 0.028 * cos(7.0 * w) - 0.018 * sin(11.0 * w) + ptr.x * 0.045;
          float dipY = 0.046 * cos(4.0 * w) - 0.028 * sin(5.0 * w) + 0.018 * cos(9.0 * w) + ptr.y * 0.045;
          float dipole = dipX * u + dipY * v;

          float q1 = 0.056 * sin(4.0 * w + 0.3) + 0.036 * cos(7.0 * w - 0.4);
          float q2 = 0.056 * cos(3.0 * w + 0.7) - 0.036 * sin(8.0 * w + 0.2);
          float quad = q1 * (u * u - v * v) + q2 * (2.0 * u * v);

          float o1 = 0.036 * cos(5.0 * w + 0.2) + 0.024 * sin(9.0 * w);
          float o2 = 0.036 * sin(6.0 * w + 1.0) - 0.024 * cos(11.0 * w);
          float octo = o1 * (u * u * u - 3.0 * u * v * v) + o2 * (3.0 * u * u * v - v * v * v);

          vec2 c1 = vec2(-0.34 + 0.24 * sin(2.0 * w) + 0.10 * cos(5.0 * w),
                          0.05 + 0.28 * cos(3.0 * w) - 0.10 * sin(7.0 * w));
          vec2 c2 = vec2( 0.28 + 0.24 * cos(3.0 * w) - 0.10 * sin(4.0 * w),
                         -0.14 + 0.26 * sin(2.0 * w) + 0.12 * cos(5.0 * w));
          vec2 c3 = vec2( 0.02 + 0.30 * sin(4.0 * w + 1.2),
                          0.34 + 0.20 * cos(5.0 * w - 0.7));

          vec2 d1 = p - c1;
          vec2 d2 = p - c2;
          vec2 d3 = p - c3;

          float v1 = (0.042 * sin(5.0 * w + 0.4) + 0.026 * cos(8.0 * w)) * exp(-dot(d1, d1) * 2.2);
          float v2 = (0.040 * cos(4.0 * w + 1.1) - 0.025 * sin(7.0 * w)) * exp(-dot(d2, d2) * 2.2);
          float v3 = (0.038 * sin(6.0 * w - 0.5) + 0.024 * cos(9.0 * w)) * exp(-dot(d3, d3) * 2.4);

          return env * (swirl + dipole + quad + octo + v1 + v2 + v3);
        }

        vec2 evalVelocity(vec2 p, float t, vec2 ptr) {
          const float eps = 0.0025;
          float dpsi_dx = (evalStreamPsi(p + vec2(eps, 0.0), t, ptr) - evalStreamPsi(p - vec2(eps, 0.0), t, ptr)) / (2.0 * eps);
          float dpsi_dy = (evalStreamPsi(p + vec2(0.0, eps), t, ptr) - evalStreamPsi(p - vec2(0.0, eps), t, ptr)) / (2.0 * eps);
          return vec2(dpsi_dy, -dpsi_dx);
        }

        vec2 computeIncompressibleFlow(vec2 p, float t, float flowAmp, vec2 ptr) {
          float r2 = dot(p, p);
          float r2Norm = r2 / (0.934 * 0.934);
          if (r2Norm >= 1.0 || flowAmp <= 0.0001) return vec2(0.0);

          float oneMinusR4 = 1.0 - r2Norm * r2Norm;
          float env = oneMinusR4 * oneMinusR4;
          float w = t * W24;

          vec2 v1 = evalVelocity(p, t, ptr);
          vec2 p_mid = p - 0.5 * flowAmp * v1;
          vec2 v2 = evalVelocity(p_mid, t, ptr);
          vec2 p_adv = p - flowAmp * v2;

          float rotEnvelope = env * (1.0 - 0.32 * r2);
          float dTheta = flowAmp * rotEnvelope * (
            0.16 * sin(2.0 * w) +
            0.11 * cos(5.0 * w - 1.3 * r2) +
            0.07 * sin(7.0 * w + 0.5) +
            ptr.x * 0.14
          );
          float cs = cos(dTheta);
          float sn = sin(dTheta);
          p_adv = vec2(cs * p_adv.x - sn * p_adv.y, sn * p_adv.x + cs * p_adv.y);

          float breath = flowAmp * env * (1.0 - r2Norm) * (
            0.058 * sin(3.0 * w + 0.4) +
            0.036 * cos(7.0 * w - 0.3)
          );
          float axAngle = 1.5 * w;
          vec2 ax1 = vec2(cos(axAngle), sin(axAngle));
          vec2 ax2 = vec2(-ax1.y, ax1.x);
          float p_ax1 = dot(p_adv, ax1);
          float p_ax2 = dot(p_adv, ax2);
          float quadScale = flowAmp * env * (0.046 * cos(4.0 * w) + 0.028 * sin(9.0 * w));

          p_adv += p_adv * breath + (ax1 * p_ax1 - ax2 * p_ax2) * quadScale;
          return p_adv - p;
        }

        vec3 computeWaveNormalAndHeight(vec2 p, float t, vec2 ptr) {
          float r2 = dot(p, p);
          float r2Norm = r2 / (0.934 * 0.934);
          if (r2Norm >= 1.0) return vec3(0.0);
          float oneMinusR4 = 1.0 - r2Norm * r2Norm;
          float env = oneMinusR4 * oneMinusR4;

          float w = t * W24;
          vec2 k1 = 2.15 * vec2(cos(w + 0.2), sin(w + 0.2));
          vec2 k2 = 1.95 * vec2(cos(-2.0 * w + 1.4), sin(-2.0 * w + 1.4));
          vec2 k3 = 2.35 * vec2(cos(3.0 * w + 2.7), sin(3.0 * w + 2.7));
          vec2 k4 = 1.65 * vec2(cos(-w + 3.8), sin(-w + 3.8));

          float p1 = dot(p, k1) - 7.0 * w;
          float p2 = dot(p, k2) - 5.0 * w + 1.1;
          float p3 = dot(p, k3) + 9.0 * w + 0.5;
          float p4 = dot(p, k4) - 11.0 * w + 2.3;

          float h = 0.048 * sin(p1) + 0.042 * cos(p2) + 0.034 * sin(p3) + 0.026 * cos(p4);
          vec2 grad_h = 0.048 * cos(p1) * k1
                      - 0.042 * sin(p2) * k2
                      + 0.034 * cos(p3) * k3
                      - 0.026 * sin(p4) * k4;

          return vec3(-grad_h.x * env, -grad_h.y * env, h * env);
        }

        float evaluateChromeSpecular(vec3 N, vec3 L1, vec3 L2, vec3 L3, float metalBoost) {
          vec3 V = vec3(0.0, 0.0, 1.0);
          vec3 H1 = normalize(L1 + V);
          vec3 H2 = normalize(L2 + V);
          vec3 H3 = normalize(L3 + V);

          float ndh1 = max(0.0, dot(N, H1));
          float ndh2 = max(0.0, dot(N, H2));
          float ndh3 = max(0.0, dot(N, H3));

          float spec1 = 0.30 * pow(ndh1, 5.0) + 0.26 * pow(ndh1, 18.0) + 0.22 * metalBoost * pow(ndh1, 52.0);
          float spec2 = 0.26 * pow(ndh2, 7.0) + 0.22 * pow(ndh2, 22.0) + 0.20 * metalBoost * pow(ndh2, 60.0);
          float spec3 = 0.22 * pow(ndh3, 5.0) + 0.18 * pow(ndh3, 16.0) + 0.16 * metalBoost * pow(ndh3, 48.0);
          return spec1 + spec2 + spec3;
        }

        float softMetallicLightCurve(float rawDelta) {
          if (rawDelta >= 0.0) {
            return 0.24 * tanh(rawDelta / 0.24);
          } else {
            return 0.070 * tanh(rawDelta / 0.070);
          }
        }

        vec3 evaluateThinFilmDispersion(vec3 N_live, vec3 N_rest, vec2 p, float dispMask, float t) {
          float w = t * W24;
          vec2 rotDir = vec2(cos(2.0 * w), sin(2.0 * w));
          float angleShift = clamp(dot(N_live.xy - N_rest.xy, vec2(0.75, -0.66)), -0.35, 0.35);
          float filmPhase = 2.5 * dot(p, rotDir) - 7.0 * w + 4.4 * dot(N_live.xy, vec2(0.6, -0.8));

          vec3 iceCyan     = vec3(-0.11,  0.075, 0.195);
          vec3 deepCobalt  = vec3(-0.12, -0.010, 0.200);
          vec3 violetGlow  = vec3( 0.065,-0.025, 0.150);
          vec3 aquaMint    = vec3(-0.08,  0.095, 0.160);
          vec3 pureSpec    = vec3( 0.14,  0.17,  0.21);

          float paletteMix = 0.5 + 0.5 * sin(3.0 * w + p.x * 1.4);
          vec3 primaryBand   = mix(iceCyan, aquaMint, paletteMix);
          vec3 secondaryBand = mix(violetGlow, deepCobalt, 0.5 + 0.5 * cos(5.0 * w - p.y * 1.4));

          float osc1 = sin(filmPhase);
          float osc2 = cos(filmPhase * 1.15 + 4.0 * w + 0.8);
          float ridgeGlint = pow(0.5 + 0.5 * sin(filmPhase - 0.5), 3.0) - 0.25;

          float r2Norm = dot(p, p) / (0.934 * 0.934);
          float env = max(0.0, 1.0 - r2Norm * r2Norm);
          float strength = dispMask * env;

          return (primaryBand * osc1 * 0.65 + secondaryBand * osc2 * 0.45 + pureSpec * ridgeGlint * 0.75 + primaryBand * angleShift * 1.05) * strength;
        }

        // Per-pixel analytical evaluation of the outer glass/chrome shell bezel (0.9385 <= r <= 0.9985)
        vec3 evalAnalyticalBezel(float r, float theta) {
          float tau = clamp((r - 0.9385) / (0.9985 - 0.9385), 0.0, 1.0);
          vec4 phi = vec4(
            1.0,
            tau,
            tau * tau,
            exp(-0.5 * pow((tau - 0.92) / 0.065, 2.0))
          );
          vec4 sumL  = uBezelL[0];
          vec4 sumCR = uBezelCR[0];
          vec4 sumCB = uBezelCB[0];
          for (int m = 1; m <= 8; ++m) {
            float ang = float(m) * theta;
            float cs = cos(ang);
            float sn = sin(ang);
            sumL  += uBezelL[2 * m - 1]  * cs + uBezelL[2 * m]  * sn;
            sumCR += uBezelCR[2 * m - 1] * cs + uBezelCR[2 * m] * sn;
            sumCB += uBezelCB[2 * m - 1] * cs + uBezelCB[2 * m] * sn;
          }
          float L  = dot(sumL,  phi);
          float CR = dot(sumCR, phi);
          float CB = dot(sumCB, phi);
          float CG = -(0.2126 * CR + 0.0722 * CB) / 0.7152;
          // Razor-sharp 4K specular chrome rim wire at r = 0.9960
          float outerWire = 0.046 * exp(-0.5 * pow((r - 0.9960) / 0.0018, 2.0));
          return clamp(vec3(L + CR + outerWire, L + CG + outerWire, L + CB + outerWire * 1.08), 0.0, 1.0);
        }

        // Per-pixel analytical evaluation of the outer atmospheric halo (r > 0.9985)
        vec3 evalAnalyticalHalo(float r, float theta) {
          float ds = max(r - 0.9985, 0.0);
          vec2 phi = vec2(exp(-16.0 * ds), exp(-42.0 * ds));
          vec2 sumR = uHaloR[0];
          vec2 sumG = uHaloG[0];
          vec2 sumB = uHaloB[0];
          for (int m = 1; m <= 6; ++m) {
            float ang = float(m) * theta;
            float cs = cos(ang);
            float sn = sin(ang);
            sumR += uHaloR[2 * m - 1] * cs + uHaloR[2 * m] * sn;
            sumG += uHaloG[2 * m - 1] * cs + uHaloG[2 * m] * sn;
            sumB += uHaloB[2 * m - 1] * cs + uHaloB[2 * m] * sn;
          }
          float taper = smoothstep(1.116, 1.068, r);
          return clamp(vec3(dot(sumR, phi), dot(sumG, phi), dot(sumB, phi)) * taper, 0.0, 1.0);
        }

        void main() {
          vec2 p = (vUv - uOrbCenter) / uOrbRadius;
          float r = length(p);
          float theta = mod(atan(p.y, p.x) + 6.28318530718, 6.28318530718);
          float w = uTime * W24;

          // Strictly pure #000000 black outside the orb's soft circular halo
          if (r >= 1.118) {
            fragColor = vec4(0.0, 0.0, 0.0, 1.0);
            return;
          }

          float flowRamp = smoothstep(0.0, 1.20, uTime);
          float effFlow    = uFlowAmp    * flowRamp;
          float effRelight = uRelightAmp;
          float effIrid    = uIridAmp;
          float effHalo    = uHaloAmp;

          // 1. Evaluate Core (r <= 0.942) from GPU-synthesized & shock-super-resolved harmonic field
          vec3 coreColor = vec3(0.0);
          if (r <= 0.944) {
            vec2 flowDisp = computeIncompressibleFlow(p, uTime, effFlow, uPointer);
            vec2 p_adv = p + flowDisp;
            float r_adv = length(p_adv);
            if (r_adv > 0.9355) {
              p_adv *= (0.9355 / r_adv);
            }
            vec2 uv_core = p_adv * 0.5 + 0.5;
            coreColor = texture(uCoreTex, uv_core).rgb;

            vec4 normData = texture(uNormTex, uv_core);
            vec2 nxy_rest = normData.rg;
            float nz_rest = sqrt(max(0.04, 1.0 - dot(nxy_rest, nxy_rest)));
            vec3 N_rest = normalize(vec3(nxy_rest, nz_rest));
            float dispMask = normData.b;

            vec3 waveNH = computeWaveNormalAndHeight(p, uTime, uPointer);

            // Evaluate ultra-fine advected isotropic metallic micro-crystals
            vec3 microFacet = evalMetallicMicroGrain(p_adv);
            vec2 microNormPerturb = microFacet.xy * (0.0055 * uMetalAmp);
            vec3 N_live = normalize(N_rest + vec3(waveNH.xy * 0.65 * effRelight + microNormPerturb, 0.0));
            vec3 N_rest_faceted = normalize(N_rest + vec3(microNormPerturb * 0.50, 0.0));

            // Metallic Chrome Surface Enhancement
            float r2Norm = min(dot(p, p) / (0.9385 * 0.9385), 1.0);
            float metalEnv = max(0.0, 1.0 - r2Norm * r2Norm);

            float luma = dot(coreColor, vec3(0.2126, 0.7152, 0.0722));
            vec3 chromaDiff = coreColor - luma;

            // Boundary-preserving monotonic S-curve chrome contrast + cool platinum-steel midtones
            float sCurveLuma = clamp(luma - 0.052 * uMetalAmp * sin(6.2831853 * luma), 0.0, 1.0);
            vec3 steelTint = mix(vec3(0.93, 0.97, 1.04), vec3(1.00, 1.01, 1.02), smoothstep(0.40, 0.86, sCurveLuma));
            vec3 metallicBase = clamp((sCurveLuma * steelTint) + chromaDiff * (1.0 + 0.12 * uMetalAmp), 0.0, 1.0);

            coreColor = mix(coreColor, metallicBase, clamp(uMetalAmp * 0.62, 0.0, 1.0));

            // Accumulate all specular/Fresnel/dispersion boosts and apply Filmic Highlight Headroom Compression (zero flat white clipping!)
            vec3 totalBoost = vec3(0.0);

            // Physical bead-blasted anodized silver micro-grain response (strongest in metallic midtones & specular grazing slopes)
            float midtoneGrainEnv = smoothstep(0.04, 0.28, luma) * (1.0 - 0.32 * smoothstep(0.86, 0.98, luma));
            float advectedGrain = microFacet.z * 0.0115 * uMetalAmp * midtoneGrainEnv * metalEnv;
            totalBoost += vec3(0.94, 0.98, 1.04) * advectedGrain;

            // Schlick grazing Fresnel metallic rim sheen along curved interior folds
            float fresnel = pow(clamp(1.0 - N_live.z, 0.0, 1.0), 2.5) * 0.052 * uMetalAmp * metalEnv;
            totalBoost += vec3(0.88, 0.95, 1.04) * fresnel;

            // Smooth studio horizon reflection sheen across curved normals
            float envSheen = sin(N_live.y * 3.8 - N_live.x * 2.4 + 1.1) * 0.018 * uMetalAmp * metalEnv * (1.0 - smoothstep(0.72, 0.94, luma));
            totalBoost += vec3(0.92, 0.97, 1.04) * envSheen;

            // Inner-core grazing rim highlight wire right before the 0.9385 glass shell boundary
            float innerRimWire = 0.024 * exp(-0.5 * pow((r - 0.9348) / 0.0025, 2.0));
            totalBoost += vec3(0.94, 0.98, 1.05) * innerRimWire;

            if (effRelight > 0.0001 || effIrid > 0.0001 || effFlow > 0.0001) {
              vec3 L1_rest = normalize(vec3(-0.36, -0.52, 0.77));
              vec3 L2_rest = normalize(vec3( 0.52, -0.16, 0.84));
              vec3 L3_rest = normalize(vec3( 0.06,  0.54, 0.84));

              vec2 ptrLight = uPointer * 0.30;
              vec3 L1_live = normalize(L1_rest + vec3(
                0.24 * sin(3.0 * w) + 0.14 * cos(7.0 * w) + ptrLight.x,
                0.22 * cos(4.0 * w) + 0.12 * sin(9.0 * w) + ptrLight.y,
                0.0
              ) * effRelight);
              vec3 L2_live = normalize(L2_rest + vec3(
                -0.22 * cos(5.0 * w + 0.6) + 0.14 * sin(3.0 * w) + ptrLight.x,
                 0.24 * sin(4.0 * w + 0.6) - 0.12 * cos(7.0 * w) + ptrLight.y,
                 0.0
              ) * effRelight);
              vec3 L3_live = normalize(L3_rest + vec3(
                 0.24 * sin(7.0 * w + 1.2) - 0.14 * cos(2.0 * w),
                -0.22 * cos(5.0 * w + 0.8) + 0.14 * sin(11.0 * w),
                 0.0
              ) * effRelight);

              float specLive = evaluateChromeSpecular(N_live, L1_live, L2_live, L3_live, uMetalAmp);
              float specRest = evaluateChromeSpecular(N_rest_faceted, L1_rest, L2_rest, L3_rest, uMetalAmp);
              float deltaSpec = (specLive - specRest) * effRelight;

              // Subtle micro-crystalline specular shimmer where studio lights graze the liquid-metal folds
              float facetSparkle = (specLive - evaluateChromeSpecular(N_rest, L1_live, L2_live, L3_live, uMetalAmp)) * 0.22;

              float envHere = evalStudioEnv(p);
              float envAdv  = evalStudioEnv(p_adv);
              float deltaEnv = (envHere - envAdv) * 0.42 * metalEnv;

              float rawLightDelta = deltaSpec * 0.68 + facetSparkle + deltaEnv + waveNH.z * 0.52 * effRelight;
              float safeLightDelta = softMetallicLightCurve(rawLightDelta);

              totalBoost += vec3(0.94, 0.98, 1.04) * safeLightDelta;
              vec3 iridShift = evaluateThinFilmDispersion(N_live, N_rest, p_adv, dispMask, uTime);
              totalBoost += iridShift * (0.56 * effIrid);
            }

            // Filmic highlight shoulder rolloff: preserves 3D gradient curvature inside bright chrome domes
            vec3 posBoost = max(totalBoost, vec3(0.0));
            vec3 negBoost = min(totalBoost, vec3(0.0));
            vec3 headroom = max(vec3(0.992) - coreColor, vec3(0.035));
            coreColor = clamp(coreColor + headroom * tanh(posBoost / headroom) + negBoost, 0.0, 1.0);
          }

          // 2. Evaluate Analytical Outer Glass/Chrome Shell Bezel (0.934 <= r <= 1.002)
          vec3 sphereColor = coreColor;
          if (r >= 0.934 && r <= 1.002) {
            vec3 bezelColor = evalAnalyticalBezel(r, theta);
            // Tactile machined satin-titanium / frosted-glass micro-grain on the outer containment shell
            float bezelTex1 = valueNoiseGrad(p * 480.0 + vec2(19.4, 73.1)).z;
            float bezelTex2 = valueNoiseGrad(vec2((p.x - p.y) * 380.0, (r - 0.9385) * 920.0)).z;
            float bezelGrain = (bezelTex1 * 0.65 + bezelTex2 * 0.35) * 0.0105 * uMetalAmp;
            bezelColor = clamp(bezelColor + vec3(0.94, 0.98, 1.04) * bezelGrain, 0.0, 1.0);

            if (effHalo > 0.0001) {
              float outerRimMask = exp(-pow((r - 0.9955) / 0.0050, 2.0));
              float innerWallMask = exp(-pow((r - 0.9385) / 0.0060, 2.0));
              float glassWallMask = smoothstep(0.938, 0.948, r) * smoothstep(0.998, 0.985, r);

              float orbitGlint1 = pow(0.5 + 0.5 * cos(theta - 3.0 * w + 0.8), 4.0);
              float orbitGlint2 = pow(0.5 + 0.5 * sin(theta + 5.0 * w - 0.5), 5.0);
              float rimPulse = (orbitGlint1 * 0.78 + orbitGlint2 * 0.58) - 0.40;

              vec3 rimHighlight = vec3(0.86, 0.95, 1.05) * (outerRimMask * 0.14 + innerWallMask * 0.12) * rimPulse;
              float causticWave = sin(theta * 4.0 - 7.0 * w + r * 20.0) * 0.038;
              vec3 glassCaustic = vec3(0.52, 0.84, 1.05) * glassWallMask * causticWave;
              bezelColor += (rimHighlight + glassCaustic) * effHalo;
            }
            // Razor-sharp 4K analytical bevel at r = 0.9385
            float coreMask = smoothstep(0.9385 + 0.0020, 0.9385 - 0.0020, r);
            sphereColor = mix(bezelColor, coreColor, coreMask);
          }

          // 3. Evaluate Analytical Outer Atmospheric Halo & True 1-Pixel Sub-Pixel Silhouette Edge at r = 0.9985
          vec3 finalColor = sphereColor;
          if (r >= 0.995) {
            vec3 haloColor = evalAnalyticalHalo(r, theta);
            if (effHalo > 0.0001) {
              float radialFade = smoothstep(1.116, 1.004, r);
              float haloZone = exp(-max(0.0, r - 0.9985) * 18.0) * radialFade;
              float haloBreath = 0.5 * sin(4.0 * w - r * 8.0)
                               + 0.5 * cos(theta * 3.0 - 5.0 * w);
              haloColor += vec3(0.55, 0.82, 1.05) * haloZone * haloBreath * 0.062 * effHalo;
            }
            float aa = max(fwidth(r) * 0.75, 0.00045);
            float sphereMask = smoothstep(0.9985 + aa, 0.9985 - aa, r);
            finalColor = mix(haloColor, sphereColor, sphereMask);
          }

          // 4. Post-Processed Metallic Crystalline Micro-Grain at Native Viewport/4K Resolution
          // Luminance-coupled anodized silver grain (strictly zero on pure #000000 black background)
          float finalLuma = dot(finalColor, vec3(0.2126, 0.7152, 0.0722));
          float lumaResponse = smoothstep(0.02, 0.24, finalLuma) * (1.0 - 0.25 * smoothstep(0.88, 0.995, finalLuma));
          float fineCrystal = blueMetallicDither(gl_FragCoord.xy);
          float medCrystal  = valueNoiseGrad(gl_FragCoord.xy * 0.58 + p * 65.0).z;
          float postGrain   = (fineCrystal * 0.65 + medCrystal * 0.35) * 0.0110 * max(uMetalAmp, 0.8) * lumaResponse;
          float orbMask     = smoothstep(1.06, 0.992, r);
          finalColor = clamp(finalColor + vec3(0.95, 0.98, 1.04) * (postGrain * orbMask), 0.0, 1.0);

          fragColor = vec4(finalColor, 1.0);
        }
      `;

      const progSynthAng = createProgram(vsFbo, fsSynthAng);
      const progSynthRad = createProgram(vsFbo, fsSynthRad);
      const progShock    = createProgram(vsFbo, fsShock);
      const progNorm     = createProgram(vsFbo, fsNorm);
      const progRender   = createProgram(vsScreen, fsRender);

      const quadBuf = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, quadBuf);
      gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([
        -1, -1,  1, -1, -1,  1,
        -1,  1,  1, -1,  1,  1
      ]), gl.STATIC_DRAW);

      function bindQuad(prog) {
        gl.useProgram(prog);
        gl.bindBuffer(gl.ARRAY_BUFFER, quadBuf);
        const loc = gl.getAttribLocation(prog, 'aPosition');
        gl.enableVertexAttribArray(loc);
        gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
      }

      // Decode mathematical spectral harmonic coefficients (Float32) into RGBA32F GPU texture
      function createSpectralHarmonicTexture() {
        const rawBytes = Uint8Array.from(atob(ORB_SPEC_F32_B64), c => c.charCodeAt(0));
        const rgbF32 = new Float32Array(rawBytes.buffer);
        const numTexels = ORB_SPEC_K * (2 * ORB_SPEC_M + 1); // 60 * 121
        const rgbaF32 = new Float32Array(numTexels * 4);
        for (let i = 0; i < numTexels; ++i) {
          rgbaF32[4 * i]     = rgbF32[3 * i];
          rgbaF32[4 * i + 1] = rgbF32[3 * i + 1];
          rgbaF32[4 * i + 2] = rgbF32[3 * i + 2];
          rgbaF32[4 * i + 3] = 1.0;
        }
        const tex = gl.createTexture();
        gl.bindTexture(gl.TEXTURE_2D, tex);
        gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA32F, 2 * ORB_SPEC_M + 1, ORB_SPEC_K, 0, gl.RGBA, gl.FLOAT, rgbaF32);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        return tex;
      }

      function createFBO(w, h, wrapS = gl.CLAMP_TO_EDGE) {
        const tex = gl.createTexture();
        gl.bindTexture(gl.TEXTURE_2D, tex);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, w, h, 0, gl.RGBA, gl.HALF_FLOAT, null);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, wrapS);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);

        const fbo = gl.createFramebuffer();
        gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
        gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex, 0);
        return { fbo, tex, w, h };
      }

      // Execute GPU Spectral Synthesis & Shock-Wave Super-Resolution Pipeline on Startup
      const texSpec = createSpectralHarmonicTexture();
      const fboAng   = createFBO(1024, 60, gl.REPEAT);
      const fboCore0 = createFBO(2048, 2048);
      const fboCore1 = createFBO(2048, 2048);
      const fboNorm  = createFBO(2048, 2048);

      // 1A: Angular Harmonics (1024 x 60)
      gl.bindFramebuffer(gl.FRAMEBUFFER, fboAng.fbo);
      gl.viewport(0, 0, fboAng.w, fboAng.h);
      bindQuad(progSynthAng);
      gl.activeTexture(gl.TEXTURE0);
      gl.bindTexture(gl.TEXTURE_2D, texSpec);
      gl.uniform1i(gl.getUniformLocation(progSynthAng, 'uSpecTex'), 0);
      gl.drawArrays(gl.TRIANGLES, 0, 6);

      // 1B: Radial Cosine Synthesis (2048 x 2048)
      gl.bindFramebuffer(gl.FRAMEBUFFER, fboCore0.fbo);
      gl.viewport(0, 0, fboCore0.w, fboCore0.h);
      bindQuad(progSynthRad);
      gl.activeTexture(gl.TEXTURE0);
      gl.bindTexture(gl.TEXTURE_2D, fboAng.tex);
      gl.uniform1i(gl.getUniformLocation(progSynthRad, 'uAngTex'), 0);
      gl.activeTexture(gl.TEXTURE1);
      gl.bindTexture(gl.TEXTURE_2D, texSpec);
      gl.uniform1i(gl.getUniformLocation(progSynthRad, 'uSpecTex'), 1);
      gl.drawArrays(gl.TRIANGLES, 0, 6);

      // 2: Smooth Osher-Rudin Shock-Wave Ridge Steepening (2048 x 2048)
      bindQuad(progShock);
      gl.uniform1i(gl.getUniformLocation(progShock, 'uInTex'), 0);
      gl.bindFramebuffer(gl.FRAMEBUFFER, fboCore1.fbo);
      gl.viewport(0, 0, fboCore1.w, fboCore1.h);
      gl.activeTexture(gl.TEXTURE0);
      gl.bindTexture(gl.TEXTURE_2D, fboCore0.tex);
      gl.drawArrays(gl.TRIANGLES, 0, 6);
      const srcCore = fboCore1;

      // 3: Analytical 32-Bit Surface Normals & Dispersion Mask (2048 x 2048)
      gl.bindFramebuffer(gl.FRAMEBUFFER, fboNorm.fbo);
      gl.viewport(0, 0, fboNorm.w, fboNorm.h);
      bindQuad(progNorm);
      gl.activeTexture(gl.TEXTURE0);
      gl.bindTexture(gl.TEXTURE_2D, srcCore.tex);
      gl.uniform1i(gl.getUniformLocation(progNorm, 'uCoreTex'), 0);
      gl.drawArrays(gl.TRIANGLES, 0, 6);

      gl.bindFramebuffer(gl.FRAMEBUFFER, null);

      const uniforms = {
        uCoreTex: gl.getUniformLocation(progRender, 'uCoreTex'),
        uNormTex: gl.getUniformLocation(progRender, 'uNormTex'),
        uTime: gl.getUniformLocation(progRender, 'uTime'),
        uFlowAmp: gl.getUniformLocation(progRender, 'uFlowAmp'),
        uMetalAmp: gl.getUniformLocation(progRender, 'uMetalAmp'),
        uRelightAmp: gl.getUniformLocation(progRender, 'uRelightAmp'),
        uIridAmp: gl.getUniformLocation(progRender, 'uIridAmp'),
        uHaloAmp: gl.getUniformLocation(progRender, 'uHaloAmp'),
        uPointer: gl.getUniformLocation(progRender, 'uPointer'),
        uOrbCenter: gl.getUniformLocation(progRender, 'uOrbCenter'),
        uOrbRadius: gl.getUniformLocation(progRender, 'uOrbRadius'),
        uBezelL: gl.getUniformLocation(progRender, 'uBezelL'),
        uBezelCR: gl.getUniformLocation(progRender, 'uBezelCR'),
        uBezelCB: gl.getUniformLocation(progRender, 'uBezelCB'),
        uHaloR: gl.getUniformLocation(progRender, 'uHaloR'),
        uHaloG: gl.getUniformLocation(progRender, 'uHaloG'),
        uHaloB: gl.getUniformLocation(progRender, 'uHaloB')
      };

      const bezelLFlat  = new Float32Array(ORB_BEZEL_L.flat());
      const bezelCRFlat = new Float32Array(ORB_BEZEL_CR.flat());
      const bezelCBFlat = new Float32Array(ORB_BEZEL_CB.flat());
      const haloRFlat   = new Float32Array(ORB_HALO_R.flat());
      const haloGFlat   = new Float32Array(ORB_HALO_G.flat());
      const haloBFlat   = new Float32Array(ORB_HALO_B.flat());

      function drawShaderFrame() {
        gl.bindFramebuffer(gl.FRAMEBUFFER, null);
        gl.viewport(0, 0, canvasShader.width, canvasShader.height);
        bindQuad(progRender);

        gl.activeTexture(gl.TEXTURE0);
        gl.bindTexture(gl.TEXTURE_2D, srcCore.tex);
        gl.uniform1i(uniforms.uCoreTex, 0);

        gl.activeTexture(gl.TEXTURE1);
        gl.bindTexture(gl.TEXTURE_2D, fboNorm.tex);
        gl.uniform1i(uniforms.uNormTex, 1);

        gl.uniform1f(uniforms.uTime, state.time);
        gl.uniform1f(uniforms.uFlowAmp, state.flowAmp);
        gl.uniform1f(uniforms.uMetalAmp, state.metalAmp);
        gl.uniform1f(uniforms.uRelightAmp, state.relightAmp);
        gl.uniform1f(uniforms.uIridAmp, state.iridAmp);
        gl.uniform1f(uniforms.uHaloAmp, state.haloAmp);
        gl.uniform2f(uniforms.uPointer, state.pointerX, state.pointerY);

        if (customW && customH) {
          const rad = customRad !== null ? customRad : 0.382;
          gl.uniform2f(uniforms.uOrbCenter, 0.5, 0.5);
          gl.uniform2f(uniforms.uOrbRadius, rad, rad);
        } else {
          gl.uniform2f(uniforms.uOrbCenter, 496.55 / 992.0, 530.80 / 1066.0);
          gl.uniform2f(uniforms.uOrbRadius, 373.50 / 992.0, 381.90 / 1066.0);
        }

        gl.uniform4fv(uniforms.uBezelL, bezelLFlat);
        gl.uniform4fv(uniforms.uBezelCR, bezelCRFlat);
        gl.uniform4fv(uniforms.uBezelCB, bezelCBFlat);
        gl.uniform2fv(uniforms.uHaloR, haloRFlat);
        gl.uniform2fv(uniforms.uHaloG, haloGFlat);
        gl.uniform2fv(uniforms.uHaloB, haloBFlat);

        gl.drawArrays(gl.TRIANGLES, 0, 6);
      }

      

    const onMove = (e) => {
      const rect = canvasShader.getBoundingClientRect();
      if (!rect.width || !rect.height) return;
      state.targetPointerX = Math.max(-1, Math.min(1, ((e.clientX - rect.left) / rect.width) * 2.0 - 1.0));
      state.targetPointerY = Math.max(-1, Math.min(1, ((e.clientY - rect.top) / rect.height) * 2.0 - 1.0));
    };
    const onLeave = () => {
      state.targetPointerX = 0.0;
      state.targetPointerY = 0.0;
    };
    window.addEventListener("pointermove", onMove, { passive: true });
    canvasShader.addEventListener("pointerleave", onLeave, { passive: true });

    // 60 FPS animated navbar mark (tab favicon stays static /favicon.png)
    let navCanvas = null;
    let navCtx = null;

    if (typeof document !== "undefined") {
      const navImg = document.querySelector(".orb-nav-logo-img");
      if (navImg && navImg.tagName === "IMG" && navImg.parentNode) {
        const dpr = Math.min(window.devicePixelRatio || 1, 2);
        navCanvas = document.createElement("canvas");
        navCanvas.width = Math.round(24 * dpr);
        navCanvas.height = Math.round(24 * dpr);
        navCanvas.className = navImg.className;
        navCanvas.setAttribute("aria-label", "Orb");
        navCtx = navCanvas.getContext("2d");
        navImg.parentNode.replaceChild(navCanvas, navImg);
      } else if (navImg && navImg.tagName === "CANVAS") {
        navCanvas = navImg;
        navCtx = navCanvas.getContext("2d");
      }
    }

    function updateNavMarkFromShader() {
      if (document.hidden || !navCtx || !navCanvas) return;
      try {
        const w = canvasShader.width;
        const h = canvasShader.height;
        const rad = customRad !== null ? customRad : 0.382;
        const cropHalf = rad * w * 1.015;
        const sx = Math.max(0, w * 0.5 - cropHalf);
        const sy = Math.max(0, h * 0.5 - cropHalf);
        const sw = Math.min(w - sx, cropHalf * 2.0);
        const sh = Math.min(h - sy, cropHalf * 2.0);

        const nw = navCanvas.width;
        const nh = navCanvas.height;
        navCtx.clearRect(0, 0, nw, nh);
        navCtx.save();
        navCtx.beginPath();
        navCtx.arc(nw * 0.5, nh * 0.5, nw * 0.48, 0, Math.PI * 2);
        navCtx.closePath();
        navCtx.clip();
        navCtx.drawImage(canvasShader, sx, sy, sw, sh, 0, 0, nw, nh);
        navCtx.restore();
      } catch (_) {}
    }

    let rafId = 0;
    let lastTs = performance.now();
    let destroyed = false;

    function renderFrame(now) {
      if (destroyed) return;
      const dt = Math.min(0.05, (now - lastTs) * 0.001);
      lastTs = now;
      if (!state.paused) {
        state.time += dt * state.speed;
      }
      state.pointerX += (state.targetPointerX - state.pointerX) * 0.08;
      state.pointerY += (state.targetPointerY - state.pointerY) * 0.08;
      drawShaderFrame();
      updateNavMarkFromShader();
      rafId = requestAnimationFrame(renderFrame);
    }

    drawShaderFrame();
    updateNavMarkFromShader();
    rafId = requestAnimationFrame(renderFrame);

    return {
      destroy() {
        destroyed = true;
        cancelAnimationFrame(rafId);
        window.removeEventListener("pointermove", onMove);
        canvasShader.removeEventListener("pointerleave", onLeave);
      }
    };
  };
})();
