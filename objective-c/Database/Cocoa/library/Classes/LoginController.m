// **********************************************************************
//
// Copyright (c) 2003-2018 ZeroC, Inc. All rights reserved.
//
// **********************************************************************

#import <LoginController.h>
#import <LibraryController.h>

#import <Library.h>
#import <Glacier2Session.h>
#import <Session.h>

#import <objc/Ice.h>
#import <objc/Glacier2.h>

NSString* const usernameKey = @"usernameKey";
NSString* const passwordKey = @"passwordKey";

@implementation LoginController

+(void)initialize
{
    // Initialize the application defaults.
    NSDictionary* appDefaults = [NSDictionary dictionaryWithObjectsAndKeys:
                                 @"", usernameKey,
                                 @"", passwordKey,
                                 nil];

    [[NSUserDefaults standardUserDefaults] registerDefaults:appDefaults];

}

- (id)init
{
    return [super initWithWindowNibName:@"LoginView"];
}

-(void)awakeFromNib
{
    // Register and load the IceSSL and IceWS plugins on communicator initialization.
    ICEregisterIceSSL(YES);
    ICEregisterIceWS(YES);

    // Initialize the fields from the application defaults.
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];

    usernameField.stringValue = [defaults stringForKey:usernameKey];
    passwordField.stringValue = [defaults stringForKey:passwordKey];

}

#pragma mark Login callbacks

// Direct login to the library server.
-(LibraryController*)doLogin:(id)proxy
{
    id<DemoSessionFactoryPrx> factory = [DemoSessionFactoryPrx checkedCast:proxy];
    if(factory == nil)
    {
        @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"Invalid proxy" userInfo:nil];
    }

    id<DemoSessionPrx> session = [factory create];
    id<DemoLibraryPrx> library = [session getLibrary];
    return [[LibraryController alloc]
            initWithCommunicator:[proxy ice_getCommunicator]
            session:session
            router:nil
            library:library];
}

// Direct login through Glacier2.
-(LibraryController*)doGlacier2Login:(id)proxy username:(NSString*)username password:(NSString*)password NS_RETURNS_RETAINED
{
    id<GLACIER2RouterPrx> router = [GLACIER2RouterPrx checkedCast:[communicator getDefaultRouter]];
    id<GLACIER2SessionPrx> glacier2session = [router createSession:username password:password];
    id<DemoGlacier2SessionPrx> session = [DemoGlacier2SessionPrx uncheckedCast:glacier2session];

    id<DemoLibraryPrx> library = [session getLibrary];

    ICELong acmTimeout = [router getACMTimeout];
    if(acmTimeout > 0)
    {
        //
        // Configure the connection to send heartbeats in order to keep our session alive
        //
        [[router ice_getCachedConnection] setACM:@(acmTimeout) close:ICENone heartbeat:@(ICEHeartbeatAlways)];
    }

    return [[LibraryController alloc]
            initWithCommunicator:[proxy ice_getCommunicator]
            session:session
            router:router
            library:library];
}

#pragma mark Login

-(void)login:(id)sender
{
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:usernameField.stringValue forKey:usernameKey];
    [defaults setObject:passwordField.stringValue forKey:passwordKey];

    ICEInitializationData* initData = [ICEInitializationData initializationData];
    initData.properties = [ICEUtil createProperties];
    [initData.properties load:[[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"config.client"]];
    [initData.properties setProperty:@"Ice.RetryIntervals" value:@"-1"];

    initData.dispatcher = ^(id<ICEDispatcherCall> call, id<ICEConnection> con)
    {
        dispatch_sync(dispatch_get_main_queue(), ^ { [call run]; });
    };

    [initData.properties setProperty:@"IceSSL.DefaultDir" value:[[NSBundle mainBundle] resourcePath]];

    id proxy;
    @try
    {
        NSAssert(communicator == nil, @"communicator == nil");
        communicator = [ICEUtil createCommunicator:initData];
        if([[[communicator getProperties] getProperty:@"Ice.Default.Router"] length] > 0)
        {
            proxy = [communicator getDefaultRouter];
        }
        else
        {
            proxy = [communicator stringToProxy:[[communicator getProperties] getProperty:@"SessionFactory.Proxy"]];
        }
    }
    @catch(ICEEndpointParseException* ex)
    {
        [communicator destroy];
        communicator = nil;

        NSRunAlertPanel(@"Error", @"%@", @"OK", nil, nil, [ex description]);
        return;
    }

    [NSApp beginSheet:connectingSheet
       modalForWindow:self.window
        modalDelegate:nil
       didEndSelector:NULL
          contextInfo:NULL];
    [progress startAnimation:self];

    NSString* username = usernameField.stringValue;
    NSString* password = passwordField.stringValue;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^ {
        NSString* msg;
        @try
        {
            LibraryController* libraryController;
            if([[[communicator getProperties] getProperty:@"Ice.Default.Router"] length] > 0)
            {
                libraryController = [self doGlacier2Login:proxy username:username password:password];
            }
            else
            {
                libraryController = [self doLogin:proxy];
            }

            dispatch_async(dispatch_get_main_queue(), ^ {
                // Hide the connecting sheet.
                [NSApp endSheet:connectingSheet];
                [connectingSheet orderOut:self.window];
                [progress stopAnimation:self];

                // The communicator is now owned by the LibraryController.
                communicator = nil;

                // Close the connecting window, show the main window.
                [self.window close];
                [libraryController showWindow:self];
            });
            return;
        }
        @catch(GLACIER2CannotCreateSessionException* ex)
        {
            msg = [NSString stringWithFormat:@"Session creation failed: %@", ex.reason_];
        }
        @catch(GLACIER2PermissionDeniedException* ex)
        {
            msg = [NSString stringWithFormat:@"Login failed: %@", ex.reason_];
        }
        @catch(ICEException* ex)
        {
            msg = [ex description];
        }
        @catch(NSException *ex)
        {
            msg = [ex reason];
        }

        dispatch_async(dispatch_get_main_queue(), ^ {
            // Hide the connecting sheet.
            [NSApp endSheet:connectingSheet];
            [connectingSheet orderOut:self.window];
            [progress stopAnimation:self];

            [communicator destroy];
            communicator = nil;

            NSRunAlertPanel(@"Error", @"%@", @"OK", nil, nil, msg);
        });
    });
}

-(void)showAdvancedSheet:(id)sender
{
    [NSApp beginSheet:advancedSheet
       modalForWindow:self.window
        modalDelegate:nil
       didEndSelector:NULL
          contextInfo:NULL];
}

-(void)closeAdvancedSheet:(id)sender
{
    [NSApp endSheet:advancedSheet];
    [advancedSheet orderOut:sender];
}

@end
