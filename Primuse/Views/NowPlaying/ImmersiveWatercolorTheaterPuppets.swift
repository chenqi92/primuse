import CoreGraphics
import Foundation
import ImageIO
import PrimuseKit

// 「水彩小剧场」的四个纸偶：从包里的 WatercolorTheater/manifest.json 读骨骼、叠放顺序与表情插槽，
// 分件图在后台解码，顺手为每一件画一张往外扩了几像素的墨色剪影（画外描边用：先把所有剪影垫在底下，
// 再把彩色的部件盖上去，只剩外轮廓露出一圈墨线）。资源由 scripts/build-mascot-parts.py 从角色母版生成。

// MARK: - 清单

struct ImmersiveTheaterManifest: Decodable, Sendable {
    struct Bone: Decodable, Sendable {
        let name: String
        let parent: String?
        let pivot: [Double]
        let axis: Double
        let counter: Bool
    }

    struct Part: Decodable, Sendable {
        let file: String
        /// 母版坐标里的 x、y、宽、高。
        let rect: [Double]
        let layer: Int
        let temporary: Bool?
    }

    struct OrderItem: Decodable, Sendable {
        let part: String?
        let slot: String?
        let bone: String
    }

    struct SlotItem: Decodable, Sendable {
        let part: String
        let bone: String?
    }

    struct Character: Decodable, Sendable {
        let bones: [Bone]
        let parts: [String: Part]
        let order: [OrderItem]
        let slots: [String: [String: [SlotItem]]]
        let anchors: [String: [Double]]
        let tearFrom: [[Double]]
    }

    let format: Int
    let canvas: Double
    let footY: Double
    let characters: [String: Character]

    static let folder = "WatercolorTheater"

    /// 包里的清单，第一次用到时读一次。
    static let bundled: ImmersiveTheaterManifest? = {
        guard let url = Bundle.main.url(forResource: "manifest", withExtension: "json", subdirectory: folder),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ImmersiveTheaterManifest.self, from: data)
    }()
}

// MARK: - 纸偶

/// 一个角色的骨骼、部件图和锚点，读进来以后不再改。
final class ImmersiveTheaterPuppet: @unchecked Sendable {
    struct Bone {
        let name: String
        let parent: Int?
        let pivot: CGPoint
        let axis: Double
        let counter: Bool
    }

    struct Sprite {
        let image: CGImage
        /// 母版坐标里铺的范围。
        let rect: CGRect
        /// 外扩的墨色剪影，铺得比部件大一圈。
        let outline: CGImage?
        let outlineRect: CGRect
        /// 描外轮廓时要不要垫它的剪影：补画的表情和很小的件（鼻子、胡须）都在大件里面，垫了也看不见。
        let outlines: Bool
        /// 错开的淡影只用大件拼出个轮廓就够了。
        let castsShadow: Bool
    }

    /// 叠放顺序里的一项：固定部件，或者按表情换的插槽。
    enum Layer {
        case part(String, bone: Int)
        case slot(String, bone: Int)
    }

    struct SlotEntry {
        let part: String
        let bone: Int?
    }

    let character: ImmersiveTheaterCharacter
    let bones: [Bone]
    let boneIndex: [String: Int]
    let sprites: [String: Sprite]
    let layers: [Layer]
    let slots: [String: [String: [SlotEntry]]]
    let anchors: [String: CGPoint]
    let tearFrom: [CGPoint]
    /// 点角色时拿来判断有没有点中的几件（身体、头）。
    let hitParts: [(part: String, bone: Int)]

