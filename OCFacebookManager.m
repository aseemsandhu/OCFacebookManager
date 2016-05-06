//
//  OCFacebookManager.m
//
//  Created by Aseem Sandhu on 2/9/15.
//

#import "OCFacebookManager.h"
#import "User.h"
#import "AppDelegate.h"
#import <MagicalRecord/CoreData+MagicalRecord.h>
#import <SDWebImage/UIImageView+WebCache.h>
#import "Utility.h"
#import <AFHTTPRequestOperationManager.h>
#import "NSString+OCAdditions.h"

@interface OCFacebookManager() <FBLoginViewDelegate>

@property (nonatomic, strong) FBSession *fbSession;
@property (nonatomic, strong) AppDelegate *appDelegate;

// Flag to prevent completion handler from executing again
@property (nonatomic) BOOL handlerFlagForPost;
@property (nonatomic) BOOL handlerFlagForOpenSession;
@property (nonatomic) BOOL handlerFlagForErrorWithToken;

@end

@implementation OCFacebookManager

@synthesize fbSession;
@synthesize appDelegate;
@synthesize handlerFlagForPost, handlerFlagForOpenSession;
@synthesize handlerFlagForErrorWithToken;


// Create singleton class
+ (id)sharedManager {
    static OCFacebookManager *sharedFBManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedFBManager = [[self alloc] init];
    });
    return sharedFBManager;
}

- (id)init {
    if (self = [super init]) {
        self.appDelegate = (AppDelegate *)[UIApplication sharedApplication].delegate;
    }
    return self;
}

- (void)openNewSession {
    
    NSLog(@"openNewSession is being called");
    
    self.handlerFlagForOpenSession = NO;
    self.handlerFlagForPost = NO;
    self.handlerFlagForErrorWithToken = NO;
    
    // If the session exists, then clear it from memory
    self.fbSession = nil;
    [[FBSession activeSession] closeAndClearTokenInformation];
    
    User *currentUser = self.appDelegate.loggedInUser;
    
    NSString *userAccessToken = currentUser.facebookToken;
    
    if (currentUser.facebookId == nil || (userAccessToken == nil || [userAccessToken isEqualToString:@""])) {
        NSLog(@"CALLING openSessionForUnverifiedUser 1");
        [self openSessionForUnverifiedUser];
    } else {
        [self openSessionWithAccessToken:userAccessToken];
    }
}

