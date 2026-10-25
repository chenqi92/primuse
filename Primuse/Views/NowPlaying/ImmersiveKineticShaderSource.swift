// 「动态歌词」背景场景的 Metal 着色器源码。
//
// 运行时交给系统自带的 Metal 编译器（`MTLDevice.makeLibrary(source:)`）编一次：工程里不放 .metal 文件，
// 打包机就不需要另装 Xcode 的 Metal Toolchain。每个场景一个片元函数，共用一个铺满画面的顶点函数。
//
// `KineticUniforms` 必须和 `ImmersiveKineticUniforms`（ImmersiveKineticMetalBackdrop.swift）逐字段一致，
// 全部用 float4，两边的对齐方式不会有分歧。弹珠落音和两个音游场景另有一份 `props`（buffer 1，float4 数组），
// 由 PrimuseKit 的 `ImmersiveKineticMarbleRun.packed`、`ImmersiveKineticRhythmChart.packed` 打包，格式写在各场景前面。

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
// ---- 三个新场景共用 ----

static float segmentDistance(float2 p, float2 a, float2 b) {
    float2 pa = p - a;
    float2 ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-7), 0.0, 1.0);
    return length(pa - ba * h);
}

// 点在三角形里时为 1（不管三个点是顺时针还是逆时针）。
static float insideTriangle(float2 p, float2 a, float2 b, float2 c) {
    float e0 = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x);
    float e1 = (c.x - b.x) * (p.y - b.y) - (c.y - b.y) * (p.x - b.x);
    float e2 = (a.x - c.x) * (p.y - c.y) - (a.y - c.y) * (p.x - c.x);
    bool positive = e0 >= 0.0 && e1 >= 0.0 && e2 >= 0.0;
    bool negative = e0 <= 0.0 && e1 <= 0.0 && e2 <= 0.0;
    return (positive || negative) ? 1.0 : 0.0;
}

// 圆角方块的有向距离：里面为负。
static float roundedBox(float2 p, float halfSize, float corner) {
    float2 d = abs(p) - (halfSize - corner);
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - corner;
}

static float2 rotate2(float2 p, float angle) {
    float c = cos(angle);
    float s = sin(angle);
    return float2(c * p.x - s * p.y, s * p.x + c * p.y);
}

// 两只手 / 两类音符的颜色：一暖一冷，专辑色带一点进去，整张专辑颜色相近时也分得开。
static float3 rhythmHandColor(int hand, constant KineticUniforms& u) {
    if (hand == 0) {
        return mix(u.colorA.rgb * 1.2 + 0.05, float3(1.0, 0.26, 0.36), 0.5);
    }
    return mix(u.colorB.rgb * 1.6 + 0.1, float3(0.2, 0.62, 1.0), 0.6);
}

// ---- 弹珠落音 ----
// props（float4）：[0] 球数、音条数、拖尾点数、画面在这条路上走到哪（只用来让背景的微尘跟着往上退）；
// [1…3] 每颗球 x、y（画面里，按画面高度算，x 从 0 到宽高比）、半径、声部；[4…6] 离上次弹开多久、速度、拖尾点数；
// [8…22] 每颗球五组拖尾点（两个点一组，最新的在前）；[24…] 每根音条两组：撞点 x、y、法线角、长度，离撞上多久、声部、力度。

static float3 marbleVoiceColor(int voice, constant KineticUniforms& u) {
    float3 a = u.colorA.rgb;
    float3 b = u.colorB.rgb;
    if (voice == 0) { return mix(a * 1.15, float3(1.0, 0.55, 0.42), 0.3); }
    if (voice == 1) { return mix(b * 1.6 + 0.12, float3(0.42, 0.86, 1.0), 0.5); }
    return mix(float3(1.0, 0.9, 0.7), a, 0.15);
}