    init?(character: ImmersiveTheaterCharacter, manifest: ImmersiveTheaterManifest.Character) {
        self.character = character
        var index: [String: Int] = [:]
        var bones: [Bone] = []
        for bone in manifest.bones {
            let parent = bone.parent.flatMap { index[$0] }
            let pivot = CGPoint(x: bone.pivot.first ?? 800, y: bone.pivot.count > 1 ? bone.pivot[1] : 1460)
            index[bone.name] = bones.count
            bones.append(Bone(name: bone.name, parent: parent, pivot: pivot, axis: bone.axis, counter: bone.counter))
        }
        guard let root = index["root"] else { return nil }
        self.bones = bones
        boneIndex = index

        var sprites: [String: Sprite] = [:]
        for (id, part) in manifest.parts {
            guard part.rect.count == 4,
                  let image = Self.loadImage(named: part.file) else { continue }
            let rect = CGRect(x: part.rect[0], y: part.rect[1], width: part.rect[2], height: part.rect[3])
            let area = Double(rect.width * rect.height)
            let outlines = part.temporary != true && area >= 4000
            let outline = outlines ? Self.outline(of: image, rect: rect) : nil
            sprites[id] = Sprite(
                image: image,
                rect: rect,
                outline: outline?.image,
                outlineRect: outline?.rect ?? rect,
                outlines: outlines,
                castsShadow: outlines && area >= 40000
            )
        }
        guard !sprites.isEmpty else { return nil }
        self.sprites = sprites

        var layers: [Layer] = []
        for item in manifest.order {
            let bone = index[item.bone] ?? root
            if let part = item.part {
                layers.append(.part(part, bone: bone))
            } else if let slot = item.slot {
                layers.append(.slot(slot, bone: bone))
            }
        }
        self.layers = layers
        var slots: [String: [String: [SlotEntry]]] = [:]
        for (slot, states) in manifest.slots {
            var table: [String: [SlotEntry]] = [:]
            for (state, items) in states {
                table[state] = items.map { item in
                    SlotEntry(part: item.part, bone: item.bone.flatMap { index[$0] })
                }
            }
            slots[slot] = table
        }
        self.slots = slots
        var anchors: [String: CGPoint] = [:]
        for (name, value) in manifest.anchors where value.count == 2 {
            anchors[name] = CGPoint(x: value[0], y: value[1])
        }
        self.anchors = anchors
        tearFrom = manifest.tearFrom.compactMap { value in
            value.count == 2 ? CGPoint(x: value[0], y: value[1]) : nil
        }
        hitParts = ["body", "head_base"].compactMap { (name: String) -> (part: String, bone: Int)? in
            guard sprites[name] != nil else { return nil }
            for layer in layers {
                if case let .part(part, bone) = layer, part == name { return (name, bone) }
            }
            return nil
        }
    }

    func anchor(_ name: String) -> CGPoint {
        anchors[name] ?? CGPoint(x: 800, y: 700)
    }

    func bone(named name: String) -> Int {
        boneIndex[name] ?? 0
    }

    // MARK: 骨骼

    /// 每根骨骼的变换（母版坐标），照原型的 evalBones：先移回轴心，按骨骼方向拉伸、转、抵消父件的拉伸，
    /// 再挪到轴心加位移，最后接到父件上。
    func evaluate(_ pose: ImmersiveTheaterPose) -> [CGAffineTransform] {
        var result: [CGAffineTransform] = []
        result.reserveCapacity(bones.count)
        for bone in bones {
            let params = pose.bones[bone.name] ?? ImmersiveTheaterBonePose()
            var local = CGAffineTransform(
                translationX: bone.pivot.x + CGFloat(params.tx),
                y: bone.pivot.y + CGFloat(params.ty)
            )
            if bone.counter, let parent = bone.parent {
                let parentParams = pose.bones[bones[parent].name] ?? ImmersiveTheaterBonePose()
                if parentParams.stretchA != 1 || parentParams.stretchB != 1 {
                    local = Self.mul(local, Self.axisScale(
                        bones[parent].axis,
                        1 / max(parentParams.stretchA, 0.05),
                        1 / max(parentParams.stretchB, 0.05)
                    ))
                }
            }
            if params.rotation != 0 {
                local = Self.mul(local, CGAffineTransform(rotationAngle: params.rotation))
            }
            if params.stretchA != 1 || params.stretchB != 1 {
                local = Self.mul(local, Self.axisScale(bone.axis, params.stretchA, params.stretchB))
            }
            local = Self.mul(local, CGAffineTransform(translationX: -bone.pivot.x, y: -bone.pivot.y))
            if let parent = bone.parent, parent < result.count {
                result.append(Self.mul(result[parent], local))
            } else {
                result.append(local)
            }
        }
        return result
    }

    /// 原型的 M.mul(m, n)：先做 n 再做 m。
    static func mul(_ m: CGAffineTransform, _ n: CGAffineTransform) -> CGAffineTransform {
        n.concatenating(m)
    }

    /// 沿 `axis` 方向拉伸 `along` 倍、垂直方向 `across` 倍。
    static func axisScale(_ axis: Double, _ along: Double, _ across: Double) -> CGAffineTransform {
        mul(mul(CGAffineTransform(rotationAngle: axis), CGAffineTransform(scaleX: along, y: across)), CGAffineTransform(rotationAngle: -axis))
    }

