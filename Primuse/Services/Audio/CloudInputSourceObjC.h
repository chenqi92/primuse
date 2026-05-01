// Bridges SFBAudioEngine's synchronous SFBInputSource read API to a
// Swift closure that performs HTTP Range fetches, so cloud-source
// playback can stream byte-by-byte instead of pre-downloading the whole
// file. The actual range/cache logic lives in CloudPlaybackSource.swift —
// this file only exists because SFBInputSource's designated initializer
// `-initWithURL:` is in a non-public `+Internal.h` header and therefore
// not visible to Swift subclasses. Re-declaring it in our target lets
// the linker resolve the symbol at runtime.

#import <Foundation/Foundation.h>
#import <SFBAudioEngine/SFBInputSource.h>

NS_ASSUME_NONNULL_BEGIN

/// Synchronous fetch callback. Called from SFBAudioEngine's audio decode
/// thread. The implementation must block until it has at least some bytes
/// for the requested range, returning an empty Data only at true EOF.
typedef NSData * _Nullable (^CloudInputFetchBlock)(int64_t offset, int64_t length, NSError **error);

@interface CloudInputSourceObjC : SFBInputSource

/// Total length of the underlying remote file. Required up front so
/// SFBAudioEngine's decoder can determine seek bounds.
@property(nonatomic, readonly) int64_t totalLength;

/// Designated initializer. Bridges to SFBInputSource's hidden
/// `-initWithURL:` so the inherited base class state (notably `_url`) is
/// initialized — without it `[super description]` and KVC paths break.
/// `url` is informational only (we never actually open it on disk).
- (instancetype)initWithURL:(nullable NSURL *)url
                totalLength:(int64_t)totalLength
                 fetchBlock:(CloudInputFetchBlock)fetchBlock NS_DESIGNATED_INITIALIZER;

@end

NS_ASSUME_NONNULL_END
