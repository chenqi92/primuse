// 「动态歌词」背景场景的 Metal 着色器源码。
//
// 运行时交给系统自带的 Metal 编译器（`MTLDevice.makeLibrary(source:)`）编一次：工程里不放 .metal 文件，
// 打包机就不需要另装 Xcode 的 Metal Toolchain。每个场景一个片元函数，共用一个铺满画面的顶点函数。
//
// `KineticUniforms` 必须和 `ImmersiveKineticUniforms`（ImmersiveKineticMetalBackdrop.swift）逐字段一致，
// 全部用 float4，两边的对齐方式不会有分歧。

import PrimuseKit

enum ImmersiveKineticShaderSource {
    static let vertexFunction = "kinetic_vertex"

    static func fragmentFunction(for scene: ImmersiveKineticScene) -> String {
        "kinetic_\(scene.rawValue)"
    }

    static let source = #"""
#include <metal_stdlib>
using namespace metal;

struct KineticUniforms {
    float4 frame;    // x 宽（像素）, y 高（像素）, z 动画时钟（秒）, w 播放进度 0…1
    float4 drive;    // x 热闹程度, y 低频, z 鼓点包络, w 响度排位
    float4 drive2;   // x 高频起音, y 闪电亮度, z 进高潮的程度 0…1（渐变）, w 这首歌的种子 0…1
    float4 motion;   // x 曲速里程, y 闪电种子, z 动效幅度, w 保留
    float4 colorA;   // 专辑主色
    float4 colorB;   // 专辑辅色
    float4 extra;    // x 副歌暖光亮度, y 保留, z 背景推近倍数, w 保留
    float4 drive3;   // x 圆滑的鼓点（管位置、角度）, y 流动时钟, z 里程每秒走多少, w 保留
    float4 events[8];// xy 落点 0…1, z 发生时刻, w 力度（0 为空）
};

struct KineticVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex KineticVertexOut kinetic_vertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    KineticVertexOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(p.x, 1.0 - p.y);
    return out;
}

// ---- 公共 ----

static float hash11(float n) {
    return fract(sin(n * 12.9898) * 43758.5453);
}