    /// 按表情把叠放顺序展开成这一帧要画的部件（部件名、骨骼、透明度）。
    func drawList(for expression: ImmersiveTheaterExpression) -> [(part: String, bone: Int, alpha: Double)] {
        var items: [(part: String, bone: Int, alpha: Double)] = []
        items.reserveCapacity(layers.count + 4)
        for layer in layers {
            switch layer {
            case let .part(part, bone):
                items.append((part, bone, 1))
            case let .slot(slot, bone):
                guard let table = slots[slot] else { continue }
                let entries: [SlotEntry]
                let alpha: Double
                switch slot {
                case "blush":
                    guard expression.blush > 0.05 else { continue }
                    entries = table["on"] ?? []
                    alpha = min(max(expression.blush, 0), 1)
                case "eyes":
                    entries = table[expression.eyes.rawValue] ?? table["open"] ?? []
                    alpha = 1
                default:
                    entries = table[expression.mouth.rawValue] ?? table["rest"] ?? []
                    alpha = 1
                }
                for entry in entries {
                    items.append((entry.part, entry.bone ?? bone, alpha))
                }
            }
        }
        return items
    }

    // MARK: 读图

    static func loadImage(named file: String) -> CGImage? {
        let name = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension
        guard let url = Bundle.main.url(
            forResource: name,
            withExtension: ext.isEmpty ? "png" : ext,
            subdirectory: ImmersiveTheaterManifest.folder
        ),
            let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }

    /// 墨色剪影：按一半的分辨率画，把部件在一圈十二个方向上各错开几像素叠起来，再整片涂成墨色。
    static func outline(of image: CGImage, rect: CGRect) -> (image: CGImage, rect: CGRect)? {
        let scale = 0.5
        let radius = 4.0
        let width = Int((Double(image.width) * scale).rounded(.up)) + Int(radius * 2) + 2
        let height = Int((Double(image.height) * scale).rounded(.up)) + Int(radius * 2) + 2
        guard width > 4, height > 4, let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let drawn = CGRect(
            x: radius + 1,
            y: radius + 1,
            width: Double(image.width) * scale,
            height: Double(image.height) * scale
        )
        context.interpolationQuality = .low
        for step in 0..<12 {
            let angle = Double(step) / 12 * 2 * Double.pi
            context.draw(image, in: drawn.offsetBy(dx: cos(angle) * radius, dy: sin(angle) * radius))
        }
        context.draw(image, in: drawn)
        context.setBlendMode(.sourceIn)
        context.setFillColor(red: 0.075, green: 0.065, blue: 0.085, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let outline = context.makeImage() else { return nil }
        // 剪影比部件大出来的那一圈，换算回母版坐标。
        let unitsPerPixel = Double(rect.width) / max(Double(image.width) * scale, 1)
        let pad = (radius + 1) * unitsPerPixel
        let outlineRect = CGRect(
            x: Double(rect.minX) - pad,
            y: Double(rect.minY) - pad,
            width: Double(width) * unitsPerPixel,
            height: Double(height) * unitsPerPixel
        )
        return (outline, outlineRect)
    }
}

/// 读过的纸偶留着：换歌只换在场的角色，用过的不再读。
@MainActor
enum ImmersiveTheaterPuppetLibrary {
    private static var loaded: [ImmersiveTheaterCharacter: ImmersiveTheaterPuppet] = [:]
    private static var inFlight: [ImmersiveTheaterCharacter: Task<ImmersiveTheaterPuppet?, Never>] = [:]

    static func cached(_ character: ImmersiveTheaterCharacter) -> ImmersiveTheaterPuppet? {
        loaded[character]
    }

    /// 读一个角色（后台解码），读过的直接给。
    static func load(_ character: ImmersiveTheaterCharacter) async -> ImmersiveTheaterPuppet? {
        if let hit = loaded[character] { return hit }
        let task: Task<ImmersiveTheaterPuppet?, Never>
        if let running = inFlight[character] {
            task = running
        } else {
            task = Task.detached(priority: .userInitiated) {
                guard let manifest = ImmersiveTheaterManifest.bundled,
                      let entry = manifest.characters[character.rawValue] else { return nil }
                return ImmersiveTheaterPuppet(character: character, manifest: entry)
            }
            inFlight[character] = task
        }
        let puppet = await task.value
        inFlight[character] = nil
        if let puppet { loaded[character] = puppet }
        return loaded[character] ?? puppet
    }
}
