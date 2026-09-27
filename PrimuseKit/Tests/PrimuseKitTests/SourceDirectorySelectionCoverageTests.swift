import Testing
@testable import PrimuseKit

/// 勾了上级目录(或整个音乐源)后,下面的目录 —— 包括源上后来新建的 —— 要
/// 显示成「已包含」,取消上级后又能单独勾选;保存前去掉被上级覆盖的下级。
@Suite("Source directory selection coverage")
struct SourceDirectorySelectionCoverageTests {
    private typealias Policy = SourceDirectorySelectionPolicy

    @Test("A folder added under a selected root reports as included")
    func newFolderUnderRootIsIncluded() {
        for type in [MusicSourceType.smb, .webdav, .drime] {
            #expect(Policy.selectionState(of: "/New", in: ["/"], for: type) == .included(by: "/"))
        }
        #expect(Policy.selectionState(of: "/Old", in: ["/"], for: .smb) == .included(by: "/"))
        #expect(Policy.selectionState(of: "/", in: ["/"], for: .smb) == .selected)
    }

    @Test("The S3 bucket root is an empty prefix and covers every child prefix")
    func s3EmptyRootCoversChildren() {
        #expect(Policy.isRootPath(""))
        #expect(Policy.isRootPath("/"))
        #expect(Policy.selectionState(of: "New/", in: [""], for: .s3) == .included(by: ""))
        #expect(Policy.selectionState(of: "Albums/Live/", in: [""], for: .s3) == .included(by: ""))
        #expect(Policy.selectionState(of: "", in: [""], for: .s3) == .selected)
        // 电视端给 S3 根存的是 "/",手机端浏览器的根行是 ""。
        #expect(Policy.selectionState(of: "", in: ["/"], for: .s3) == .selected)
        #expect(Policy.storedRootSelection(in: ["Music/", ""]) == "")
        #expect(Policy.storedRootSelection(in: ["Music/"]) == nil)
    }

    @Test("Unchecking the ancestor makes its children independently selectable")
    func uncheckingAncestorReleasesChildren() {
        var selections = ["/"]
        selections = Policy.normalizedSelections(
            Policy.toggledSelection(selections, path: "/"),
            for: .webdav
        )
        #expect(selections.isEmpty)
        #expect(Policy.selectionState(of: "/New", in: selections, for: .webdav) == .unselected)

        selections = Policy.normalizedSelections(
            Policy.toggledSelection(selections, path: "/New"),
            for: .webdav
        )
        #expect(selections == ["/New"])
        #expect(Policy.selectionState(of: "/New", in: selections, for: .webdav) == .selected)
    }

    @Test("A selected non-root folder covers its descendants")
    func nonRootAncestorCoverage() {
        #expect(Policy.selectionState(of: "/Music/New", in: ["/Music"], for: .smb) == .included(by: "/Music"))
        #expect(Policy.selectionState(of: "/Music/A/B", in: ["/Music"], for: .smb) == .included(by: "/Music"))
        #expect(Policy.selectionState(of: "/Music", in: ["/Music"], for: .smb) == .selected)
        // 名字相同前缀的兄弟目录不算下级。
        #expect(Policy.selectionState(of: "/Musical", in: ["/Music"], for: .smb) == .unselected)
        #expect(Policy.selectionState(of: "/Other", in: ["/Music"], for: .smb) == .unselected)
        #expect(Policy.covers("/Music", "/Music/New", for: .smb))
        #expect(Policy.covers("/Music", "/Music", for: .smb))
        #expect(!Policy.covers("/Music/New", "/Music", for: .smb))
        #expect(!Policy.covers("/Music", "/Musical", for: .smb))
    }

    @Test("The outermost covering selection is reported")
    func reportsOutermostAncestor() {
        let selections = ["/Music/Albums", "/Music"]
        #expect(Policy.selectionState(of: "/Music/Albums/Live", in: selections, for: .smb) == .included(by: "/Music"))
        #expect(Policy.selectionState(of: "/Music/Albums/Live", in: selections + ["/"], for: .smb) == .included(by: "/"))
        // 旧数据里上下级同时存着:下级自己仍显示为已勾选,可以取消。
        #expect(Policy.selectionState(of: "/Music/Albums", in: selections, for: .smb) == .selected)
    }