static float hash21(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

static float noise2(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static float fbm(float2 p, int octaves) {
    float value = 0.0;
    float amplitude = 0.5;
    for (int i = 0; i < octaves; i++) {
        value += amplitude * noise2(p);
        p = p * 2.03 + float2(17.1, 9.2);
        amplitude *= 0.5;
    }
    return value;
}

static float sq(float x) {
    return x * x;
}

// 从 1 落到 0：x 不超过 lo 时为 1，到 hi 为 0（smoothstep 两个边界反着写是未定义行为）。
static float below(float lo, float hi, float x) {
    return 1.0 - smoothstep(lo, hi, x);
}

// 每个落点自己的随机数：按发生时刻算，不按它排在第几个槽（新落点进来时旧的会挪槽，按槽算会整体变样）。
static float eventSalt(float4 e) {
    return hash11(e.z * 0.731 + 0.37);
}

// 落点快到寿命（4 秒）时淡到 0，被挤掉时已经看不见。
static float eventFade(float age) {
    return below(3.0, 4.0, age);
}

static float vignette(float2 uv, float strength) {
    float2 d = uv - 0.5;
    return 1.0 - strength * smoothstep(0.25, 0.95, dot(d, d) * 2.2);
}

static float3 finish(float3 color) {
    return clamp(color, 0.0, 1.0);
}

// 副歌里背景慢慢推近一点（歌词不动，景往前靠）。
static float2 kineticZoom(float2 uv, constant KineticUniforms& u) {
    return (uv - 0.5) / max(u.extra.z, 1.0) + 0.5;
}

// 收尾：副歌里右上角亮起一片暖光（位置不动，只跟着副歌慢慢亮、慢慢灭），再夹到 0…1。
static float3 kineticFinish(float3 color, float2 uv, constant KineticUniforms& u) {
    float glow = u.extra.x;
    if (glow > 0.001) {
        float spot = exp(-length((uv - float2(0.92, -0.05)) * float2(1.6, 1.0)) * 2.4);
        float3 warm = mix(float3(1.0, 0.6, 0.3), u.colorA.rgb, 0.35);
        color = 1.0 - (1.0 - color) * (1.0 - warm * spot * glow * 0.6);
    }
    return clamp(color, 0.0, 1.0);
}

// ---- 雨窗 ----

// 窗外虚化的光斑：三层，每层查相邻的格子，光斑大过格子也不会被裁成方块。
static float3 rainBokeh(float2 uv, float aspect, float t, constant KineticUniforms& u) {
    float3 a = u.colorA.rgb;
    float3 b = u.colorB.rgb;
    float3 color = mix(b * 0.42, a * 0.20, uv.y) + float3(0.018, 0.02, 0.03);
    // 远处街道那一片低低的暖光。
    color += mix(a, float3(1.0, 0.80, 0.55), 0.45) * exp(-sq((uv.y - 0.80) * 3.5)) * 0.14;
    for (int layer = 0; layer < 3; layer++) {
        float fl = float(layer);
        float scale = 3.0 + fl * 2.6;
        float2 p = float2(uv.x * aspect, uv.y) * scale + float2(t * (0.012 + 0.008 * fl), 0.0);
        float2 base = floor(p);
        for (int oy = -1; oy <= 1; oy++) {
            for (int ox = -1; ox <= 1; ox++) {
                float2 cell = base + float2(float(ox), float(oy));
                float h = hash21(cell + fl * 17.0);
                if (h < 0.5) { continue; }
                float2 center = cell + 0.5 + (float2(hash21(cell + 3.1), hash21(cell + 7.7)) - 0.5) * 0.8;
                float radius = 0.20 + 0.32 * hash21(cell + 5.3);
                float soft = radius * (0.55 - 0.15 * fl);
                float mask = below(radius - soft, radius, length(p - center));
                float twinkle = 0.78 + 0.22 * sin(t * (0.5 + h) + h * 30.0);
                float3 tint = mix(a, float3(1.0, 0.84, 0.60), hash21(cell + 11.0) * 0.6);
                float lift = 0.09 + 0.10 * u.drive.x + 0.14 * u.drive3.x;
                color += tint * mask * lift * twinkle * (1.15 - 0.25 * fl);
            }
        }
    }
    return color;
}

// 贴在玻璃上的水珠：xy 是指向边缘的法线（中心 0、边上 1），z 是遮罩。
static float3 rainStaticDrops(float2 q, float t) {
    float2 p = q * 15.0;
    float2 cell = floor(p);
    float2 f = fract(p) - 0.5;
    float h = hash21(cell);
    float2 center = (float2(hash21(cell + 1.3), hash21(cell + 5.9)) - 0.5) * 0.45;
    float radius = 0.08 + 0.16 * hash21(cell + 9.1);
    float2 normal = (f - center) / radius;
    float life = fract(t * 0.035 + h);
    float alive = smoothstep(0.0, 0.06, life) * below(0.8, 1.0, life) * step(0.48, h);
    float mask = below(0.82, 1.0, length(normal)) * alive;
    return float3(normal * mask, mask);
}

// 一列一列往下滑的大水珠，滑过的地方留一道擦干净的水痕。xy 法线，z 水珠，w 水痕。`flow` 是流动时钟：
// 越热闹滑得越快，但速度变了水珠不会跳。
static float4 rainSlidingDrops(float2 q, float aspect, float flow) {
    const float columns = 5.0;
    float x = q.x / aspect * columns;
    float column = floor(x);
    float h = hash11(column * 3.7 + 1.0);
    float fx = (fract(x) - 0.5) * aspect / columns;
    float y = fract(flow * (0.10 + 0.12 * h) + h * 7.0) * 1.3 - 0.15;
    float wobble = 0.03 * sin(q.y * 7.0 + h * 40.0) * sin(q.y * 2.3 + h * 9.0);
    float dx = fx - wobble;
    float dy = q.y - y;
    float radius = 0.022 + 0.014 * h;
    // 上窄下圆的一颗。
    float2 normal = float2(dx, dy * (dy < 0.0 ? 0.6 : 1.0)) / radius;
    float present = step(0.2, h);
    float drop = below(0.82, 1.0, length(normal)) * present;
    float trail = below(radius * 0.25, radius * 0.6, abs(dx)) * smoothstep(-0.55, -0.02, dy) * step(dy, 0.0) * present;
    return float4(normal * drop, drop, trail);
}

fragment float4 kinetic_rainGlass(KineticVertexOut in [[stage_in]], constant KineticUniforms& u [[buffer(0)]]) {
    float2 uv = kineticZoom(in.uv, u);
    float aspect = u.frame.x / max(u.frame.y, 1.0);
    float t = u.frame.z;
    float2 q = float2(uv.x * aspect, uv.y);
    float3 still = rainStaticDrops(q, t);
    float4 slide = rainSlidingDrops(q, aspect, u.drive3.y);
    float drop = clamp(still.z + slide.z, 0.0, 1.0);
    float2 normal = still.xy + slide.xy;
    // 玻璃起了一层雾：雾后面的光斑暗一点、发白；水珠和水痕擦过的地方是清楚的。
    float3 clear = rainBokeh(uv, aspect, t, u);
    float3 fogged = clear * 0.72 + float3(0.035, 0.038, 0.045);
    float3 color = mix(fogged, clear, clamp(slide.w + drop, 0.0, 1.0));
    // 水珠像一面小透镜：里面的光斑倒过来、亮一点，边上一圈暗，左上一点高光。
    float3 lens = rainBokeh(uv - normal * 0.03, aspect, t, u) * 1.25;
    color = mix(color, lens, drop);
    float edge = smoothstep(0.55, 1.0, length(normal)) * drop;
    color *= 1.0 - edge * 0.45;
    float glint = below(0.0, 0.32, length(normal + float2(0.38, 0.45))) * drop;
    color += glint * 0.55;
    color *= vignette(uv, 0.5);
    return float4(kineticFinish(color, uv, u), 1.0);
}

// ---- 水面涟漪 ----

// 水面上方的夜空：上暗下亮，一轮月亮，几颗星。`y` 0 是画面顶，`horizon` 是水天线。
static float3 pondSky(float x, float y, float aspect, float horizon, float t, bool stars, constant KineticUniforms& u) {
    float3 a = u.colorA.rgb;
    float3 b = u.colorB.rgb;
    float k = clamp(y / horizon, 0.0, 1.0);
    float3 color = mix(b * 0.18 + float3(0.01, 0.012, 0.025), a * 0.32 + float3(0.05, 0.05, 0.06), k * k);
    float2 moon = float2(0.66 * aspect, horizon * 0.42);
    float d = length(float2(x * aspect, y) - moon);
    float3 moonColor = mix(float3(1.0, 0.96, 0.88), a, 0.25);
    color += moonColor * (below(0.034, 0.04, d) * 0.9 + exp(-d * 7.0) * 0.28);
    float2 cell = floor(float2(x * aspect, y) * 160.0);
    if (stars) {
        color += step(0.995, hash21(cell)) * (0.4 + 0.4 * sin(t * 1.7 + hash21(cell + 2.0) * 40.0)) * (1.0 - k) * 0.6;
    }
    return color;
}

static float pondHeight(float2 world, float t, constant KineticUniforms& u) {
    float h = (noise2(world * float2(2.2, 5.0) + float2(t * 0.20, t * 0.32)) - 0.5) * 0.10;
    h += (noise2(world * float2(6.0, 13.0) - float2(t * 0.45, -t * 0.25)) - 0.5) * 0.04;
    for (int i = 0; i < 8; i++) {
        float4 e = u.events[i];
        if (e.w <= 0.0) { continue; }
        float age = t - e.z;
        if (age < 0.0 || age > 4.0) { continue; }
        float2 center = float2((e.x - 0.5) * 2.4, 0.7 + e.y * 2.2);
        float d = length(world - center);
        float x = d - age * 0.42;
        float envelope = exp(-abs(x) * 7.0) * exp(-age * 0.75) * eventFade(age) * e.w;
        h += sin(x * 26.0) * envelope * 0.45;
    }
    return h;
}

static float2 pondWorld(float2 uv, float aspect, float horizon) {
    float depth = 0.22 / max(uv.y - horizon, 0.004);
    return float2((uv.x - 0.5) * aspect * depth, depth);
}

fragment float4 kinetic_ripplePond(KineticVertexOut in [[stage_in]], constant KineticUniforms& u [[buffer(0)]]) {
    float2 uv = kineticZoom(in.uv, u);
    float aspect = u.frame.x / max(u.frame.y, 1.0);
    float t = u.frame.z;
    const float horizon = 0.30;
    float3 a = u.colorA.rgb;
    float3 b = u.colorB.rgb;
    if (uv.y < horizon) {
        float3 sky = pondSky(uv.x, uv.y, aspect, horizon, t, true, u);
        return float4(kineticFinish(sky * vignette(uv, 0.5), uv, u), 1.0);
    }
    // 水面：按透视换到水平面上算波纹，远处的涟漪自然被压扁。斜率在水平面上量，远近一致。
    float2 world = pondWorld(uv, aspect, horizon);
    const float step = 0.012;
    float h0 = pondHeight(world, t, u);
    float2 grad = float2(
        pondHeight(world + float2(step, 0.0), t, u) - h0,
        pondHeight(world + float2(0.0, step), t, u) - h0
    ) / step;
    grad = clamp(grad, -6.0, 6.0);
    float waterDepth = uv.y - horizon;
    float nearness = 0.3 + waterDepth;
    // 倒影：沿水天线翻下来，离水天线多远倒影就在线下多远，再按波纹揉一揉；翻过天顶的部分只取天顶的颜色。
    float reflectY = horizon - waterDepth + grad.y * 0.010 * nearness;
    float reflectX = uv.x + grad.x * 0.006 * nearness;
    float3 mirrored = pondSky(reflectX, max(reflectY, 0.0), aspect, horizon, t, reflectY > 0.0, u);
    float fresnel = 0.35 + 0.6 * exp(-waterDepth * 4.0);
    float3 deep = b * 0.22 + a * 0.05 + float3(0.01, 0.014, 0.022);
    float3 color = mix(deep, mirrored, fresnel);
    // 月光在水面上拉出的一道碎金：越近越宽，波纹把它打碎成一片闪光。
    float moonX = 0.66 * aspect;
    float spread = 9.0 / (0.12 + waterDepth);
    float path = exp(-sq((uv.x * aspect - moonX - grad.x * 0.03) * spread));
    float glitter = smoothstep(0.45, 0.95, noise2(world * float2(5.0, 16.0) + float2(t * 0.7, -t * 0.4)));
    color += mix(float3(1.0, 0.95, 0.85), a, 0.3) * path * (0.25 + 0.75 * glitter) * 0.55 * exp(-waterDepth * 1.2);
    // 浪尖迎着月光的那一面亮一下。
    float crest = clamp(h0 * 2.2, 0.0, 1.0);
    color += mix(float3(1.0), a, 0.4) * crest * crest * 0.22 * (0.5 + u.drive3.x);
    // 水天线上一层薄雾。
    color = mix(color, a * 0.30 + float3(0.05), exp(-waterDepth * 30.0) * 0.6);
    color *= vignette(uv, 0.5);
    return float4(kineticFinish(color, uv, u), 1.0);
}

// ---- 天光一日 ----

static float3 skyKey(float p, bool top) {
    // 拂晓、上午、正午、黄昏、入夜五个关键帧。
    float3 tops[5] = { float3(0.10, 0.11, 0.26), float3(0.22, 0.40, 0.66), float3(0.14, 0.34, 0.66), float3(0.20, 0.14, 0.34), float3(0.02, 0.03, 0.08) };
    float3 horizons[5] = { float3(0.82, 0.46, 0.40), float3(0.72, 0.78, 0.84), float3(0.62, 0.76, 0.88), float3(0.96, 0.52, 0.24), float3(0.10, 0.11, 0.22) };
    float scaled = clamp(p, 0.0, 1.0) * 4.0;
    int index = min(int(floor(scaled)), 3);
    float f = smoothstep(0.0, 1.0, scaled - float(index));
    return top ? mix(tops[index], tops[index + 1], f) : mix(horizons[index], horizons[index + 1], f);
}

fragment float4 kinetic_daylight(KineticVertexOut in [[stage_in]], constant KineticUniforms& u [[buffer(0)]]) {
    float2 uv = kineticZoom(in.uv, u);
    float aspect = u.frame.x / max(u.frame.y, 1.0);
    float t = u.frame.z;
    float p = u.frame.w;
    float2 q = float2(uv.x * aspect, uv.y);
    float3 a = u.colorA.rgb;
    float3 top = skyKey(p, true);
    float3 horizon = skyKey(p, false);
    float horizonLine = 0.74;
    float3 color = mix(top, horizon, smoothstep(0.0, horizonLine, uv.y));
    color = mix(color, color * (0.6 + 0.8 * a), 0.25);
    // 太阳沿一道弧从左走到右。
    float2 sun = float2(mix(0.10, 0.90, p) * aspect, horizonLine - sin(p * 3.14159) * 0.52);
    float d = length(q - sun);
    float altitude = clamp((horizonLine - sun.y) / 0.52, 0.0, 1.0);
    float3 sunColor = mix(float3(1.0, 0.55, 0.28), float3(1.0, 0.93, 0.78), altitude);
    float night = smoothstep(0.82, 0.95, p);
    color += sunColor * (exp(-d * 9.0) * 0.55 + below(0.035, 0.05, d) * 0.6) * (1.0 - night) * (0.85 + 0.3 * u.drive.x);
    // 夜里的星星和月亮。
    float2 starCell = floor(q * 180.0);
    float star = step(0.996, hash21(starCell)) * (0.5 + 0.5 * sin(t * 2.0 + hash21(starCell + 4.0) * 50.0));
    color += star * night * (1.0 - smoothstep(0.4, horizonLine, uv.y)) * 0.8;
    float2 moon = float2(0.78 * aspect, 0.22);
    color += float3(0.85, 0.88, 0.95) * below(0.03, 0.035, length(q - moon)) * night * 0.7;
    // 云：慢慢往右飘，被太阳从侧面照亮。
    float clouds = fbm(float2(q.x * 1.8 + t * 0.012, uv.y * 4.2), 5);
    float cloudMask = smoothstep(0.52, 0.78, clouds) * (1.0 - smoothstep(0.1, horizonLine, uv.y) * 0.6);
    float3 cloudColor = mix(horizon * 0.95, float3(1.0), 0.35) * (0.55 + 0.45 * (1.0 - night));
    color = mix(color, cloudColor, cloudMask * 0.7);
    // 两层远山。
    float far = horizonLine + 0.04 - 0.07 * fbm(float2(q.x * 1.4, 3.0), 4);
    float near = horizonLine + 0.12 - 0.09 * fbm(float2(q.x * 2.3 + 9.0, 7.0), 4);
    float3 hillFar = mix(horizon * 0.45, float3(0.04, 0.05, 0.08), 0.35);
    float3 hillNear = float3(0.025, 0.03, 0.05) + u.colorB.rgb * 0.08;
    color = mix(color, hillFar, smoothstep(far, far + 0.004, uv.y));
    color = mix(color, hillNear, smoothstep(near, near + 0.004, uv.y));
    // 歌词压在正中：整幅压暗一点，字才看得清。
    color *= (0.74 - 0.14 * sin(p * 3.14159)) * vignette(uv, 0.45);
    return float4(kineticFinish(color, uv, u), 1.0);
}

// ---- 曲速隧道 ----

static float warpLayer(float2 d, float r, float angle, float travel, float count, float salt, float stretch) {
    float slot = (angle / 6.28318 + 0.5) * count;
    float bin = floor(slot);
    float within = fract(slot) - 0.5;
    float h = hash11(bin * 1.37 + salt);
    float z = fract(h * 7.0 - travel * (0.35 + 0.65 * h));
    float radius = 0.035 / max(z, 0.015);
    float streakLength = radius * stretch;
    float along = smoothstep(radius - streakLength, radius, r) * below(radius, radius + 0.006, r);
    float across = exp(-sq(within / (0.10 + 0.12 * (1.0 - z))));
    return along * across * (1.0 - z) * step(0.35, h);
}

fragment float4 kinetic_warpTunnel(KineticVertexOut in [[stage_in]], constant KineticUniforms& u [[buffer(0)]]) {
    float2 uv = kineticZoom(in.uv, u);
    float aspect = u.frame.x / max(u.frame.y, 1.0);
    float t = u.frame.z;
    float2 q = float2(uv.x * aspect, uv.y);
    float2 center = float2(0.5 * aspect + 0.03 * sin(t * 0.31), 0.5 + 0.02 * cos(t * 0.23));
    float2 d = q - center;
    float r = length(d);
    float angle = atan2(d.y, d.x);
    float travel = u.motion.x;
    // 拖尾长短跟着里程的速度走（速度是平滑过的），不跟着鼓点一帧一帧地伸缩。
    float stretch = clamp(0.1 + 0.26 * u.drive3.z, 0.18, 0.95);
    float3 a = u.colorA.rgb;
    float3 b = u.colorB.rgb;
    float3 color = b * 0.06 + float3(0.006, 0.008, 0.016);
    // 隧道壁：一段一段往外冲的碎环。
    float rings = sin(log(max(r, 0.001)) * 14.0 - travel * 6.0);
    float broken = noise2(float2(angle * 4.0, log(max(r, 0.001)) * 3.0 - travel * 1.5));
    color += a * smoothstep(0.82, 1.0, rings) * smoothstep(0.45, 0.8, broken) * 0.09 * smoothstep(0.03, 0.45, r);
    float streaks = warpLayer(d, r, angle, travel, 140.0, 0.0, stretch);
    streaks += warpLayer(d, r, angle + 0.013, travel * 1.3, 230.0, 11.0, stretch) * 0.75;
    streaks += warpLayer(d, r, angle + 0.007, travel * 0.8, 380.0, 23.0, stretch * 0.8) * 0.45;
    float3 tint = mix(a, float3(1.0), 0.45 + 0.3 * sin(angle * 3.0 + travel));
    color += tint * streaks * (0.9 + 0.8 * u.drive.z);
    // 中心的光，鼓点时一亮。
    color += mix(a, float3(1.0), 0.5) * exp(-r * 9.0) * (0.25 + 0.6 * u.drive3.x + 0.3 * u.drive2.z);
    // 重拍冲出去的冲击波。
    for (int i = 0; i < 8; i++) {
        float4 e = u.events[i];
        if (e.w <= 0.0) { continue; }
        float age = t - e.z;
        if (age < 0.0 || age > 1.0) { continue; }
        float front = age * 1.3;
        float ring = exp(-sq((r - front) * 90.0)) * sq(1.0 - age) * e.w;
        color += mix(a, float3(1.0), 0.35) * ring * 0.4;
    }
    color *= vignette(uv, 0.65);
    return float4(kineticFinish(color, uv, u), 1.0);
}

// ---- 雷暴 ----

static float boltDistance(float2 q, float aspect, float seed) {
    float x0 = (0.18 + 0.64 * seed) * aspect;
    float bottom = 0.55 + 0.3 * hash11(seed * 91.0);
    float y = q.y;
    float path = x0 + (fbm(float2(y * 6.0, seed * 40.0), 4) - 0.5) * 0.34 + (noise2(float2(y * 46.0, seed * 13.0)) - 0.5) * 0.035;
    float trunk = abs(q.x - path) + step(bottom, y) * 10.0;
    // 中途分出去的一支。
    float forkY = 0.22 + 0.15 * hash11(seed * 7.0);
    float side = hash11(seed * 3.0) < 0.5 ? -1.0 : 1.0;
    float forkPath = x0 + (fbm(float2(forkY * 6.0, seed * 40.0), 4) - 0.5) * 0.34 + (y - forkY) * 0.55 * side
        + (noise2(float2(y * 40.0, seed * 29.0)) - 0.5) * 0.03;
    float fork = abs(q.x - forkPath) + (step(y, forkY) + step(forkY + 0.22, y)) * 10.0;
    return min(trunk, fork * 1.6);
}

fragment float4 kinetic_thunderstorm(KineticVertexOut in [[stage_in]], constant KineticUniforms& u [[buffer(0)]]) {
    float2 uv = kineticZoom(in.uv, u);
    float aspect = u.frame.x / max(u.frame.y, 1.0);
    float t = u.frame.z;
    float2 q = float2(uv.x * aspect, uv.y);
    float3 a = u.colorA.rgb;
    float3 b = u.colorB.rgb;
    float flash = u.drive2.y;
    float seed = u.motion.y;
    // 乌云：扭一扭再叠几层噪声。
    float2 warp = float2(fbm(q * 1.6 + float2(t * 0.03, 0.0), 3), fbm(q * 1.6 + float2(5.2, t * 0.02), 3));
    float clouds = fbm(q * float2(1.4, 2.6) + warp * 0.8 + float2(t * 0.02, 0.0), 5);
    float upper = 1.0 - smoothstep(0.15, 0.85, uv.y);
    float billow = smoothstep(0.32, 0.78, clouds);
    float3 color = mix(float3(0.014, 0.016, 0.026), b * 0.38 + float3(0.06, 0.065, 0.08), billow * (0.35 + 0.65 * upper));
    // 云团朝上那一面被天光勾出一点边。
    color += (b * 0.3 + 0.05) * smoothstep(0.55, 0.75, clouds) * (1.0 - smoothstep(0.55, 0.85, fbm(q * float2(1.4, 2.6) + warp * 0.8 + float2(t * 0.02, -0.03), 5))) * upper;
    // 远处云里的暗闪：没有落雷时也偶尔亮一下。
    float distant = smoothstep(0.86, 1.0, noise2(float2(t * 2.3, 4.1))) * (0.5 + 0.5 * u.drive3.x);
    // 暗闪的位置慢慢挪，不会亮着亮着跳到另一处。
    float2 distantCenter = float2((0.2 + 0.6 * noise2(float2(t * 0.17, 8.0))) * aspect, 0.22);
    color += (b * 0.5 + 0.15) * distant * billow * exp(-length(q - distantCenter) * 3.0) * 0.6;
    // 闪电：芯很亮，外面一圈光，云被从里面照亮。
    float bolt = boltDistance(q, aspect, seed);
    float3 boltColor = mix(float3(0.85, 0.9, 1.0), a, 0.25);
    float nearness = exp(-abs(q.x - (0.18 + 0.64 * seed) * aspect) * 2.2);
    color += boltColor * flash * (exp(-bolt * 420.0) * 1.2 + exp(-bolt * 45.0) * 0.35);
    color += boltColor * flash * clouds * (0.18 + 0.5 * nearness) * upper;
    color += boltColor * flash * 0.06;
    // 斜雨：两层，近的粗而快。
    for (int layer = 0; layer < 2; layer++) {
        float fl = float(layer);
        float2 rp = float2(q.x + q.y * (0.16 + 0.04 * fl), q.y);
        float columns = 90.0 - 40.0 * fl;
        float column = floor(rp.x * columns);
        float h = hash11(column + fl * 31.0);
        float fall = fract(rp.y * (1.2 - 0.4 * fl) + u.drive3.y * (3.0 + 1.8 * h) + h * 9.0);
        float streak = smoothstep(0.86, 1.0, fall) * exp(-sq((fract(rp.x * columns) - 0.5) / (0.07 + 0.05 * fl)));
        color += float3(0.55, 0.6, 0.7) * streak * step(0.3, h) * (0.10 + 0.08 * fl) * (1.0 + 2.0 * flash);
    }
    color *= vignette(uv, 0.6);
    return float4(kineticFinish(color, uv, u), 1.0);
}
// ---- 雾中光柱 ----

fragment float4 kinetic_godRays(KineticVertexOut in [[stage_in]], constant KineticUniforms& u [[buffer(0)]]) {
    float2 uv = kineticZoom(in.uv, u);
    float aspect = u.frame.x / max(u.frame.y, 1.0);
    float t = u.frame.z;
    float2 q = float2(uv.x * aspect, uv.y);
    float3 a = u.colorA.rgb;
    float3 b = u.colorB.rgb;
    // 光从画面上方偏一侧斜射进来，光源慢慢挪。
    float2 source = float2((0.32 + 0.08 * sin(t * 0.05)) * aspect, -0.35);
    float2 d = q - source;
    float angle = atan2(d.x, d.y);
    float dist = length(d);
    float rays = 0.0;
    rays += smoothstep(0.35, 1.0, noise2(float2(angle * 9.0, t * 0.06)));
    rays += 0.6 * smoothstep(0.45, 1.0, noise2(float2(angle * 23.0 + 4.0, t * 0.09)));
    rays *= smoothstep(0.0, 0.25, angle + 0.75) * below(0.25, 0.75, angle);
    float fog = fbm(q * float2(2.0, 3.0) + float2(t * 0.025, t * 0.01), 4);
    float breathe = 0.75 + 0.45 * u.drive3.x + 0.2 * u.drive.x;
    float3 color = mix(float3(0.012, 0.014, 0.02), b * 0.2 + 0.02, fog * 0.8);
    float3 beam = mix(a, float3(1.0, 0.92, 0.78), 0.55);
    color += beam * rays * (0.18 + 0.32 * fog) * exp(-dist * 0.7) * breathe;
    // 光里飘的浮尘：落在光柱里的才亮。
    float2 dustP = q * 70.0 + float2(t * 0.6, -t * 0.9);
    float2 cell = floor(dustP);
    float h = hash21(cell);
    float2 f = fract(dustP) - 0.5 - (float2(hash21(cell + 2.0), hash21(cell + 5.0)) - 0.5) * 0.6;
    float mote = below(0.0, 0.12, length(f)) * step(0.93, h) * (0.6 + 0.4 * sin(t * 3.0 + h * 40.0));
    color += beam * mote * (0.15 + rays * 0.9) * (0.7 + 0.8 * u.drive2.x);
    color *= vignette(uv, 0.55);
    return float4(kineticFinish(color, uv, u), 1.0);
}

// ---- 星轨长曝光 ----

fragment float4 kinetic_starTrails(KineticVertexOut in [[stage_in]], constant KineticUniforms& u [[buffer(0)]]) {
    float2 uv = kineticZoom(in.uv, u);
    float aspect = u.frame.x / max(u.frame.y, 1.0);
    float t = u.frame.z;
    float2 q = float2(uv.x * aspect, uv.y);
    float3 a = u.colorA.rgb;
    float3 b = u.colorB.rgb;
    float2 pole = float2(0.78 * aspect, 0.12);
    float2 d = q - pole;
    float r = length(d);
    float angle = atan2(d.y, d.x);
    // 天空：靠近地平线偏亮一点。
    float3 color = mix(b * 0.10 + float3(0.006, 0.008, 0.02), a * 0.18 + float3(0.02, 0.025, 0.04), smoothstep(0.2, 0.95, uv.y));
    // 一圈一圈的星轨：每一圈上一两颗星，拖出一段弧。
    float ringWidth = 0.0055;
    float ring = floor(r / ringWidth);
    float within = fract(r / ringWidth) - 0.5;
    float exposure = 0.55 + 0.9 * u.drive.x;
    for (int k = 0; k < 2; k++) {
        float h = hash11(ring * 1.7 + float(k) * 31.0);
        float head = h * 6.28318 + u.drive3.y * 0.05;
        float behind = fmod(head - angle + 12.56636, 6.28318);
        float trail = below(exposure * 0.2, exposure, behind) * step(0.55, hash11(ring * 3.1 + float(k)));
        float brightness = (0.25 + 0.75 * hash11(ring * 5.3 + float(k))) * (1.0 - behind / max(exposure, 0.01));
        float3 starColor = mix(float3(0.75, 0.85, 1.0), mix(a, float3(1.0), 0.5), hash11(ring + float(k) * 7.0));
        color += starColor * trail * brightness * exp(-sq(within * 3.2)) * 0.7;
    }
    // 重拍时划过一颗流星。
    for (int i = 0; i < 8; i++) {
        float4 e = u.events[i];
        if (e.w < 0.5) { continue; }
        float age = t - e.z;
        if (age < 0.0 || age > 0.8) { continue; }
        float2 start = float2(e.x * aspect, e.y * 0.5);
        float2 dir = normalize(float2(-0.8, 0.45));
        float2 head = start + dir * age * 1.4;
        float2 rel = q - head;
        float along = dot(rel, -dir);
        float across = abs(rel.x * dir.y - rel.y * dir.x);
        float streak = smoothstep(0.25, 0.0, along) * step(0.0, along) * exp(-across * 900.0);
        color += float3(1.0, 0.95, 0.9) * streak * (1.0 - age / 0.8) * 1.2;
    }
    // 前景一道山脊剪影。
    float ridge = 0.86 - 0.08 * fbm(float2(q.x * 2.2, 2.0), 4);
    color = mix(color, float3(0.008, 0.009, 0.014), smoothstep(ridge, ridge + 0.003, uv.y));
    color *= vignette(uv, 0.5);
    return float4(kineticFinish(color, uv, u), 1.0);
}

// ---- 池底焦散 ----

static float causticLayer(float2 p, float t) {
    float2 cell = floor(p);
    float2 f = fract(p);
    float first = 8.0;
    float second = 8.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float2 offset = float2(float(x), float(y));
            float2 seed = cell + offset;
            float2 jitter = 0.5 + 0.42 * sin(t * (0.6 + 0.4 * hash21(seed)) + 6.28318 * float2(hash21(seed + 1.7), hash21(seed + 9.2)));
            float d = length(offset + jitter - f);
            if (d < first) { second = first; first = d; } else if (d < second) { second = d; }
        }
    }
    // 边越窄越亮，两层叠起来交汇处更亮。
    return exp(-(second - first) * 11.0);
}