fragment float4 kinetic_marbleDrop(KineticVertexOut in [[stage_in]], constant KineticUniforms& u [[buffer(0)]], constant float4* props [[buffer(1)]]) {
    float2 uv = kineticZoom(in.uv, u);
    float aspect = u.frame.x / max(u.frame.y, 1.0);
    float t = u.frame.z;
    float2 q = float2(uv.x * aspect, uv.y);
    float3 a = u.colorA.rgb;
    float3 b = u.colorB.rgb;
    int ballCount = min(int(props[0].x), 3);
    int barCount = min(int(props[0].y), 52);
    float camera = props[0].w;
    float3 color = mix(b * 0.10 + float3(0.006, 0.007, 0.014), a * 0.07 + float3(0.012, 0.012, 0.022), uv.y);
    // 远近两层微尘：画面往下走，它们往上退，越近退得越快。
    for (int layer = 0; layer < 2; layer++) {
        float fl = float(layer);
        float2 p = float2(q.x, q.y + camera * (0.3 + 0.4 * fl)) * (34.0 - 12.0 * fl);
        float2 cell = floor(p);
        float h = hash21(cell + fl * 31.0);
        float2 f = fract(p) - 0.5 - (float2(hash21(cell + 2.3), hash21(cell + 7.1)) - 0.5) * 0.7;
        float mote = below(0.0, 0.07 + 0.05 * fl, length(f)) * step(0.88, h);
        color += mix(b * 1.4 + 0.1, float3(1.0), 0.5) * mote * (0.05 + 0.05 * fl) * (0.7 + 0.3 * sin(t * 1.3 + h * 40.0));
    }
    // 音条：撞上那一下亮起来、荡开一圈，之后留着微光慢慢暗下去。
    for (int i = 0; i < barCount; i++) {
        float4 g = props[24 + i * 2];
        float4 m = props[25 + i * 2];
        float2 c = g.xy;
        float2 rel = q - c;
        if (abs(rel.x) > 0.2 || abs(rel.y) > 0.2) { continue; }
        float age = m.x;
        float3 tint = marbleVoiceColor(int(m.y), u);
        float2 n = float2(cos(g.z), sin(g.z));
        float2 tangent = float2(-n.y, n.x);
        float halfLength = g.w * 0.5;
        // 音条贴着撞点、往背离球的一侧让出一点厚度。
        float2 mid = c - n * 0.004;
        float d = segmentDistance(q, mid - tangent * halfLength, mid + tangent * halfLength);
        float flash = exp(-age * 5.0) * (0.45 + 0.55 * m.z);
        float life = below(4.5, 7.0, age) * (0.4 + 0.6 * exp(-age * 0.6));
        float core = below(0.0028, 0.0048, d);
        // 顺着音条一道高光，像一根发光的琴键。
        float along = dot(q - mid, tangent) / max(halfLength, 0.001);
        float sheen = 0.75 + 0.25 * cos(along * 2.2);
        color += tint * (core * (0.42 + 1.5 * flash) * sheen + exp(-d * 85.0) * (0.06 + 0.6 * flash)) * life;
        if (age < 0.7) {
            float ring = exp(-sq((length(rel) - age * 0.12) * 160.0)) * sq(1.0 - age / 0.7) * (0.4 + 0.6 * m.z);
            color += tint * ring * 0.45;
        }
    }
    // 球和拖尾。
    for (int i = 0; i < ballCount; i++) {
        float4 ball = props[1 + i];
        float4 info = props[4 + i];
        float r = ball.z;
        float3 tint = marbleVoiceColor(int(ball.w), u);
        float2 previous = ball.xy;
        int points = min(int(info.z), 10);
        float trail = 0.0;
        // 拖尾按走过的路长算、最长 `trailReach`：一直往下掉时十个采样能拉出小半个画面，像一道竖线。离得比这还远的
        // 像素不必逐段量。
        const float trailReach = 0.09;
        if (length(q - ball.xy) > trailReach + r * 2.0) { points = 0; }
        float travelled = 0.0;
        for (int k = 0; k < points; k++) {
            float4 pair = props[8 + i * 5 + k / 2];
            float2 p = (k % 2 == 0) ? pair.xy : pair.zw;
            float step = length(p - previous);
            if (travelled + step > trailReach) {
                p = previous + (p - previous) * ((trailReach - travelled) / max(step, 1e-5));
                step = trailReach - travelled;
            }
            float fade = 1.0 - (travelled + step) / trailReach;
            float d = segmentDistance(q, previous, p);
            trail = max(trail, below(0.0, r * (0.15 + 0.7 * fade), d) * fade * fade);
            travelled += step;
            previous = p;
            if (travelled >= trailReach) { break; }
        }
        color += tint * trail * 0.4;
        float d = length(q - ball.xy);
        float hit = exp(-info.x * 7.0);
        float body = below(r * 0.86, r, d);
        float2 local = (q - ball.xy) / r;
        float shade = 0.5 + 0.5 * clamp(1.0 - length(local - float2(-0.35, -0.45)) * 0.8, 0.0, 1.0);
        float3 surface = tint * shade * (1.0 + 0.7 * hit) + float3(0.25) * hit;
        // 左上一点高光。
        surface += float3(1.0) * below(0.0, 0.32, length(local - float2(-0.38, -0.42))) * 0.5;
        color = mix(color, surface, body);
        color += tint * exp(-max(d - r, 0.0) / (r * (1.3 + 2.2 * hit))) * (0.22 + 0.6 * hit) * (1.0 - body);
    }
    color *= vignette(uv, 0.5);
    return float4(kineticFinish(color, uv, u), 1.0);
}

