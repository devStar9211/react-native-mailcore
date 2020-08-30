//
//  EmailHelper.m
//  RNMaileCore
//
//  Created by devStar on 8/29/20.
//

#import "EmailHelper.h"
#import <GTMSessionFetcher/GTMSessionFetcherService.h>
#import <GTMSessionFetcher/GTMSessionFetcher.h>

/*! @brief The OIDC issuer from which the configuration will be discovered.
 */
static NSString *const kIssuer = @"https://accounts.google.com";

/*! @brief The OAuth client ID.
 @discussion For Google, register your client at
 https://console.developers.google.com/apis/credentials?project=_
 The client should be registered with the "iOS" type.
 */
static NSString *kClientID = @"963823664528-9ece7qad7jv6eu5mhf61ilvhcvqcsar9.apps.googleusercontent.com";

/*! @brief The OAuth redirect URI for the client @c kClientID.
 @discussion With Google, the scheme of the redirect URI is the reverse DNS notation of the
 client ID. This scheme must be registered as a scheme in the project's Info
 property list ("CFBundleURLTypes" plist key). Any path component will work, we use
 'oauthredirect' here to help disambiguate from any other use of this scheme.
 */
static NSString *kRedirectURI =
@"com.googleusercontent.apps.963823664528-9ece7qad7jv6eu5mhf61ilvhcvqcsar9:/oauthredirect";

/*! @brief @c NSCoding key for the authState property. You don't need to change this value.
 */
static NSString *kAuthorizerKey = @"googleOAuthCodingKey";


@implementation EmailHelper

static dispatch_once_t pred;
static EmailHelper *shared = nil;

+ (EmailHelper *)singleton {
    dispatch_once(&pred, ^{ shared = [[EmailHelper alloc] init]; });
    return shared;
}

- (instancetype)init {
    if (self = [super init]) {
        [self loadState];
    }
    return self;
}

- (void)initialize:(NSString *)clientID
       redirectURL:(NSString *)redirectURL {
    kClientID = clientID;
    kRedirectURI = redirectURL;
}

- (void)refreshState:(NSString *)authorizerKey {
    kAuthorizerKey = authorizerKey;
    [self loadState];
}

#pragma mark -

// CALL THIS TO START
- (void)doEmailLoginIfRequiredOnVC:(UIViewController*)vc completionBlock:(dispatch_block_t)completionBlock {
    // Optional: if no internet connectivity, do nothing
    dispatch_async(dispatch_get_main_queue(), ^{
                    
        // first see if we already have authorization
        [self checkIfAuthorizationIsValid:^(BOOL authorized) {
            NSAssert([NSThread currentThread].isMainThread, @"ERROR MAIN THREAD NEEDED");
            if (authorized) {
                if (completionBlock)
                    completionBlock();
            } else {
                [self doInitialAuthorizationWithVC:vc completionBlock:completionBlock];
            }
        }];
    });
}

/*! @brief Saves the @c GTMAppAuthFetcherAuthorization to @c NSUSerDefaults.
 */
- (void)saveState {
    if (_authorization.canAuthorize) {
        [GTMAppAuthFetcherAuthorization saveAuthorization:_authorization toKeychainForName:kAuthorizerKey];
    } else {
        NSLog(@"EmailHelper: WARNING, attempt to save a google authorization which cannot authorize, discarding");
        [GTMAppAuthFetcherAuthorization removeAuthorizationFromKeychainForName:kAuthorizerKey];
    }
}

/*! @brief Loads the @c GTMAppAuthFetcherAuthorization from @c NSUSerDefaults.
 */
- (void)loadState {
    GTMAppAuthFetcherAuthorization* authorization =
    [GTMAppAuthFetcherAuthorization authorizationFromKeychainForName:kAuthorizerKey];
    
    if (authorization.canAuthorize) {
        self.authorization = authorization;
    } else {
        NSLog(@"EmailHelper: WARNING, loaded google authorization cannot authorize, discarding");
        self.authorization = nil;
        [GTMAppAuthFetcherAuthorization removeAuthorizationFromKeychainForName:kAuthorizerKey];
    }
}