fragment float4 kinetic_caustics(KineticVertexOut in [[stage_in]], constant KineticUniforms& u [[buffer(0)]]) {
    float2 uv = kineticZoom(in.uv, u);
    float aspect = u.frame.x / max(u.frame.y, 1.0);
    float t = u.frame.z;
    float2 q = float2(uv.x * aspect, uv.y);
    float3 a = u.colorA.rgb;
    float3 b = u.colorB.rgb;
    float2 warp = float2(fbm(q * 1.6 + t * 0.12, 3), fbm(q * 1.6 - t * 0.10 + 7.0, 3)) - 0.5;
    float flow = u.drive3.y * 0.9;
    float first = causticLayer(q * 3.6 + warp * 1.4, flow);
    float second = causticLayer(q * 5.4 - warp * 1.1 + 3.0, flow * 1.27);
    float light = pow(first * 0.65 + second * 0.55, 2.2) * 1.4;
    float3 floorColor = mix(b * 0.25 + float3(0.01, 0.025, 0.035), a * 0.22 + float3(0.02, 0.04, 0.05), uv.y);
    float3 color = floorColor + mix(a, float3(0.85, 0.98, 1.0), 0.55) * light * (0.22 + 0.25 * u.drive3.x);
    // 水面上一层波光的斑驳，往远处变淡。
    color *= 0.85 + 0.25 * noise2(q * 3.0 + float2(t * 0.2, 0.0));
    color *= vignette(uv, 0.6);
    return float4(kineticFinish(color, uv, u), 1.0);
}