// ---- 下落轨道 ----
// props（float4）：[0] 小节里第几拍（0…4，没对上拍子时 -1）、一拍多长、拍子多可信、音符数；[1] 提前多久放上轨道、
// 进副歌的程度、打掉了多少个；[16…] 每个音符两组：光剑用的位置 x、y，离该打还有多久（负的是已经打掉了多久）、
// 力度，第几条轨道（小数部分乘 2 是这个音符自己的随机数）、手（+2 是歌词的字头）、劈的方向、放上轨道多久了。

// 轨道在画面上的样子：地平线、判定线、判定线处半宽（按画面高度算）。
static float3 highwayFrame(float aspect) {
    float portrait = aspect < 1.0 ? 1.0 : 0.0;
    float horizon = mix(0.14, 0.12, portrait);
    float judge = mix(0.86, 0.84, portrait);
    float halfWidth = min(0.42 * aspect, 0.46);
    return float3(horizon, judge, halfWidth);
}

// 判定线到最远处的纵深、镜头离判定线多远（越远透视越平：近处的音符不会大得占掉半个画面）。
constant float kHighwayFar = 6.5;
constant float kHighwayEye = 3.0;

fragment float4 kinetic_noteHighway(KineticVertexOut in [[stage_in]], constant KineticUniforms& u [[buffer(0)]], constant float4* props [[buffer(1)]]) {
    float2 uv = kineticZoom(in.uv, u);
    float aspect = u.frame.x / max(u.frame.y, 1.0);
    float t = u.frame.z;
    float2 q = float2(uv.x * aspect, uv.y);
    float3 a = u.colorA.rgb;
    float3 b = u.colorB.rgb;
    float3 frame = highwayFrame(aspect);
    float horizon = frame.x;
    float judge = frame.y;
    float halfWidth = frame.z;
    float cx = 0.5 * aspect;
    float measure = props[0].x;
    float period = max(props[0].y, 0.1);
    float lead = max(props[1].x, 0.1);
    float climax = props[1].y;
    float combo = min(props[1].z / 60.0, 1.0);
    int noteCount = min(int(props[0].w), 56);
    float zPerSecond = kHighwayFar / lead;
    float3 laneWarm = rhythmHandColor(0, u);
    float3 laneCool = rhythmHandColor(1, u);

    // 背景：深色，地平线上一层光，两侧的舞台光柱跟着鼓点亮。
    float3 color = mix(float3(0.008, 0.008, 0.018) + b * 0.06, a * 0.10 + float3(0.02, 0.012, 0.035), smoothstep(0.0, horizon + 0.1, uv.y) * below(horizon, 1.0, uv.y));
    color += mix(a, float3(1.0), 0.4) * exp(-abs(uv.y - horizon) * 24.0) * (0.18 + 0.3 * u.drive3.x);
    for (int side = 0; side < 2; side++) {
        float sx = side == 0 ? -1.0 : 1.0;
        float2 source = float2(cx + sx * (halfWidth * 1.9 + 0.05), -0.05);
        float2 rel = q - source;
        float sweep = sx * (0.28 + 0.12 * sin(u.drive3.y * 0.6 + float(side) * 2.0));
        float2 dir = normalize(float2(-sin(sweep), 1.0));
        float across = abs(rel.x * dir.y - rel.y * dir.x);
        float beam = exp(-across * 34.0) * step(0.0, dot(rel, dir)) * exp(-length(rel) * 1.2);
        color += (side == 0 ? laneWarm : laneCool) * beam * (0.08 + 0.35 * u.drive3.x + 0.15 * climax);
    }

    float s = (q.y - horizon) / (judge - horizon);
    if (s > 0.02) {
        float z = kHighwayEye * (1.0 / s - 1.0);
        float xw = (q.x - cx) / (halfWidth * s);
        float lanes = (xw + 1.0) * 2.0;
        float fog = exp(-max(z, 0.0) * 0.2) * smoothstep(0.02, 0.3, s);
        if (abs(xw) < 1.0) {
            // 路面：半透明的深色，越远越淡；连击越多两边越亮。
            color = mix(color, float3(0.012, 0.012, 0.026) + b * 0.05, 0.75 * fog);
            float laneLine = abs(fract(lanes + 0.5) - 0.5);
            color += mix(b, float3(1.0), 0.5) * below(0.0, fwidth(lanes) * 1.2, laneLine) * 0.22 * fog;
            // 拍线：每一拍一道横线迎面过来，每小节第一拍那道更亮。
            if (measure >= 0.0 && z >= 0.0) {
                float w = measure + z / zPerSecond / period;
                float beatLine = abs(fract(w + 0.5) - 0.5);
                float strong = fmod(floor(w + 0.5), 4.0) < 0.5 ? 1.0 : 0.0;
                float lineAlpha = below(0.0, fwidth(w) * 1.3, beatLine) * clamp(props[0].z * 1.5 - 0.4, 0.0, 1.0);
                color += mix(a, float3(1.0), 0.5) * lineAlpha * (0.12 + 0.22 * strong) * fog;
            }
        }
        // 两侧的导轨。
        float edge = abs(abs(xw) - 1.0) * halfWidth * s;
        color += mix(a, float3(1.0), 0.3) * exp(-edge * 380.0) * (0.45 + 0.4 * combo + 0.3 * u.drive3.x) * fog * step(-0.2, z);

        // 音符：从远处顺着轨道落到判定线。
        for (int i = noteCount - 1; i >= 0; i--) {
            float4 g = props[16 + i * 2];
            float4 m = props[17 + i * 2];
            float tth = g.z;
            int lane = int(m.x);
            float laneCenter = -0.75 + 0.5 * float(lane);
            float3 tint = (lane == 0 || lane == 3) ? laneWarm : laneCool;
            bool lyric = m.y >= 2.0;
            if (tth > -0.02) {
                float zn = max(tth, 0.0) * zPerSecond;
                float dz = abs(z - zn);
                float dx = abs(xw - laneCenter);
                if (dz < 0.6 && dx < 0.3) {
                    float appear = smoothstep(0.0, 0.25, m.w);
                    // 在路面上量的圆角块：横跨大半条轨道，纵深一小截。
                    float2 local = float2(dx / 0.21, dz / 0.16);
                    float box = length(max(local - float2(0.82, 0.55), 0.0)) + min(max(local.x - 0.82, local.y - 0.55), 0.0) - 0.18;
                    float fill = below(0.0, fwidth(box) * 1.5 + 0.001, box);
                    float rim = exp(-abs(box) * 9.0);
                    float3 body = mix(tint, float3(1.0), lyric ? 0.45 : 0.18);
                    float glowFront = 0.8 + 0.6 * below(0.0, 0.6, local.y) * step(z, zn);
                    color = mix(color, body * glowFront * (0.85 + 0.25 * g.w), fill * appear * fog);
                    color += tint * rim * 0.35 * appear * fog;
                }
            } else {
                // 打中：判定线上炸开一圈，整条轨道亮一下，往上溅火星。
                float age = -tth;
                if (age < 0.6) {
                    float bright = exp(-age * 7.0) * (0.6 + 0.4 * g.w);
                    float column = exp(-abs(xw - laneCenter) * 9.0) * step(abs(xw), 1.0) * exp(-z * 0.3) * step(-0.05, z);
                    color += tint * column * bright * 0.5;
                }
            }
        }
    }

    // 判定线和下面那排键：音符到时那条轨道的键被按下去、亮起来。
    float judgeGlow = exp(-abs(q.y - judge) * 140.0) * step(abs(q.x - cx), halfWidth);
    color += mix(a, float3(1.0), 0.6) * judgeGlow * (0.55 + 0.4 * u.drive3.x);
    for (int lane = 0; lane < 4; lane++) {
        float laneCenter = cx + (-0.75 + 0.5 * float(lane)) * halfWidth;
        float3 tint = (lane == 0 || lane == 3) ? laneWarm : laneCool;
        float press = 0.0;
        for (int i = 0; i < noteCount; i++) {
            float4 g = props[16 + i * 2];
            if (int(props[17 + i * 2].x) != lane) { continue; }
            float tth = g.z;
            press = max(press, smoothstep(-0.03, 0.0, -tth + 0.0) * below(0.06, 0.16, -tth) * step(tth, 0.03));
        }
        float keyHalf = halfWidth * 0.21;
        float2 keyCenter = float2(laneCenter, judge + 0.032 + 0.006 * press);
        float2 rel = q - keyCenter;
        float key = roundedBox(rel * float2(1.0, keyHalf / 0.022), keyHalf, keyHalf * 0.3);
        float keyFill = below(0.0, 0.002, key);
        float3 keyColor = mix(float3(0.05, 0.05, 0.08) + tint * 0.12, mix(tint, float3(1.0), 0.35) * 1.2, press);
        color = mix(color, keyColor, keyFill * 0.92);
        color += tint * exp(-max(key, 0.0) * 70.0) * (0.12 + 0.7 * press);
    }

    // 打中的那一下：判定线上一圈光环、一团闪光和往上溅的火星（画在最上层）。
    for (int i = 0; i < noteCount; i++) {
        float4 g = props[16 + i * 2];
        float4 m = props[17 + i * 2];
        float age = -g.z;
        if (age < 0.0 || age > 0.6) { continue; }
        int lane = int(m.x);
        float3 tint = (lane == 0 || lane == 3) ? laneWarm : laneCool;
        float2 burst = float2(cx + (-0.75 + 0.5 * float(lane)) * halfWidth, judge);
        float2 rel = q - burst;
        float2 squashed = rel * float2(1.0, 2.4);
        float ring = exp(-sq((length(squashed) - (0.02 + age * 0.22)) * 90.0)) * sq(1.0 - age / 0.6);
        float flash = exp(-length(squashed) * 26.0) * exp(-age * 10.0);
        color += mix(tint, float3(1.0), 0.4) * (ring * 0.8 + flash * 1.6) * (0.6 + 0.4 * g.w);
        float salt = hash11(fract(m.x) * 2.0 * 37.0 + float(lane) * 1.7);
        for (int k = 0; k < 7; k++) {
            float fk = float(k);
            float angle = -1.5708 + (hash11(salt * 13.0 + fk) - 0.5) * 2.2;
            float speed = 0.25 + 0.3 * hash11(salt * 29.0 + fk * 3.1);
            float2 p = burst + float2(cos(angle), sin(angle)) * speed * age + float2(0.0, 0.9 * age * age);
            float spark = exp(-length(q - p) * 420.0) * (1.0 - age / 0.6);
            color += mix(tint, float3(1.0), 0.6) * spark * 1.2;
        }
    }
    color *= vignette(uv, 0.55);
    return float4(kineticFinish(color, uv, u), 1.0);
}

