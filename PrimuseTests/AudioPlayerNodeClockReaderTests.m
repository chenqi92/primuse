#import <XCTest/XCTest.h>

#import "../Primuse/Services/Audio/AudioPlayerNodeClockReader.h"

@interface ThrowingPlayerTimeAudioPlayerNode : AVAudioPlayerNode
@end

@implementation ThrowingPlayerTimeAudioPlayerNode

- (AVAudioTime *)lastRenderTime {
    return [[AVAudioTime alloc] initWithSampleTime:0 atRate:44100];
}

- (AVAudioTime *)playerTimeForNodeTime:(AVAudioTime *)nodeTime {
    [NSException raise:NSInternalInconsistencyException
                format:@"simulated player-time failure"];
    return nil;
}

@end

@interface ThrowingLastRenderTimeAudioPlayerNode : AVAudioPlayerNode
@end

@implementation ThrowingLastRenderTimeAudioPlayerNode

- (AVAudioTime *)lastRenderTime {
    [NSException raise:NSInternalInconsistencyException
                format:@"simulated render-time failure"];
    return nil;
}

@end

@interface AudioPlayerNodeClockReaderTests : XCTestCase
@end

@implementation AudioPlayerNodeClockReaderTests

- (void)testPlayerTimeExceptionIsContained {
    ThrowingPlayerTimeAudioPlayerNode *node = [[ThrowingPlayerTimeAudioPlayerNode alloc] init];

    XCTAssertNil(PrimusePlayerTimeForNode(node));
}

- (void)testLastRenderTimeExceptionIsContained {
    ThrowingLastRenderTimeAudioPlayerNode *node = [[ThrowingLastRenderTimeAudioPlayerNode alloc] init];

    XCTAssertNil(PrimusePlayerTimeForNode(node));
    XCTAssertFalse(PrimusePlayerNodeHasRenderTime(node));
}

@end