// ---- 墨入水 ----

fragment float4 kinetic_inkBloom(KineticVertexOut in [[stage_in]], constant KineticUniforms& u [[buffer(0)]]) {
    float2 uv = kineticZoom(in.uv, u);
    float aspect = u.frame.x / max(u.frame.y, 1.0);
    float t = u.frame.z;
    float2 q = float2(uv.x * aspect, uv.y);
    float3 a = u.colorA.rgb;
    float3 b = u.colorB.rgb;
    float3 color = float3(0.008, 0.009, 0.014) + b * 0.05;
    // 底下一直在慢慢翻卷的一层墨。
    float2 w1 = float2(fbm(q * 1.3 + float2(t * 0.02, 0.0), 4), fbm(q * 1.3 + float2(3.1, t * 0.018), 4));
    float base = fbm(q * 1.6 + w1 * 1.4 + float2(0.0, t * 0.015), 5);
    color += mix(b, a, base) * smoothstep(0.45, 0.85, base) * 0.22;
    // 每一下鼓点滴进一团墨，边缘被水流扯成丝。
    for (int i = 0; i < 8; i++) {
        float4 e = u.events[i];
        if (e.w <= 0.0) { continue; }
        float age = t - e.z;
        if (age < 0.0 || age > 4.0) { continue; }
        float2 c = float2(e.x * aspect, e.y);
        float2 rel = q - c;
        float salt = eventSalt(e) * 40.0;
        float2 swirl = float2(fbm(rel * 3.0 + float2(age * 0.3, salt), 4), fbm(rel * 3.0 + float2(salt * 2.0, age * 0.25), 4)) - 0.5;
        float radius = 0.04 + 0.24 * (1.0 - exp(-age * 1.0));
        float d = length(rel + swirl * 0.22 * (0.4 + age));
        // 边缘被水流扯成丝：密度按细碎的噪声起伏，越往外越稀。
        float detail = fbm(rel * 9.0 + swirl * 3.0 + float2(age * 0.4, -age * 0.3), 4);
        float density = smoothstep(0.0, 0.12, radius - d + (detail - 0.5) * 0.16);
        float filaments = 0.45 + 0.9 * smoothstep(0.35, 0.75, detail);
        float life = exp(-age * 0.5) * eventFade(age) * e.w;
        float cloud = density * filaments * life;
        float3 tint = mix(a * 1.3 + 0.08, mix(b * 1.6 + 0.15, float3(1.0), 0.3), hash11(salt * 3.7 + 1.3));
        // 墨团的外沿迎着光，亮一圈。
        float rim = smoothstep(0.0, 0.05, radius - d + (detail - 0.5) * 0.16) - density * 0.6;
        color += tint * (cloud * 0.85 + max(rim, 0.0) * life * 0.35);
    }
    color *= vignette(uv, 0.55);
    return float4(kineticFinish(color, uv, u), 1.0);
}

