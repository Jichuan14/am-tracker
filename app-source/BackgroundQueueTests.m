// Executes the real submission function with a fake destination. No Music calls.
#define main AMQueueHelperMain
#include "BackgroundQueue.m"
#undef main
@interface QueueCommandFixture : NSObject
@property NSMutableArray *items;
@end
@implementation QueueCommandFixture
- (instancetype)init {if((self=[super init]))_items=[NSMutableArray arrayWithObject:@"existing"];return self;}
- (void)insertPlaybackQueueWithResult:(id)queue atPosition:(int)position onDestination:(id)destination withOptions:(id)options completion:(void (^)(id))completion {
    // Model the observed next-item insertion, preserving older user queue items.
    [self.items insertObject:queue atIndex:1];
    if(position!=1)[NSException raise:@"QueuePolicy" format:@"Expected the existing insertion route (1), got %d",position];
    if([options count]!=0)[NSException raise:@"QueuePolicy" format:@"Unexpected options"];
    completion(@{});
}
@end
int main(void){@autoreleasepool{@try{
    QueueCommandFixture *command=[QueueCommandFixture new];
    for(NSString *song in @[@"recommendation"]){
        __block BOOL acknowledged=NO;
        submitQueue(song,nil,command,^(id result){acknowledged=YES;});
        if(!acknowledged)return 1;
    }
    if(![command.items isEqual:@[@"existing",@"recommendation"]])return 1;
    puts("PASS: background submission inserts one next song without replacing existing items. Mock commands only.");return 0;
}@catch(NSException *e){fprintf(stderr,"FAIL: %s\n",e.reason.UTF8String);return 1;}}}
