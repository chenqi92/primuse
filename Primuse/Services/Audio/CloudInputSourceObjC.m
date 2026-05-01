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

    NSError *fetchError = nil;
    NSData *data = self.fetchBlock(_offset, toRead, &fetchError);
    if (data == nil) {
        if (error) { *error = fetchError ?: [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:nil]; }
        *bytesRead = 0;
        return NO;
    }

    NSInteger copied = (NSInteger)MIN((NSUInteger)toRead, data.length);
    memcpy(buffer, data.bytes, (size_t)copied);
    _offset += copied;
    *bytesRead = copied;
    return YES;
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