// ---- 激光秀 ----

fragment float4 kinetic_laserShow(KineticVertexOut in [[stage_in]], constant KineticUniforms& u [[buffer(0)]]) {
    float2 uv = kineticZoom(in.uv, u);
    float aspect = u.frame.x / max(u.frame.y, 1.0);
    float t = u.frame.z;
    float2 q = float2(uv.x * aspect, uv.y);
    float3 a = u.colorA.rgb;
    float3 b = u.colorB.rgb;
    float haze = fbm(q * float2(1.5, 2.5) + float2(t * 0.05, t * 0.03), 4);
    float3 color = float3(0.01, 0.01, 0.016) + b * 0.10 * haze + a * 0.04 * haze * u.drive3.x;
    float flow = u.drive3.y;
    float flowRate = 0.55 + 0.9 * u.drive.x + 0.35 * u.drive2.z;
    // 张开的幅度跟圆滑过的鼓点走：直接跟鼓点包络，光束会一帧跳到另一个角度。
    float fan = 0.25 + 0.5 * u.drive3.x + 0.3 * u.drive2.z;
    float amplitude = 0.35 + fan * 0.55;
    // 台口一排光源，光束扫来扫去，鼓点时张开。
    for (int i = 0; i < 9; i++) {
        float fi = float(i);
        float2 source = float2((0.08 + 0.105 * fi) * aspect, 1.04);
        float rate = 0.45 + 0.08 * fi;
        float phase = flow * rate + fi * 1.9;
        float sweep = sin(phase) * amplitude + (fi - 4.0) * 0.07;
        float2 dir = float2(sin(sweep), -cos(sweep));
        float2 rel = q - source;
        float along = dot(rel, dir);
        float across = abs(rel.x * dir.y - rel.y * dir.x);
        // 运动模糊：一帧（按 30 帧算）里光束扫过多宽，芯就摊多宽、按比例变暗，扫得快时是一片光而不是一格格跳。
        float sweepSpeed = abs(cos(phase) * amplitude * rate * flowRate);
        float core = 1.0 / 260.0 + sweepSpeed * max(along, 0.0) / 30.0 * 0.5;
        float beam = step(0.0, along) * (exp(-across / core) / (core * 260.0) + exp(-across * 24.0) * 0.28);
        float3 tint = (i % 3 == 0) ? a : ((i % 3 == 1) ? mix(b * 1.8 + 0.2, float3(0.3, 0.9, 1.0), 0.5) : mix(a, float3(1.0, 0.2, 0.8), 0.5));
        color += mix(tint, float3(1.0), 0.3) * beam * (0.3 + 0.9 * haze) * (0.55 + 0.9 * u.drive.x);
        // 光源本身一个亮点。
        color += mix(tint, float3(1.0), 0.6) * exp(-length(rel) * 40.0) * 0.6;
    }
    // 重拍时台口一片横向的扫光。
    color += mix(a, float3(1.0), 0.5) * u.drive3.x * 0.12 * exp(-sq((uv.y - 0.98) * 6.0));
    color *= vignette(uv, 0.5);
    return float4(kineticFinish(color, uv, u), 1.0);
}

