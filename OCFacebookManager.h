//
//  OCFacebookManager.h
//
//  Created by Aseem Sandhu on 2/9/15.
//

#import <Foundation/Foundation.h>

@protocol FacebookManagerDelegate <NSObject>

- (void)userVerifiedSuccessfullyWithName:(NSString *)name;
- (void)failedToUploadFBUser;
- (void)facebookIdDidNotMatch;

@optional
- (void)handleFacebookPostResponse:(NSError *)err;
- (void)successfullyStoredFBProfileImage:(UIImage *)image;
- (void)userVerificationFailed;

@end

/**
 * The Util class that handles all communication with FB
 */
@interface OCFacebookManager : NSObject

@property (nonatomic, weak) id <FacebookManagerDelegate> fbDelegate;

+ (id)sharedManager;
- (void)openNewSession;
- (void)sharePostOnFBWithTitle:(NSString *)title description:(NSString *)desc imageData:(NSData *)imgData;

@end
