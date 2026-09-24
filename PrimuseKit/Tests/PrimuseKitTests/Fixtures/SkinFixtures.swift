import Foundation
@testable import PrimuseKit

/// 测试用的皮肤。
///
/// 正式目录(`SkinCatalog.all`)里现在只有随 App 提供的经典与极简,待解锁的路径(选择、回落、
/// 权益换算、配套可用性)要靠这里的夹具来走。它们都只换了 token,不是真正的皮肤,不会出现在任何构建里。
enum SkinFixtures {
    /// 两套待解锁的夹具。
    static var unlockable: [SkinDefinition] { [midnight, nocturne] }

    /// 正式目录加上待解锁的夹具,用来断言「目录里有待解锁皮肤时」的行为。
    static var catalogWithUnlockable: [SkinDefinition] { SkinCatalog.all + unlockable }
}