// ---- 光剑劈方块 ----
// props 与下落轨道相同，另有 [2…5]、[6…9] 两只手的光剑这一刻和之前七个采样指着哪儿（打的那个平面上，x 向右、
// y 向上，两个点一组，最新的在前），[10] 两只手挥得多快。

constant float kSaberHitDepth = 1.5;
constant float kSaberSpeed = 8.0;
constant float kSaberCube = 0.2;

static float2 saberProject(float3 p, float2 center, float focal) {
    float z = max(p.z, 0.05);
    return float2(center.x + p.x / z * focal, center.y - p.y / z * focal);
}

// 劈的方向（画面上，y 向下），编号同 `ImmersiveKineticRhythmChart.Cut`。
static float2 saberCutVector(int cut) {
    switch (cut) {
        case 1: return float2(0.0, -1.0);
        case 2: return float2(-1.0, 0.0);
        case 3: return float2(1.0, 0.0);
        case 4: return float2(-0.7071, 0.7071);
        case 5: return float2(0.7071, 0.7071);
        case 6: return float2(-0.7071, -0.7071);
        case 7: return float2(0.7071, -0.7071);
        default: return float2(0.0, 1.0);
    }
}

static float2 saberAim(constant float4* props, int hand, int step) {
    float4 pair = props[2 + hand * 4 + step / 2];
    return (step % 2 == 0) ? pair.xy : pair.zw;
}

