import Foundation

// MARK: - 回到前台时「歌曲模型不在内存里就不先占用」的判断,等到判得了再判(DL3)

extension MusicLibrary {
    /// 不装歌曲模型的启动还在第一次发布之前:这时 `isUsable`、`isReady` 都是假,「模型在不在内存里」还答不了。
    /// 照「在内存里」那一支走(`onReady(holding:)`)就是为一个还没答的问题把模型装回来。开关关着时恒为假。
    var isInUnloadedLaunchWindow: Bool {
        launchMayPublishWithoutTheSongModel && readiness == .preparing
    }

    /// 「模型不在内存里就走目录那条路,否则 `onReady(holding:)`」这类判断:不装模型的启动还没到「可用」时,
    /// 等到可用(不是就绪)再判 —— 到时候是只装小状态的那次发布(`isUsable && !isReady`),或者启动退回了整份装载
    /// (`isReady`,等可用的随那次发布一起放行)。别的时候当场判,与以前一样;开关关着时永远当场判。
    /// 真机第 5 轮:装新构建后的第一次启动,场景比「可用」早 600 ms 变成活跃,回前台的续扫判断走了装模型那一支,
    /// 占用在可用那一刻变成 `load begin reason=hold scan at launch`(平常的启动只赢这场赛跑 43–44 ms)。
    func decideOnceUsableInTheLaunchWindow(_ decide: @escaping @MainActor () -> Void) {
        if isInUnloadedLaunchWindow, !isUsable {
            onUsable(decide)
        } else {
            decide()
        }
    }

    /// 回到前台的续扫(场景 `.active`)。续扫会往库里合并行,就绪前进去只会看到空模型,所以推迟到发布之后
    /// (已就绪时 `onReady` 立即执行)。扫描的启动状态还没读完时答不了有没有要续的,按有算。
    /// 判断本身在不装模型的启动窗口里等到可用再做(`decideOnceUsableInTheLaunchWindow`)。
    func resumeScansOnSceneActivation(
        isStartupStateReady: @escaping @MainActor () -> Bool,
        whenStartupStateReady: @escaping @MainActor () async -> Void,
        hasResumableScanWork: @escaping @MainActor () -> Bool,
        resume: @escaping @MainActor () -> Void
    ) {
        decideOnceUsableInTheLaunchWindow { [self] in
            if isUsable, !isReady, !isStartupStateReady() {
                // 6c: 歌曲模型放掉了(或启动没装)而扫描的启动状态还没读完:先读完再判有没有要续的,
                // 不按有算 —— 那会为一个还没答的判断把模型装回来。
                Task { @MainActor in
                    await whenStartupStateReady()
                    self.onReady(holding: .scan, ifThereIsWork: { hasResumableScanWork() }) { resume() }
                }
            } else {
                onReady(holding: .scan, ifThereIsWork: {
                    !isStartupStateReady() || hasResumableScanWork()
                }) { resume() }
            }
        }
    }

    /// 回到前台的目录拓扑重建:同上,以库为输入。只有可能要重建的音乐源在时才请歌曲模型装回来,
    /// 要不要重建在发布后照旧细查。判断在不装模型的启动窗口里等到可用再做。
    func startFolderTopologyRebuildsOnSceneActivation(
        mayNeedRebuild: @escaping @MainActor () -> Bool,
        start: @escaping @MainActor () -> Void
    ) {
        decideOnceUsableInTheLaunchWindow { [self] in
            if isUsable, !isReady {
                // 6c: 模型放掉了(或启动没装):不先占用。细查(同步状态、目录的按源计数)不要模型;真要重建的
                // 那一轮扫描到提交前自己等模型。有服务器源就每次回前台装一次模型的那一步就此没了。
                start()
            } else {
                onReady(holding: .scan, ifThereIsWork: { mayNeedRebuild() }) { start() }
            }
        }
    }
}
