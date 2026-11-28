import Foundation

extension MetadataBackfillService {
    /// 场景切换(进后台时播放或不播放、在后台里播放开始或停下)时开补读。
    ///
    /// 6c 的规则:歌曲模型在内存里就开工,与以前相同。不在内存里时不为一次场景切换把它装回来 —— 进后台的那几秒里
    /// 装到一半进程就被挂起,内存最糟;`start()` 自己在发布时开工(模型因别的原因装回来时:页面、播放、续扫……),
    /// 一直没人装回来就留给后台处理任务(`BackgroundProcessingDrain`:先问有没有活儿,有就占用模型,有几分钟)。
    /// 没有活儿、或已经在跑时什么也不做。
    func startForSceneTransition() {
        guard hasPendingWork, !isRunning else { return }
        start()
    }
}
