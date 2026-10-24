#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>

@interface NSObject(BackgroundQueue)
- (id)initWithContextID:(id)context storeItemIDs:(id)ids collectionIdentifierSet:(id)collection;
- (void)setShouldImmediatelyStartPlayback:(BOOL)value;
- (void)setShouldOverrideManuallyCuratedQueue:(BOOL)value;
- (id)initWithAppBundleID:(id)bundleID;
- (void)insertPlaybackQueueWithResult:(id)queue atPosition:(int)position onDestination:(id)destination withOptions:(id)options completion:(void (^)(id))completion;
@end
static int output(NSDictionary *value,int code) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    fwrite(data.bytes,1,data.length,stdout);fputc('\n',stdout);return code;
}
int main(int argc,const char **argv) { @autoreleasepool { @try {
    if(argc!=2) return output(@{@"status":@"invalid_id"},2);
    BOOL check=!strcmp(argv[1],"--check");
    NSString *storeID=check?@"1":@(argv[1]);
    NSRegularExpression *valid=[NSRegularExpression regularExpressionWithPattern:@"\\A[1-9][0-9]{0,18}\\z" options:0 error:nil];
    if([valid numberOfMatchesInString:storeID options:0 range:NSMakeRange(0,storeID.length)]!=1) return output(@{@"status":@"invalid_id"},2);
    if(![NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.Music"].count) return output(@{@"status":@"unavailable"},3);
    if(!dlopen("/System/Library/PrivateFrameworks/MediaPlaybackCore.framework/MediaPlaybackCore",RTLD_LAZY|RTLD_GLOBAL)) return output(@{@"status":@"unsupported"},3);
    Class queueClass=NSClassFromString(@"MPCAssistantStoreTracklistPlaybackQueue");
    Class destinationClass=NSClassFromString(@"MPCAssistantRemoteControlDestination");
    Class commandClass=NSClassFromString(@"MPCAssistantCommand");
    if(![queueClass instancesRespondToSelector:@selector(initWithContextID:storeItemIDs:collectionIdentifierSet:)] ||
       ![queueClass instancesRespondToSelector:@selector(setShouldImmediatelyStartPlayback:)] ||
       ![queueClass instancesRespondToSelector:@selector(setShouldOverrideManuallyCuratedQueue:)] ||
       ![destinationClass instancesRespondToSelector:@selector(initWithAppBundleID:)] ||
       ![commandClass instancesRespondToSelector:@selector(insertPlaybackQueueWithResult:atPosition:onDestination:withOptions:completion:)]) return output(@{@"status":@"unsupported"},3);
    if(check) return output(@{@"status":@"available",@"backend":@"MPCAssistantStoreTracklistPlaybackQueue"},0);
    id queue=[[queueClass alloc]initWithContextID:nil storeItemIDs:@[@(strtoull(argv[1],NULL,10))] collectionIdentifierSet:nil];
    [queue setShouldImmediatelyStartPlayback:NO];[queue setShouldOverrideManuallyCuratedQueue:NO];
    id destination=[[destinationClass alloc]initWithAppBundleID:@"com.apple.Music"],command=[commandClass new];
    if(!queue||!destination||!command) return output(@{@"status":@"unsupported"},3);
    __block BOOL done=NO;__block NSDictionary *response;
    NSLock *completionLock=[NSLock new];
    [command insertPlaybackQueueWithResult:queue atPosition:2 onDestination:destination withOptions:@{} completion:^(id result) {
        [completionLock lock];
        @try {
            id error=[result respondsToSelector:NSSelectorFromString(@"error")]?[result valueForKey:@"error"]:@"Missing error field";
            id statuses=[result respondsToSelector:NSSelectorFromString(@"returnStatuses")]?[result valueForKey:@"returnStatuses"]:nil;
            BOOL accepted=!error && [statuses isKindOfClass:NSArray.class] && [statuses count]>0;
            for(id status in [statuses isKindOfClass:NSArray.class]?statuses:@[]) if(![status isKindOfClass:NSNumber.class]||[status integerValue]!=0) accepted=NO;
            response=@{@"status":accepted?@"accepted":@"rejected",@"catalog_id":storeID,@"return_statuses":[statuses isKindOfClass:NSArray.class]?statuses:@[],@"error":error?[error description]:@""};
        } @catch(NSException *exception) {response=@{@"status":@"invalid_response"};}
        done=YES;[completionLock unlock];
    }];
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:20];
    while(deadline.timeIntervalSinceNow>0) {
        [completionLock lock];BOOL finished=done;[completionLock unlock];
        if(finished)break;
        [[NSRunLoop currentRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
    }
    [completionLock lock];BOOL finished=done;NSDictionary *finalResponse=response;[completionLock unlock];
    if(!finished) return output(@{@"status":@"unknown",@"error":@"Music did not confirm insertion. Do not retry automatically."},4);
    return output(finalResponse,[finalResponse[@"status"]isEqual:@"accepted"]?0:3);
} @catch(NSException *exception) {return output(@{@"status":@"unsupported",@"error":exception.reason?:@"Private queue API unavailable"},3);} } }
