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

- (void)testStartingNodeOutsideAnEngineIsContained {
    // Raises on every system, including through -playAndReturnError: on 27.
    AVAudioPlayerNode *node = [[AVAudioPlayerNode alloc] init];

    XCTAssertFalse(PrimuseStartPlayerNode(node));
}

- (void)testStartingDisconnectedNodeReportsFailure {
    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    AVAudioPlayerNode *connected = [[AVAudioPlayerNode alloc] init];
    AVAudioPlayerNode *disconnected = [[AVAudioPlayerNode alloc] init];
    [engine attachNode:connected];
    [engine attachNode:disconnected];
    [engine connect:connected to:engine.mainMixerNode format:nil];
    NSError *error = nil;
    XCTSkipUnless([engine startAndReturnError:&error], @"engine could not start: %@", error);

    XCTAssertFalse(PrimuseStartPlayerNode(disconnected));
    XCTAssertTrue(PrimuseStartPlayerNode(connected));

    [engine stop];
}

- (void)testConnectingNodeOutsideTheEngineIsContained {
    // Connecting a node that was never attached raises on older systems and
    // fails through -connect:to:format:error: on 27.
    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    AVAudioPlayerNode *node = [[AVAudioPlayerNode alloc] init];
    NSError *error = nil;

    XCTAssertFalse(PrimuseConnectNodes(engine, node, engine.mainMixerNode, nil, &error));
    XCTAssertNotNil(error);
}

- (void)testConnectingAttachedNodeSucceeds {
    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    AVAudioPlayerNode *node = [[AVAudioPlayerNode alloc] init];
    [engine attachNode:node];
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100 channels:2];
    NSError *error = nil;

    XCTAssertTrue(PrimuseConnectNodes(engine, node, engine.mainMixerNode, format, &error));
    XCTAssertNil(error);
}

- (void)testSplittingOneOutputIntoTwoMixerInputs {
    // 混响并联：一路分给干声混音和混响，两路再汇进同一个混音节点的 0、1 号输入。
    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    AVAudioMixerNode *source = [[AVAudioMixerNode alloc] init];
    AVAudioMixerNode *dry = [[AVAudioMixerNode alloc] init];
    AVAudioUnitReverb *reverb = [[AVAudioUnitReverb alloc] init];
    AVAudioMixerNode *wet = [[AVAudioMixerNode alloc] init];
    AVAudioMixerNode *sum = [[AVAudioMixerNode alloc] init];
    for (AVAudioNode *node in @[source, dry, reverb, wet, sum]) {
        [engine attachNode:node];
    }
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
    NSError *error = nil;
    NSArray<AVAudioConnectionPoint *> *points = @[
        [[AVAudioConnectionPoint alloc] initWithNode:dry bus:0],
        [[AVAudioConnectionPoint alloc] initWithNode:reverb bus:0],
    ];

    XCTAssertTrue(PrimuseConnectNodeToPoints(engine, source, points, format, &error));
    XCTAssertTrue(PrimuseConnectNodes(engine, reverb, wet, format, &error));
    XCTAssertTrue(PrimuseConnectNodeBuses(engine, dry, 0, sum, 0, format, &error));
    XCTAssertTrue(PrimuseConnectNodeBuses(engine, wet, 0, sum, 1, format, &error));
    XCTAssertNil(error);
    XCTAssertEqual([engine outputConnectionPointsForNode:source outputBus:0].count, 2u);
    XCTAssertEqualObjects([engine inputConnectionPointForNode:sum inputBus:1].node, wet);
}

- (void)testSplittingFromNodeOutsideTheEngineIsContained {
    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    AVAudioMixerNode *source = [[AVAudioMixerNode alloc] init];
    AVAudioMixerNode *dry = [[AVAudioMixerNode alloc] init];
    [engine attachNode:dry];
    NSError *error = nil;
    NSArray<AVAudioConnectionPoint *> *points = @[[[AVAudioConnectionPoint alloc] initWithNode:dry bus:0]];

    XCTAssertFalse(PrimuseConnectNodeToPoints(engine, source, points, nil, &error));
    XCTAssertNotNil(error);
    error = nil;
    XCTAssertFalse(PrimuseConnectNodeBuses(engine, source, 0, dry, 0, nil, &error));
    XCTAssertNotNil(error);
}

@end