- (void)openSessionForUnverifiedUser {
    
    NSLog(@"OPEN SESSION FOR UNVERIFIED USER IS BEING CALLED");
    
    self.fbSession = nil;
    [[FBSession activeSession] closeAndClearTokenInformation];
    
    // Open a session showing user the login UI
    
    self.fbSession = [[FBSession alloc] initWithPermissions:@[@"publish_actions"]];
    [FBSession setActiveSession:self.fbSession];
    
    [self.fbSession openWithBehavior:FBSessionLoginBehaviorForcingWebView completionHandler:^(FBSession *session, FBSessionState status, NSError *error) {
        NSLog(@"the error with completion handler for facebook session: %@", [error localizedDescription]);
        NSLog(@"the completion handler for opening a session with facebook");
        NSLog(@"the FBSession when logging in with facebook: %@", session);
        NSLog(@"the status when logging in with facebook: %u", (unsigned)status);
        NSLog(@"the access token when logging in with facebook: %@", session.accessTokenData);
        
        if (self.handlerFlagForOpenSession) {
            self.handlerFlagForOpenSession = NO;
            return;
        }
        
        if ((!error) && (status == FBSessionStateOpen || status == FBSessionStateOpenTokenExtended)) {
            
            NSLog(@"the FBSession is now in the open state");
            
            // Only save the facebookToken and facebookId in Core Data if publish_actions is accepted by user
            // first object in declinedPermissions array is an empty string for some reason
            if ((session.declinedPermissions.count <= 1) && [[session.declinedPermissions objectAtIndex:0] isEqualToString:@""]) {
                
                NSLog(@"the user did not decline any permissions");
                
                // Get the user information from Facebook server
                [[FBRequest requestForMe] startWithCompletionHandler:^(FBRequestConnection *connection, FBGraphObject *result, NSError *error) {
                    NSLog(@"the result after setting up connection to get facebook user data: %@", result);
                    NSLog(@"the error, if any, after getting the facebook user data: %@", [error localizedDescription]);
                    if (result && !error) {
                        
                        NSString *accessTokenString = session.accessTokenData.accessToken;
                        NSString *facebookName = [result valueForKey:@"name"];
                        NSString *facebookId = [result valueForKey:@"id"];
                        
                        User *currentUser = self.appDelegate.loggedInUser;
                        
                        // Make sure that facebookId matches because we are not allowing users to login with different FB account once they have verified for the first time
                        if ((currentUser.facebookId != nil) && ![currentUser.facebookId isEqualToString:@""]) {
                            if (![facebookId isEqualToString:currentUser.facebookId]) {
                                NSLog(@"the facebookId does not match the one that the user originally verified with");
                                [self.fbDelegate facebookIdDidNotMatch];
                                return;
                            }
                        }
                        
                        [self saveGraphObjectWithFBToken:accessTokenString fbName:facebookName fbId:facebookId];
                        
                    } else {
                        NSLog(@"Error with verifying the facebook user");
                        if ([self.fbDelegate respondsToSelector:@selector(userVerificationFailed)]) {

                            [self.fbDelegate userVerificationFailed];
                        }
                    }
                }];
            } else {
                if ([self.fbDelegate respondsToSelector:@selector(userVerificationFailed)]) {
                    [self.fbDelegate userVerificationFailed];
                }
            }
        } else {
            if ([self.fbDelegate respondsToSelector:@selector(userVerificationFailed)]) {
                [self.fbDelegate userVerificationFailed];
            }
        }
        
    }];
}

- (void)openSessionWithAccessToken:(NSString *)accessToken {
    
    NSLog(@"OPEN SESSION WITH ACCESS TOKEN IS BEING CALLED");
    
    self.fbSession = nil;
    [[FBSession activeSession] closeAndClearTokenInformation];
    
    FBAccessTokenData *accessTokenData = [FBAccessTokenData createTokenFromString:accessToken permissions:@[@"publish_actions"] expirationDate:nil loginType:FBSessionLoginTypeWebView refreshDate:nil];
    
    self.fbSession = [[FBSession alloc] initWithPermissions:@[@"publish_actions"]];
    
    [FBSession setActiveSession:self.fbSession];
    
    __block BOOL runTimeFlag;
    
    [self.fbSession openFromAccessTokenData:accessTokenData completionHandler:^(FBSession *session, FBSessionState status, NSError *error) {
        
        if (self.handlerFlagForPost) {
            self.handlerFlagForPost = NO;
            NSLog(@"returning the completion handler for openFromAccessTokenData");
            return;
        }
        
        // If session with access token was successful then get the graph user
        // Otherwise, show login screen
        if ((!error) && (status == FBSessionStateOpen || status == FBSessionStateOpenTokenExtended) && ((session.declinedPermissions.count == 0) || session.declinedPermissions == nil)) {
            
            NSLog(@"the FBSession is now in the open state with access token");
            
            // Get the user information from Facebook server
            [[FBRequest requestForMe] startWithCompletionHandler:^(FBRequestConnection *connection, FBGraphObject *result, NSError *error) {
                NSLog(@"the result after setting up connection to get facebook user data with access token: %@", result);
                NSLog(@"the error, if any, after getting the facebook user data with access token: %@", [error localizedDescription]);
                if (result && !error) {
                    
                    NSString *accessTokenString = session.accessTokenData.accessToken;
                    NSString *facebookId = [result valueForKey:@"id"];
                    
                    User *currentUser = self.appDelegate.loggedInUser;
                    
                    // Check if facebookId from local matches the response
                    if ((currentUser.facebookId != nil) && ![currentUser.facebookId isEqualToString:@""])  {
                        if (![currentUser.facebookId isEqualToString:facebookId]) {
                            NSLog(@"SHOW AN ALERT HERE FOR THE FACEBOOK ID NOT MATCHING WITH LOCAL DATABASE. TELL THE USER TO LOG IN WITH THEIR ORIGINAL FACEBOOK ACCOUNT");
                            [self.fbDelegate facebookIdDidNotMatch];
                            
                            return;
                            
                        } else {
                            // If the local facebook data does not match data from facebook server, then show login screen
                            if ([currentUser.facebookToken isEqualToString:accessTokenString]) {
                                runTimeFlag = YES;
                                [self.fbDelegate userVerifiedSuccessfullyWithName:currentUser.fullName];
                            } else {
                                NSLog(@"CALLING openSessionForUnverifiedUser 2");
                                [self openSessionForUnverifiedUser];
                            }
                        }
                    }
                    
                } else {
                    if (!runTimeFlag) {
                        
                        if (self.handlerFlagForErrorWithToken) {
                            self.handlerFlagForErrorWithToken = NO;
                            NSLog(@"the handlerFlagForErrorWithToken3");
                            return;
                        }
                        NSLog(@"CALLING openSessionForUnverifiedUser 3");
                        self.handlerFlagForErrorWithToken = YES;
                        [self openSessionForUnverifiedUser];
                    }
                }
            }];
        } else {
            if (!runTimeFlag) {
                if (self.handlerFlagForErrorWithToken) {
                    self.handlerFlagForErrorWithToken = NO;
                    NSLog(@"the handlerFlagForErrorWithToken4");
                    return;
                }
                NSLog(@"CALLING openSessionForUnverifiedUser 4");
                self.handlerFlagForErrorWithToken = YES;
                [self openSessionForUnverifiedUser];
            }
        }
    }];
}