- (void)doInitialAuthorizationWithVC:(UIViewController*)vc completionBlock:(dispatch_block_t)completionBlock {
    NSURL *issuer = [NSURL URLWithString:kIssuer];
    NSURL *redirectURI = [NSURL URLWithString:kRedirectURI];

    NSLog(@"EmailHelper: Fetching configuration for issuer: %@", issuer);
    
    // discovers endpoints
    [OIDAuthorizationService discoverServiceConfigurationForIssuer:issuer completion:^(OIDServiceConfiguration *_Nullable configuration, NSError *_Nullable error) {
        if (!configuration) {
            NSLog(@"EmailHelper: Error retrieving discovery document: %@", [error localizedDescription]);
            self.authorization = nil;
            return;
        }
        
        NSLog(@"EmailHelper: Got configuration: %@", configuration);
        
        // builds authentication request
        OIDAuthorizationRequest *request =
        [[OIDAuthorizationRequest alloc] initWithConfiguration:configuration
                                                      clientId:kClientID
                                                        scopes:@[OIDScopeOpenID, OIDScopeProfile, @"https://mail.google.com/"]
                                                   redirectURL:redirectURI
                                                  responseType:OIDResponseTypeCode
                                          additionalParameters:nil];
        // performs authentication request
        NSLog(@"EmailHelper: Initiating authorization request with scope: %@", request.scope);
        self.currentAuthorizationFlow = [OIDAuthState authStateByPresentingAuthorizationRequest:request presentingViewController:vc callback:^(OIDAuthState *_Nullable authState, NSError *_Nullable error) {
            if (authState) {
                self.authorization = [[GTMAppAuthFetcherAuthorization alloc] initWithAuthState:authState];
                NSLog(@"EmailHelper: Got authorization tokens. Access token: %@", authState.lastTokenResponse.accessToken);
                [self saveState];
            } else {
                self.authorization = nil;
                NSLog(@"EmailHelper: Authorization error: %@", [error localizedDescription]);
            }
            if (completionBlock)
                dispatch_async(dispatch_get_main_queue(), completionBlock);
        }];
    }];
}

// Performs a UserInfo request to the account to see if the token works
- (void)checkIfAuthorizationIsValid:(void (^)(BOOL authorized))completionBlock {
    NSLog(@"EmailHelper: Performing userinfo request");
    
    // Creates a GTMSessionFetcherService with the authorization.
    // Normally you would save this service object and re-use it for all REST API calls.
    GTMSessionFetcherService *fetcherService = [[GTMSessionFetcherService alloc] init];
    fetcherService.authorizer = self.authorization;
    
    // Creates a fetcher for the API call.
    NSURL *userinfoEndpoint = [NSURL URLWithString:@"https://www.googleapis.com/oauth2/v3/userinfo"];
    GTMSessionFetcher *fetcher = [fetcherService fetcherWithURL:userinfoEndpoint];
    [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
        // Checks for an error.
        if (error) {
            // OIDOAuthTokenErrorDomain indicates an issue with the authorization.
            if ([error.domain isEqual:OIDOAuthTokenErrorDomain]) {
                [GTMAppAuthFetcherAuthorization removeAuthorizationFromKeychainForName:kAuthorizerKey];
                self.authorization = nil;
                NSLog(@"EmailHelper: Authorization error during token refresh, cleared state. %@", error);
                if (completionBlock)
                    completionBlock(NO);
            } else {
                // Other errors are assumed transient.
                NSLog(@"EmailHelper: Transient error during token refresh. %@", error);
                if (completionBlock)
                    completionBlock(NO);
            }
            return;
        }
        
        NSLog(@"EmailHelper: authorization is valid");
        if (completionBlock)
            completionBlock(YES);
    }];
}

@end