// 光剑的握把在镜头前下方，跟着手腕往挥的方向带一点。
static float3 saberHilt(int hand, float2 aim) {
    float side = hand == 0 ? -1.0 : 1.0;
    float2 rest = float2(side * 0.36, -0.82);
    return float3(side * 0.15 + (aim.x - rest.x) * 0.3, -0.5 + (aim.y - rest.y) * 0.25, 0.55);
}

static float3 saberTip(int hand, float2 aim) {
    float3 hilt = saberHilt(hand, aim);
    float3 target = float3(aim, kSaberHitDepth);
    return hilt + (target - hilt) * 1.25;
}

fragment float4 kinetic_saberSlash(KineticVertexOut in [[stage_in]], constant KineticUniforms& u [[buffer(0)]], constant float4* props [[buffer(1)]]) {
    float2 uv = kineticZoom(in.uv, u);
    float aspect = u.frame.x / max(u.frame.y, 1.0);
    float t = u.frame.z;
    float2 q = float2(uv.x * aspect, uv.y);
    float3 a = u.colorA.rgb;
    float3 b = u.colorB.rgb;
    float2 center = float2(0.5 * aspect, 0.48);
    float focal = min(1.35 * aspect, 1.1);
    float measure = props[0].x;
    float period = max(props[0].y, 0.1);
    float climax = props[1].y;
    int noteCount = min(int(props[0].w), 56);
    float3 warm = rhythmHandColor(0, u);
    float3 cool = rhythmHandColor(1, u);
    float beatPhase = measure >= 0.0 ? fract(measure) : 0.5;
    float onBeat = measure >= 0.0 ? exp(-beatPhase * 6.0) * props[0].z : u.drive3.x;

    // 场地：深色，远处一层雾光。
    float2 rel = q - center;
    float3 color = float3(0.006, 0.007, 0.016) + b * 0.05;
    color += mix(a, b, 0.5) * exp(-length(rel * float2(0.7, 1.6)) * 3.0) * 0.12;
    // 地面：往远处收拢的网格，两条霓虹灯带沿着两侧。
    if (q.y > center.y + 0.01) {
        float depth = 0.9 * focal / (q.y - center.y);
        float worldX = rel.x * depth / focal;
        float travel = u.motion.x * 2.0;
        float row = depth + travel;
        float rowLine = abs(fract(row * 0.8 + 0.5) - 0.5);
        float fade = exp(-depth * 0.12);
        color += mix(b, float3(1.0), 0.3) * below(0.0, fwidth(row * 0.8) * 1.4, rowLine) * 0.10 * fade;
        for (int side = 0; side < 2; side++) {
            float sx = side == 0 ? -1.0 : 1.0;
            float strip = abs(worldX - sx * 1.1);
            float width = fwidth(worldX) * 1.5;
            color += (side == 0 ? warm : cool) * (below(0.0, width + 0.02, strip) * 0.6 + exp(-strip * 6.0) * 0.12) * fade * (0.5 + 0.7 * onBeat);
        }
    }
    // 远处一圈圈方形的灯环：每一拍往镜头这边推近一截，慢慢转。
    for (int k = 0; k < 6; k++) {
        float fk = float(k);
        float ringZ = 3.0 + fk * 1.6 - (measure >= 0.0 ? beatPhase : fract(t * 0.5)) * 1.6;
        float halfSize = 1.05 / ringZ * focal;
        float2 p = rotate2(rel, 0.08 * sin(t * 0.3 + fk * 0.7) + (climax > 0.5 ? 0.1 * fk : 0.0));
        float square = abs(max(abs(p.x), abs(p.y)) - halfSize);
        float fade = smoothstep(2.4, 3.6, ringZ) * below(9.0, 11.0, ringZ);
        color += mix(k % 2 == 0 ? warm : cool, float3(1.0), 0.25) * exp(-square * 260.0 * ringZ / 3.0) * fade * (0.18 + 0.5 * onBeat);
    }

    // 方块：从远处飞过来，远的先画、近的盖在上面。打掉以后两半往两边飞开。
    for (int i = noteCount - 1; i >= 0; i--) {
        float4 g = props[16 + i * 2];
        float4 m = props[17 + i * 2];
        float tth = g.z;
        int hand = int(fmod(m.y, 2.0));
        bool lyric = m.y >= 2.0;
        float3 tint = hand == 0 ? warm : cool;
        if (tth > 0.0) {
            float z = kSaberHitDepth + tth * kSaberSpeed;
            float2 c = saberProject(float3(g.x, g.y, z), center, focal);
            float cubeHalf = kSaberCube * 0.5 / z * focal;
            float2 local = q - c;
            if (abs(local.x) > cubeHalf * 3.0 || abs(local.y) > cubeHalf * 3.0) { continue; }
            float2 cutDir = saberCutVector(int(m.z));
            float appear = smoothstep(0.0, 0.25, m.w) * below(12.0, 13.5, z);
            // 后面那一面：往消失点那边缩一点，画出方块的侧面。
            float2 back = saberProject(float3(g.x, g.y, z + kSaberCube), center, focal);
            float backHalf = kSaberCube * 0.5 / (z + kSaberCube) * focal;
            float sideBox = 1e3;
            for (int s = 0; s <= 4; s++) {
                float f = float(s) / 4.0;
                sideBox = min(sideBox, roundedBox(q - mix(c, back, f), mix(cubeHalf, backHalf, f), mix(cubeHalf, backHalf, f) * 0.18));
            }
            float face = roundedBox(local, cubeHalf, cubeHalf * 0.18);
            float sideFill = below(0.0, 0.0015, sideBox);
            float faceFill = below(0.0, 0.0015, face);
            color = mix(color, tint * 0.35, sideFill * appear);
            float3 faceColor = mix(tint * 0.55, tint * 1.05, smoothstep(cubeHalf, -cubeHalf, local.y + local.x * 0.3));
            color = mix(color, faceColor, faceFill * appear);
            color += mix(tint, float3(1.0), 0.4) * exp(-abs(face) / max(cubeHalf * 0.08, 0.0008)) * 0.6 * appear;
            // 面上的箭头（歌词的字头是一个点：哪个方向劈都行）。
            float2 arrowSpace = float2(dot(local, float2(-cutDir.y, cutDir.x)), dot(local, cutDir)) / cubeHalf;
            float mark;
            if (lyric) {
                mark = below(0.2, 0.28, length(arrowSpace));
            } else {
                // 一道折角朝劈的方向的人字。
                float chevron = arrowSpace.y + 0.9 * abs(arrowSpace.x) - 0.28;
                mark = below(0.09, 0.13, abs(chevron)) * below(0.5, 0.56, abs(arrowSpace.x));
            }
            color = mix(color, float3(1.0), mark * faceFill * appear * 0.95);
        } else {
            float age = -tth;
            if (age > 0.6) { continue; }
            float z = kSaberHitDepth - age * 0.5;
            float2 c = saberProject(float3(g.x, g.y, z), center, focal);
            float cubeHalf = kSaberCube * 0.5 / z * focal;
            // 碎块和火星飞得最远的地方以外不必算。
            if (length(q - c) > cubeHalf * 5.0 + focal * (0.85 * age + 0.2 * age * age) + 0.02) { continue; }
            float2 cutDir = saberCutVector(int(m.z));
            float2 perp = float2(-cutDir.y, cutDir.x);
            float fade = below(0.08, 0.32, age);
            // 一刀两半：沿着刀口的两侧往外飞、各自打着转，往下掉。
            for (int s = 0; s < 2; s++) {
                float sx = s == 0 ? 1.0 : -1.0;
                float2 offset = perp * sx * cubeHalf * (0.12 + age * 3.2) + cutDir * age * cubeHalf * 1.2 + float2(0.0, 0.5 * age * age);
                float angle = sx * age * 4.0;
                float2 local = rotate2(q - (c + offset), -angle);
                float box = roundedBox(local, cubeHalf, cubeHalf * 0.18);
                float side = dot(local, perp) * sx;
                float piece = below(0.0, 0.0015, max(box, -side));
                color = mix(color, tint * 0.8, piece * fade);
                color += tint * exp(-abs(max(box, -side)) / max(cubeHalf * 0.06, 0.0008)) * fade * 0.5;
                // 切面亮一下。
                color += float3(1.0) * exp(-abs(side) / max(cubeHalf * 0.05, 0.0006)) * step(box, 0.0) * exp(-age * 12.0) * 0.9;
            }
            // 刀口一道光，和沿着刀口飞出去的火星。
            float slash = exp(-abs(dot(q - c, perp)) * 600.0) * below(cubeHalf * 1.6, cubeHalf * 2.6, abs(dot(q - c, cutDir))) * exp(-age * 14.0);
            color += mix(tint, float3(1.0), 0.5) * slash * 1.5;
            float salt = hash11(fract(m.x) * 2.0 * 37.0 + floor(m.x) * 3.3);
            for (int k = 0; k < 8; k++) {
                float fk = float(k);
                float spread = (hash11(salt * 17.0 + fk) - 0.5) * 1.6;
                float2 dir = normalize(cutDir * (k % 2 == 0 ? 1.0 : -0.4) + perp * spread);
                float speed = (0.35 + 0.45 * hash11(salt * 31.0 + fk * 1.7)) * focal;
                float2 p = c + dir * speed * age + float2(0.0, 0.6 * age * age);
                color += mix(tint, float3(1.0), 0.6) * exp(-length(q - p) * 380.0) * below(0.2, 0.5, age) * 1.4;
            }
        }
    }

    // 两把光剑和挥过的拖影。
    for (int hand = 0; hand < 2; hand++) {
        float3 tint = hand == 0 ? warm : cool;
        float swing = clamp(props[10][hand] / 6.0, 0.0, 1.0);
        float2 aim0 = saberAim(props, hand, 0);
        float3 hilt3 = saberHilt(hand, aim0);
        float3 tip3 = saberTip(hand, aim0);
        // 拖影：相邻两个采样之间那一片，靠刀尖那段才有，越早越淡。挥得慢时看不出拖影，整段不算。
        if (swing > 0.05) {
            float ribbon = 0.0;
            float3 hPrev = saberHilt(hand, aim0);
            float3 tPrev = saberTip(hand, aim0);
            float2 innerPrev = saberProject(mix(hPrev, tPrev, 0.45), center, focal);
            float2 outerPrev = saberProject(tPrev, center, focal);
            for (int k = 1; k < 8; k++) {
                float2 aim = saberAim(props, hand, k);
                float3 h = saberHilt(hand, aim);
                float3 tipPoint = saberTip(hand, aim);
                float2 inner = saberProject(mix(h, tipPoint, 0.45), center, focal);
                float2 outer = saberProject(tipPoint, center, focal);
                float inside = max(insideTriangle(q, innerPrev, outerPrev, outer), insideTriangle(q, innerPrev, outer, inner));
                ribbon = max(ribbon, inside * (1.0 - float(k - 1) / 7.0));
                innerPrev = inner;
                outerPrev = outer;
            }
            color += mix(tint, float3(1.0), 0.25) * ribbon * ribbon * (0.25 + 0.55 * swing);
        }
        float2 hilt = saberProject(hilt3, center, focal);
        float2 tip = saberProject(tip3, center, focal);
        float2 ba = tip - hilt;
        float h = clamp(dot(q - hilt, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
        float d = length(q - hilt - ba * h);
        // 越靠近镜头越粗。
        float width = mix(0.012, 0.004, h) * focal;
        float core = below(width * 0.35, width * 0.6, d);
        color = mix(color, float3(1.0), core);
        color += tint * exp(-d / (width * (1.4 + 0.8 * swing))) * 0.9;
    }
    // 拍上整个场子闪一下。
    color += mix(a, float3(1.0), 0.4) * onBeat * 0.035;
    color *= vignette(uv, 0.55);
    return float4(kineticFinish(color, uv, u), 1.0);
}
"""#
}