- (void)saveGraphObjectWithFBToken:(NSString *)token fbName:(NSString *)name fbId:(NSString *)fbId {
    
    NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
    
    NSString *urlString = [NSString stringWithFormat:@"%@uid=%@&pwd=%@&fullName=%@&facebookId=%@&accessToken=%@", EDITFACEBOOKUSERURL, [userDefaults valueForKey:USERID], [[userDefaults valueForKey:PASSWORD] urlEncodeStringWithUTF8], [name urlEncodeStringWithUTF8], [fbId urlEncodeStringWithUTF8], [token urlEncodeStringWithUTF8]];
    
    AFHTTPRequestOperationManager *manager = [AFHTTPRequestOperationManager manager];
    
    [manager GET:urlString parameters:nil success:^(AFHTTPRequestOperation *operation, id responseObject) {
        NSLog(@"the response object when editing facebook profile: %@", responseObject);
        User *currentUser = self.appDelegate.loggedInUser;
        
        [currentUser setValue:token forKey:@"facebookToken"];
        [currentUser setValue:name forKey:@"fullName"];
        [currentUser setValue:fbId forKey:@"facebookId"];
        
        NSError *error = nil;
        [[NSManagedObjectContext MR_defaultContext] MR_saveToPersistentStoreWithCompletion:^(BOOL success, NSError *error) {
            if (success) {
                
                NSLog(@"the facebook token that was saved with graph user: %@", self.appDelegate.loggedInUser.facebookToken);
                NSLog(@"the facebook id that was saved with graph user: %@", self.appDelegate.loggedInUser.facebookId);
                NSLog(@"the facebook full name that was saved with graph user: %@", self.appDelegate.loggedInUser.fullName);
                
                [userDefaults setValue:name forKey:FULLNAME];
                
                [self fetchUserProfileImage];
                
                if ([self.fbDelegate respondsToSelector:@selector(userVerifiedSuccessfullyWithName:)]) {
                    [self.fbDelegate userVerifiedSuccessfullyWithName:currentUser.fullName];
                }
            } else {
                NSLog(@"there was an error saving to persistent store: %@", [error localizedDescription]);
            }
        }];
        
    } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
        [self.fbDelegate failedToUploadFBUser];
        NSLog(@"Error when editing facebook profile: %@", error);
    }];
}

