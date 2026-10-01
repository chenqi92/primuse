#import "CloudInputSourceObjC.h"

// Re-declaration of SFBInputSource's hidden designated initializer.
// The implementation lives in the SFBAudioEngine package, but the
// declaration is in `SFBInputSource+Internal.h` which isn't part of
// the public umbrella. The selector exists at runtime — declaring it
// here just lets ARC/clang generate the right call site.
@interface SFBInputSource (CloudInputSourcePrivate)
- (instancetype)initWithURL:(nullable NSURL *)url;
@end

@interface CloudInputSourceObjC () {
    int64_t _offset;
    BOOL _open;
}
@property(nonatomic, copy) CloudInputFetchBlock fetchBlock;
@end

@implementation CloudInputSourceObjC

- (instancetype)initWithURL:(NSURL *)url
                totalLength:(int64_t)totalLength
                 fetchBlock:(CloudInputFetchBlock)fetchBlock {
    self = [super initWithURL:url];
    if (self) {
        _totalLength = totalLength;
        _fetchBlock = [fetchBlock copy];
        _offset = 0;
        _open = NO;
    }
    return self;
}

- (BOOL)openReturningError:(NSError **)error {
    _open = YES;
    _offset = 0;
    return YES;
}

- (BOOL)closeReturningError:(NSError **)error {
    _open = NO;
    self.fetchBlock = nil;
    return YES;
}

- (BOOL)isOpen {
    return _open;
}

- (BOOL)readBytes:(void *)buffer
           length:(NSInteger)length
        bytesRead:(NSInteger *)bytesRead
            error:(NSError **)error {
    if (!_open) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EBADF userInfo:nil];
        }
        *bytesRead = 0;
        return NO;
    }
    if (length <= 0 || _offset >= _totalLength) {
        *bytesRead = 0;
        return YES;
    }

    int64_t remaining = _totalLength - _offset;
    int64_t toRead = MIN((int64_t)length, remaining);

    // The fetch block answers one cached range or one chunk at a time, so a
    // read crossing a range or chunk boundary comes back short. SFB's own
    // decoders simply ask again, but Core Audio's AudioFile (AAC / ALAC in
    // M4A) takes a short read inside packet data as a decoding failure. Keep
    // reading until the request is satisfied, like a file would.
    NSInteger copied = 0;
    while (copied < toRead) {
        NSError *fetchError = nil;
        NSData *data = self.fetchBlock(_offset + copied, toRead - copied, &fetchError);
        NSInteger chunk = data == nil ? 0 : (NSInteger)MIN((NSUInteger)(toRead - copied), data.length);
        if (chunk == 0) {
            // Bytes already copied are real data; hand them over and let the
            // next read report the failure.
            if (copied > 0) { break; }
            // 关键: 一个字节都没读到但 _offset 还没到 _totalLength 时, 必须返回
            // 错误而不是 YES+0。SFB 把 "bytesRead=0 且 return YES" 当成自然 EOF,
            // 会把 decoder position 拉到 totalFrames, 解码循环退出,
            // AudioPlayerService 把短数据末尾的 buffer 当成 "歌唱完了" 调度
            // gapless boundary callback —— 用户体感就是歌没播完就切下一首。
            // 返回错误让上层走 retry / autoAdvance 路径而不是误判 EOF。
            if (error) {
                *error = data == nil
                    ? (fetchError ?: [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:nil])
                    : [NSError errorWithDomain:NSPOSIXErrorDomain
                                          code:EIO
                                      userInfo:@{NSLocalizedDescriptionKey: @"Cloud source returned 0 bytes mid-stream"}];
            }
            *bytesRead = 0;
            return NO;
        }
        memcpy((uint8_t *)buffer + copied, data.bytes, (size_t)chunk);
        copied += chunk;
    }
    _offset += copied;
    *bytesRead = copied;
    return YES;
}

- (NSData *)readDataAtOffset:(int64_t)offset
                      length:(NSInteger)length
                       error:(NSError **)error {
    if (offset < 0 || length < 0 || offset > _totalLength) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];
        }
        return nil;
    }
    if (length == 0 || offset == _totalLength) {
        return [NSData data];
    }

    CloudInputFetchBlock fetch = self.fetchBlock;
    if (fetch == nil) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EBADF userInfo:nil];
        }
        return nil;
    }
    int64_t requested = MIN((int64_t)length, _totalLength - offset);
    NSError *fetchError = nil;
    NSData *data = fetch(offset, requested, &fetchError);
    if (data == nil) {
        if (error) {
            *error = fetchError ?: [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:nil];
        }
        return nil;
    }
    if (data.length == 0 && requested > 0) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:EIO
                                     userInfo:@{NSLocalizedDescriptionKey: @"Cloud source returned 0 bytes mid-stream"}];
        }
        return nil;
    }
    if (data.length > (NSUInteger)requested) {
        return [data subdataWithRange:NSMakeRange(0, (NSUInteger)requested)];
    }
    return data;
}

- (BOOL)atEOF {
    return _offset >= _totalLength;
}

- (BOOL)getOffset:(NSInteger *)offset error:(NSError **)error {
    *offset = (NSInteger)_offset;
    return YES;
}

- (BOOL)getLength:(NSInteger *)length error:(NSError **)error {
    *length = (NSInteger)_totalLength;
    return YES;
}

- (BOOL)supportsSeeking {
    return YES;
}

- (BOOL)seekToOffset:(NSInteger)offset error:(NSError **)error {
    if (offset < 0 || offset > _totalLength) {
        if (error) { *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil]; }
        return NO;
    }
    _offset = (int64_t)offset;
    return YES;
}

@end