    @Test("Trailing slashes do not change coverage or identity")
    func trailingSlashes() {
        #expect(Policy.selectionState(of: "/Music/New/", in: ["/Music/"], for: .smb) == .included(by: "/Music/"))
        #expect(Policy.selectionState(of: "/Music", in: ["/Music/"], for: .smb) == .selected)
        #expect(Policy.selectionState(of: "Music/Live/", in: ["Music/"], for: .s3) == .included(by: "Music/"))
        #expect(Policy.selectionState(of: "/Music", in: ["Music/"], for: .s3) == .selected)
        #expect(Policy.toggledSelection(["Music/"], path: "/Music").isEmpty)
        #expect(Policy.toggledSelection(["/Music/"], path: "/Music").isEmpty)
        #expect(Policy.isSamePath("Music/", "/Music"))
        #expect(Policy.isSamePath("", "/"))
        #expect(!Policy.isSamePath("/Music", "/Musical"))
    }

    @Test("Opaque item identifiers rely on the browsing ancestor chain")
    func opaqueIdentifiersUseAncestorChain() {
        // ID 寻址的网盘看不出上下级:只有浏览路径能说明 "child" 在 "parent" 里。
        #expect(Policy.selectionState(of: "child", in: ["parent"], for: .googleDrive) == .unselected)
        #expect(Policy.selectionState(
            of: "child",
            in: ["parent"],
            ancestors: ["/", "parent"],
            for: .googleDrive
        ) == .included(by: "parent"))
        #expect(Policy.selectionState(
            of: "grandchild",
            in: ["child", "parent"],
            ancestors: ["/", "parent", "child"],
            for: .googleDrive
        ) == .included(by: "parent"))
        // 根目录对任何源都覆盖一切。
        #expect(Policy.selectionState(of: "4815", in: ["/"], for: .drime) == .included(by: "/"))
        // 浏览路径同样适用于层级路径的源,和前缀判断一致。
        #expect(Policy.selectionState(
            of: "/Music/New",
            in: ["/Music"],
            ancestors: ["/", "/Music"],
            for: .smb
        ) == .included(by: "/Music"))
    }

    @Test("Normalization drops descendants but keeps siblings")
    func normalizationDropsDescendantsKeepsSiblings() {
        #expect(Policy.normalizedSelections(["/Music", "/Music/New"], for: .smb) == ["/Music"])
        #expect(Policy.normalizedSelections(["/Music/New", "/Music"], for: .webdav) == ["/Music"])
        #expect(Policy.normalizedSelections(["/A", "/B", "/New"], for: .smb) == ["/A", "/B", "/New"])
        #expect(Policy.normalizedSelections(["/Music", "/Musical"], for: .smb) == ["/Music", "/Musical"])
        #expect(Policy.normalizedSelections(
            ["/Music/Albums/Live", "/Music", "/Music/Albums", "/Podcasts", "/Podcasts/2026/"],
            for: .smb
        ) == ["/Music", "/Podcasts"])
        #expect(Policy.normalizedSelections(["/Music", "/", "Radio"], for: .smb) == ["/"])
        #expect(Policy.normalizedSelections(["Music/", "Music/Live/", "Albums/"], for: .s3) == ["Music/", "Albums/"])
        // 同一个目录的两种写法只留第一条。
        #expect(Policy.normalizedSelections(["Music/", "/Music"], for: .s3) == ["Music/"])
        // 不认识层级的源不按前缀猜,只按根去重。
        #expect(Policy.normalizedSelections(["a", "a/b"], for: .googleDrive) == ["a", "a/b"])
        #expect(Policy.normalizedSelections(["a", "/"], for: .googleDrive) == ["/"])
        #expect(Policy.normalizedSelections([], for: .smb).isEmpty)
    }

    @Test("Tapping a new folder while an ancestor is selected cannot silently drop it")
    func togglingIncludedFolderKeepsAncestor() {
        // 选择页会禁用「已包含」行的勾选框;即使调用到了,结果也只是保持上级。
        let toggled = Policy.normalizedSelections(
            Policy.toggledSelection(["/"], path: "/New"),
            for: .smb
        )
        #expect(toggled == ["/"])
        #expect(Policy.selectionState(of: "/New", in: toggled, for: .smb) == .included(by: "/"))
    }
}