- (void)fetchUserProfileImage {
    
    User *currentUser = self.appDelegate.loggedInUser;
    
    NSURL *fbImageURL = [NSURL URLWithString:[NSString stringWithFormat:@"https://graph.facebook.com/%@/picture?type=large", currentUser.facebookId]];
    
    NSURLRequest *request = [NSURLRequest requestWithURL:fbImageURL];
    
    [NSURLConnection sendAsynchronousRequest:request queue:[NSOperationQueue mainQueue] completionHandler:^(NSURLResponse *response, NSData *data, NSError *connectionError) {
        
        NSLog(@"the data when loading facebook image: %@", data);
        
        NSHTTPURLResponse *resp = (NSHTTPURLResponse*)response;
        int code = (int)[resp statusCode];
        
        if (connectionError == nil) {
            
            if (code == 200 || code == 201) {
                
                if (data) {
                    [self uploadProfileImageData:data];
                }
                
            }
            
        }
    }];
}

- (void)uploadProfileImageData:(NSData *)imgData {
    
    NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
    NSString *filename = [Utility getMyProfilePicCacheKey];
    
    NSURLRequest *request = [Utility uploadImageRequest:imgData :filename :[userDefaults valueForKey:USERID] :[userDefaults valueForKey:PASSWORD]];
    [NSURLConnection sendAsynchronousRequest:request queue:[NSOperationQueue mainQueue] completionHandler:^(NSURLResponse *response, NSData *data, NSError *connectionError) {
        
        NSLog(@"the data when loading facebook image: %@", data);
        
        NSHTTPURLResponse *resp = (NSHTTPURLResponse*)response;
        int code = (int)[resp statusCode];
        
        NSLog(@"the response when uploading profile image: %@", resp);
        NSLog(@"the status code for uploading profile image: %d", code);
        NSLog(@"the connection error if any when uploading the profile image: %@", [connectionError localizedDescription]);
        
        if (connectionError == nil) {
            
            if (code == 200 || code == 201) {
                
                UIImage *image = [UIImage imageWithData:imgData];
                
                [[SDImageCache sharedImageCache] storeImage:image forKey:filename toDisk:YES];
                if ([self.fbDelegate respondsToSelector:@selector(successfullyStoredFBProfileImage:)]) {
                    [self.fbDelegate successfullyStoredFBProfileImage:(UIImage *)image];
                }
                NSLog(@"the file name when storing the image: %@", filename);
            } else {
                NSLog(@"The profile image was not uploaded to our server");
            }
            
        } else {
            NSLog(@"There was a connection error when uploading the profile image to our server: %@", [connectionError localizedDescription]);
        }
    }];
}

- (void)sharePostOnFBWithTitle:(NSString *)title description:(NSString *)desc imageData:(NSData *)imgData {
    
    NSString *messageString = [NSString stringWithFormat:@"%@\n\n%@", title, desc];
    
    NSDictionary *params = @{ @"message" : messageString };
    
    FBRequest *postRequest;
    
    if(imgData) {
        UIImage *img = [UIImage imageWithData:imgData];
        postRequest = [FBRequest requestForUploadPhoto:img];
        [postRequest.parameters addEntriesFromDictionary:params];
    } else {
        postRequest = [[FBRequest alloc] initWithSession:self.fbSession graphPath:@"me/feed" parameters:params HTTPMethod:@"POST"];
    }
    
    NSLog(@"executing the post request for publishing to facebook");
    
    FBRequestConnection *connection = [[FBRequestConnection alloc] initWithTimeout:10.0];
    
    [connection addRequest:postRequest completionHandler:^(FBRequestConnection *connection, id result, NSError *error) {
        NSLog(@"the result from facebook post connection: %@", result);
        if ([self.fbDelegate respondsToSelector:@selector(handleFacebookPostResponse:)]) {
            [self.fbDelegate handleFacebookPostResponse:error];
        }
        self.fbSession = nil;
        [[FBSession activeSession] closeAndClearTokenInformation];
    }];
    
    [connection start];
    self.handlerFlagForPost = YES;
    
}

@end







