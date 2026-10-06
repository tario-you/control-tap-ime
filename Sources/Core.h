#import <Foundation/Foundation.h>
void CTFail(NSString *message);
BOOL CTNeedsRefresh(NSDictionary *source);
NSDictionary *CTValidateConfiguration(NSDictionary *configuration);
NSArray<NSDictionary *> *CTSourceGroup(NSArray<NSDictionary *> *available, NSDictionary *configuration);
NSDictionary *CTNextSource(NSString *currentID, NSArray<NSDictionary *> *group);
