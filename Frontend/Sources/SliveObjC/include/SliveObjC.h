#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` inside an Objective-C @try. Returns nil when it completes,
/// or "<name>: <reason>" when it raised an NSException.
///
/// Swift cannot catch Objective-C exceptions, and AVAudioEngine reports
/// several conditions (tap format vs. hardware format, a tap already on the
/// bus, invalid input formats) by raising instead of returning an error —
/// an uncaught raise aborts the whole process. Route those calls through
/// here so a refused microphone degrades to a failed recording, not a crash.
FOUNDATION_EXPORT NSString * _Nullable SliveCatchObjCException(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
