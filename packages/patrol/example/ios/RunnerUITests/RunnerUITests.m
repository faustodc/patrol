@import XCTest;
@import patrol;
@import ObjectiveC.runtime;

#define PATROL_INTEGRATION_TEST_IOS_RUNNER(__test_class)
  @interface __test_class : XCTestCase
  @end

@implementation __test_class

+(NSArray<NSInvocation *> *)testInvocations {
  __block NSMutableDictionary<NSString *, NSNumber *> *callbacksState = NULL;
  __block NSArray<NSString *> *dartTests = NULL;
  __block BOOL appReady = NO;
  
  /* Start native automation server */
  PatrolServer *server = [[PatrolServer alloc] initWithOnAppReadyCallback:^{
    appReady = YES;
  } onDartLifecycleCallbackExecuted:^(NSString * _Nonnull callbackName) {
    /* callbacksState dictionary will have been already initialized when this callback is executed */
    NSLog(@"onLifecycleCallbackExecuted for %@", callbackName);
    [callbacksState setObject:@YES forKey:callbackName];
  }];
  
  NSError *_Nullable __autoreleasing *_Nullable err = NULL;
  [server startAndReturnError:err];
  if (err != NULL) {
    NSLog(@"patrolServer.start(): failed, err: %@", err);
  }
  
  /* Create a client for PatrolAppService, which lets us list and run Dart tests */
  __block ObjCPatrolAppServiceClient *appServiceClient = [[ObjCPatrolAppServiceClient alloc] init];
  
  /* Allow the Local Network permission required by Dart Observatory */
  XCUIApplication *springboard = [[XCUIApplication alloc] initWithBundleIdentifier:@"com.apple.springboard"];
  XCUIElementQuery *systemAlerts = springboard.alerts;
  if (systemAlerts.buttons[@"Allow"].exists) {
    [systemAlerts.buttons[@"Allow"] tap];
  }
  
  /* MARK: Start initial run */
  /* Run the app for the first time to gather Dart tests */
  XCUIApplication *app = [[XCUIApplication alloc] init];
  NSDictionary *args = @{ @"PATROL_INITIAL_RUN" : @"true" };
  app.launchEnvironment = args;
  [app launch];
  
  /* Spin the runloop waiting until the app reports that PatrolAppService is up */
  while (!appReady) {
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
  }
  
  /* MARK: List Dart lifecycle callbacks */
  
  [appServiceClient
    listDartLifecycleCallbacksWithCompletion:^(NSArray<NSString *> * _Nullable setUpAlls,
                                               NSArray<NSString *> * _Nullable tearDownAlls,
                                               NSError * _Nullable err) {
    if (err != NULL) {
      NSLog(@"listDartLifecycleCallbacks(): failed, err: %@", err);
    }
    
    callbacksState = [[NSMutableDictionary alloc] init];
    for (NSString* setUpAll in setUpAlls) {
      [callbacksState setObject:@NO forKey:setUpAll];
    }
  }];
  
  /* Spin the runloop waiting until the app reports the Dart lifecycle callbacks it contains */
  while (!callbacksState) {
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
  }
  NSLog(@"Got %lu Dart lifecycle callbacks: %@", callbacksState.count, callbacksState);
  
  /* MARK: List Dart tests */
  
  [appServiceClient listDartTestsWithCompletion:^(NSArray<NSString *> *_Nullable tests, NSError *_Nullable err) {
    if (err != NULL) {
      NSLog(@"listDartTests(): failed, err: %@", err);
    }
    
    dartTests = tests;
  }];
  
  /* Spin the runloop waiting until the app reports the Dart tests it contains */
  while (!dartTests) {
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
  }
  NSLog(@"Got %lu Dart tests: %@", dartTests.count, dartTests);
  
  /* MARK: Create tests at runtime */
  
  NSMutableArray<NSInvocation *> *invocations = [[NSMutableArray alloc] init];
  
  /**
   *
   * Once Dart tests are available, we:
   *
   *  Step 1. Dynamically add test case methods that request execution of an individual Dart test file.
   *
   *  Step 2. Create invocations to the generated methods and return them
   */
  
  for (NSString * dartTest in dartTests) {
    /* Step 1 - dynamically create test cases */
    
    IMP implementation = imp_implementationWithBlock(^(id _self) {
      /* Reset server's appReady state, because new app process will be started */
      appReady = NO;
      
      XCUIApplication *app = [[XCUIApplication alloc] init];
      NSDictionary *args = @{ @"PATROL_INITIAL_RUN" : @"false" };
      [app setLaunchEnvironment:args];
      [app launch];
      
      /* Spin the runloop waiting until the app reports that PatrolAppService is up */
      while (!appReady) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
      }
      
      __block BOOL callbacksSet = NO;
      [appServiceClient setDartLifecycleCallbacksState:callbacksState completion:^(NSError * _Nullable err) {
        if (err != NULL) {
          NSLog(@"setDartLifecycleCallbacksState(): call failed, err: %@", err);
        }
      
        NSLog(@"setDartLifecycleCallbacksState(): call succeeded");
        callbacksSet = YES;
      }];
      
      /*Wait until lifecycle callbacks are set*/
      while (!callbacksSet) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
      }
      
      __block ObjCRunDartTestResponse *response = NULL;
      __block NSError *error;
      [appServiceClient runDartTest:dartTest
                         completion:^(ObjCRunDartTestResponse *_Nullable r, NSError *_Nullable err) {
        NSString *status;
        if (err != NULL) {
          error = err;
          status = @"CRASHED";
        } else {
          response = r;
          status = response.passed ? @"PASSED" : @"FAILED";
        }
        
        NSLog(@"runDartTest(\"%@\"): call finished, test result: %@", dartTest, status);
      }];
      
      /* Wait until Dart test finishes (either fails or passes) or crashes */
      while (!response && !error) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
      }
      
      BOOL passed = response ? response.passed : NO;
      NSString *details = response ? response.details : @"(no details - app likely crashed)";
      
      XCTAssertTrue(passed, @"%@", details);
    });
    
    NSString *selectorName = [PatrolUtils createMethodNameFromPatrolGeneratedGroup:dartTest];
    SEL selector = NSSelectorFromString(selectorName);
    class_addMethod(self, selector, implementation, "v@:");
    
    /* Step 2 – create invocations to the dynamically created methods */
    NSMethodSignature *signature = [self instanceMethodSignatureForSelector:selector];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.selector = selector;
    
    NSLog(@"RunnerUITests.testInvocations(): selectorName = %@, signature: %@", selectorName, signature);
    
    [invocations addObject:invocation];
  }
  
  return invocations;
}

@end

PATROL_INTEGRATION_TEST_IOS_RUNNER(RunnerUITests)
