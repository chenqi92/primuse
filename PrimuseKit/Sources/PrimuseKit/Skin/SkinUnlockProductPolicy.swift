import Foundation

/// 解锁项与商店产品之间的换算。
///
/// 样式只认 `unlockID`(`SkinAccess.unlockable`),不认商店;商店只认产品标识。两边的换算
/// 集中在这里:换一种发放方式(比如一个产品解锁全部样式)不必动样式定义,也不必动界面。
public enum SkinUnlockProductPolicy {
    /// 产品标识 = 前缀 + unlockID,例如 `com.welape.yuanyin.skin.midnight`。
    public static let productPrefix = "com.welape.yuanyin."
    /// 拥有这一项,等于解锁目录里全部需要解锁的样式。
    public static let allAccessProductID = "com.welape.yuanyin.skin.all"

    public static func productID(
        forUnlockID unlockID: String,
        prefix: String = productPrefix
    ) -> String {
        prefix + unlockID
    }

    public static func unlockID(
        forProductID productID: String,
        prefix: String = productPrefix
    ) -> String? {
        guard productID.hasPrefix(prefix) else { return nil }
        let unlockID = String(productID.dropFirst(prefix.count))
        return unlockID.isEmpty ? nil : unlockID
    }

    /// 目录里需要解锁的项,无重复,顺序与目录一致。
    public static func unlockIDs(in catalog: [SkinDefinition]) -> [String] {
        var seen: Set<String> = []
        return catalog.compactMap(\.access.unlockID).filter { seen.insert($0).inserted }
    }

    /// 需要向商店查询的产品。目录里没有需要解锁的样式时为空 —— 调用方据此完全不碰商店。
    public static func productIDs(
        for catalog: [SkinDefinition],
        prefix: String = productPrefix,
        allAccessProductID: String? = allAccessProductID
    ) -> [String] {
        let unlockIDs = unlockIDs(in: catalog)
        guard !unlockIDs.isEmpty else { return [] }
        var productIDs = unlockIDs.map { productID(forUnlockID: $0, prefix: prefix) }
        if let allAccessProductID, !productIDs.contains(allAccessProductID) {
            productIDs.append(allAccessProductID)
        }
        return productIDs
    }

    /// 已拥有的产品换算成已解锁的项。不认识的产品(更新版本才有的样式)直接忽略。
    public static func unlockedIDs(
        ownedProductIDs: Set<String>,
        catalog: [SkinDefinition],
        prefix: String = productPrefix,
        allAccessProductID: String? = allAccessProductID
    ) -> Set<String> {
        let known = unlockIDs(in: catalog)
        if let allAccessProductID, ownedProductIDs.contains(allAccessProductID) {
            return Set(known)
        }
        return Set(known.filter { ownedProductIDs.contains(productID(forUnlockID: $0, prefix: prefix)) })
    }
}
