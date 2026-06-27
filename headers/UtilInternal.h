#import "Util.h"

NS_ASSUME_NONNULL_BEGIN

@interface Util (Internal)

+ (nullable id)safeValueForKey:(NSString *)key onObject:(id)object;

+ (NSDictionary *)extractVideoInfoFromPlaybackNodeSync:(id)node;

+ (nullable id)findPlaybackNodeInTree:(id)node;

@end

NS_ASSUME_NONNULL_END