// ---- 霓虹夜驰 ----

fragment float4 kinetic_neonDrive(KineticVertexOut in [[stage_in]], constant KineticUniforms& u [[buffer(0)]]) {
    float2 uv = kineticZoom(in.uv, u);
    float aspect = u.frame.x / max(u.frame.y, 1.0);
    float t = u.frame.z;
    float3 a = u.colorA.rgb;
    float3 b = u.colorB.rgb;
    const float horizon = 0.52;
    float travel = u.motion.x * 1.4;
    float3 neonA = mix(a, float3(1.0, 0.3, 0.7), 0.35);
    float3 neonB = mix(b * 1.8 + 0.15, float3(0.2, 0.9, 1.0), 0.45);
    float3 color;
    if (uv.y < horizon) {
        // 天上：深色渐变，远处城市的一排灯。
        float k = uv.y / horizon;
        color = mix(float3(0.01, 0.008, 0.025), neonA * 0.22 + float3(0.03, 0.01, 0.05), k * k);
        float x = uv.x * aspect;
        float skyline = horizon - (0.04 + 0.12 * step(0.5, hash11(floor(x * 18.0)))) * hash11(floor(x * 18.0) + 3.0);
        if (uv.y > skyline) {
            color = float3(0.02, 0.016, 0.035);
            float2 window = floor(float2(x * 140.0, uv.y * 160.0));
            color += mix(neonA, float3(1.0, 0.85, 0.6), 0.5) * step(0.82, hash21(window)) * 0.35;
        }
    } else {
        // 路面：透视网格往脸上冲。
        float ground = uv.y - horizon;
        float depth = 0.12 / ground;
        float2 world = float2((uv.x - 0.5) * aspect * depth, depth + travel);
        // 横线每半个单位一道，竖线是车道。线宽按屏幕像素算（fwidth），远近都是一两个像素，网格才会往消失点收拢。
        // 冲得快时一帧（按 30 帧算）横线能挪掉小半格：按挪的距离把线拉成一道光、稍稍变暗，不然近处的
        // 横线会一格一格地跳，看着像闪。只按平方根变暗，拉长了仍是一道亮的灯带。
        float rowCoord = world.y * 2.0;
        float acrossLine = abs(fract(rowCoord + 0.5) - 0.5);
        float sharp = fwidth(rowCoord) * 1.6;
        float smear = min(sharp + u.drive3.z * 1.4 * 2.0 / 30.0 * 0.5, 0.45);
        float lines = below(0.0, smear, acrossLine) * sqrt(sharp / max(smear, 0.0001));
        float laneCoord = world.x * 12.0;
        float laneLine = abs(fract(laneCoord + 0.5) - 0.5);
        float lanes = below(0.0, fwidth(laneCoord) * 1.4, laneLine);
        color = float3(0.008, 0.006, 0.02) + neonB * 0.03;
        color += neonA * lines * exp(-depth * 0.05) * 0.9;
        color += neonB * lanes * exp(-depth * 0.06) * 0.8;
        // 路边一路掠过的灯柱拖出光带。
        float side = abs((uv.x - 0.5) * aspect * depth);
        float posts = smoothstep(0.85, 1.0, sin(world.y * 3.0)) * below(0.0, 0.12, abs(side - 2.4));
        color += mix(neonA, float3(1.0), 0.5) * posts * exp(-depth * 0.04);
    }
    // 地平线上一层辉光，重拍时更亮。
    color += neonA * exp(-abs(uv.y - horizon) * 22.0) * (0.25 + 0.5 * u.drive3.x);
    color *= vignette(uv, 0.55);
    return float4(kineticFinish(color, uv, u), 1.0);
}
"""#
}
