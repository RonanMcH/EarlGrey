//
// Copyright 2017 Google Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

#import <WebKit/WebKit.h>

#import "AppFramework/Action/GREYScrollAction.h"

#import "AppFramework/Action/GREYPathGestureUtils.h"
#import "AppFramework/Additions/NSObject+GREYApp.h"
#import "AppFramework/Additions/UIScrollView+GREYApp.h"
#import "AppFramework/Error/GREYAppError.h"
#import "AppFramework/Event/GREYSyntheticEvents.h"
#import "AppFramework/Matcher/GREYAllOf.h"
#import "AppFramework/Matcher/GREYAnyOf.h"
#import "AppFramework/Matcher/GREYMatchers.h"
#import "AppFramework/Matcher/GREYNot.h"
#import "AppFramework/Synchronization/GREYAppStateTracker.h"
#import "AppFramework/Synchronization/GREYSyncAPI.h"
#import "AppFramework/Synchronization/GREYUIThreadExecutor.h"
#import "CommonLib/Additions/NSString+GREYCommon.h"
#import "CommonLib/Assertion/GREYFatalAsserts.h"
#import "CommonLib/Assertion/GREYThrowDefines.h"
#import "CommonLib/Error/GREYScrollActionError.h"
#import "CommonLib/Error/NSError+GREYCommon.h"
#import "UILib/Additions/CGGeometry+GREYUI.h"

/**
 *  Scroll views under web views take at least (depending on speed of execution environment) two
 *  touch points to accurately determine scroll resistance.
 */
static const NSInteger kMinTouchPointsToDetectScrollResistance = 2;

@implementation GREYScrollAction {
  /**
   *  The direction in which the content must be scrolled.
   */
  GREYDirection _direction;
  /**
   *  The amount of scroll (in the units of scrollView's coordinate system) to be applied.
   */
  CGFloat _amount;
  /**
   *  The start point of the scroll defined as percentages of the visible area's width and height.
   *  If any of the coordinate is set to @c NAN the corresponding coordinate of the scroll start
   *  point will be set to achieve maximum scroll.
   */
  CGPoint _startPointPercents;
}

- (instancetype)initWithDirection:(GREYDirection)direction
                           amount:(CGFloat)amount
               startPointPercents:(CGPoint)startPointPercents {
  GREYThrowOnFailedConditionWithMessage(amount > 0,
                                        @"Scroll amount must be positive and greater than zero.");
  GREYThrowOnFailedConditionWithMessage(
      isnan(startPointPercents.x) || (startPointPercents.x > 0 && startPointPercents.x < 1),
      @"startPointPercents must be NAN or in the range (0, 1) "
      @"exclusive");
  GREYThrowOnFailedConditionWithMessage(
      isnan(startPointPercents.y) || (startPointPercents.y > 0 && startPointPercents.y < 1),
      @"startPointPercents must be NAN or in the range (0, 1) "
      @"exclusive");

  NSString *name =
      [NSString stringWithFormat:@"Scroll %@ for %g", NSStringFromGREYDirection(direction), amount];

  NSArray *classMatchers = @[
    [GREYMatchers matcherForKindOfClass:[UIScrollView class]],
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    // TODO: Perform a scan of UIWebView usage and deprecate if possible. // NOLINT
    [GREYMatchers matcherForKindOfClass:[UIWebView class]],
#pragma clang diagnostic pop
    [GREYMatchers matcherForKindOfClass:[WKWebView class]],
  ];
  id<GREYMatcher> systemAlertShownMatcher = [GREYMatchers matcherForSystemAlertViewShown];
  NSArray *constraintMatchers = @[
    [[GREYAnyOf alloc] initWithMatchers:classMatchers],
    [[GREYNot alloc] initWithMatcher:systemAlertShownMatcher]
  ];
  self =
      [super initWithName:name constraints:[[GREYAllOf alloc] initWithMatchers:constraintMatchers]];
  if (self) {
    _direction = direction;
    _amount = amount;
    _startPointPercents = startPointPercents;
  }
  return self;
}

- (instancetype)initWithDirection:(GREYDirection)direction amount:(CGFloat)amount {
  return [self initWithDirection:direction amount:amount startPointPercents:GREYCGPointNull];
}

#pragma mark - GREYAction

- (BOOL)perform:(id)element error:(__strong NSError **)errorOrNil {
  __block BOOL retVal = NO;
  grey_dispatch_sync_on_main_thread(^{
    // We aggressively access UI elements when performing the action, rather than having pieces
    // running on the main thread separately, the whole action will be performed on the main thread.
    retVal = [self grey_perform:element error:errorOrNil];
  });
  return retVal;
}

#pragma mark - Private

- (BOOL)grey_perform:(UIScrollView *)element error:(__strong NSError **)errorOrNil {
  if (![self satisfiesConstraintsForElement:element error:errorOrNil]) {
    return NO;
  }

  // To scroll WebViews we must use the UIScrollView in its heirarchy and scroll it.
  // TODO: Add tests for WKWebView.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  // TODO: Perform a scan of UIWebView usage and deprecate if possible. // NOLINT
  if ([element isKindOfClass:[UIWebView class]]) {
    element = [(UIWebView *)element scrollView];
  }
#pragma clang diagnostic pop
  if ([element isKindOfClass:[WKWebView class]]) {
    element = [(WKWebView *)element scrollView];
  }

  CGFloat amountRemaining = _amount;
  BOOL success = YES;
  while (amountRemaining > 0 && success) {
    @autoreleasepool {
      // To scroll the content view in a direction
      GREYDirection reverseDirection = [GREYConstants reverseOfDirection:_direction];
      NSArray *touchPath = [GREYPathGestureUtils touchPathForGestureInView:element
                                                             withDirection:reverseDirection
                                                                    length:amountRemaining
                                                        startPointPercents:_startPointPercents
                                                        outRemainingAmount:&amountRemaining];
      if (!touchPath) {
        I_GREYPopulateError(errorOrNil, kGREYScrollErrorDomain, kGREYScrollImpossible,
                            @"Cannot scroll, ensure that the selected scroll view "
                            @"is wide enough to scroll.");
        return NO;
      }
      success = [GREYScrollAction grey_injectTouchPath:touchPath onScrollView:element];
    }
  }
  if (!success) {
    I_GREYPopulateError(errorOrNil, kGREYScrollErrorDomain, kGREYScrollReachedContentEdge,
                        @"Cannot scroll, the scrollview is already at the edge.");
  }
  return success;
}

/**
 *  Injects the touch path into the given @c scrollView until the content edge could be reached.
 *
 *  @param touchPath  The touch path to be injected.
 *  @param scrollView The UIScrollView for the injection.
 *
 *  @return @c YES if entire touchPath was injected, else @c NO.
 */
+ (BOOL)grey_injectTouchPath:(NSArray<NSValue *> *)touchPath
                onScrollView:(UIScrollView *)scrollView {
  GREYFatalAssert([touchPath count] >= 1);

  // In scrollviews that have their bounce turned off the horizontal and vertical velocities are
  // not reliable for detecting scroll resistance because they report non-zero velocities even
  // when content edge has been reached. So we are using contentOffsets as a workaround. But note
  // that this can be broken by AUT since it can modify the offsets during the scroll and if it
  // resets the offset to the same point for kMinTouchPointsToDetectScrollResistance times, this
  // algorithm interprets it as scroll resistance and stops scrolling.
  BOOL shouldDetectResistanceFromContentOffset = !scrollView.bounces;
  CGPoint originalOffset = scrollView.contentOffset;
  CGPoint prevOffset = scrollView.contentOffset;

  GREYSyntheticEvents *eventGenerator = [[GREYSyntheticEvents alloc] init];
  [eventGenerator beginTouchAtPoint:touchPath[0].CGPointValue
                   relativeToWindow:scrollView.window
                  immediateDelivery:YES];
  BOOL hasResistance = NO;
  NSInteger consecutiveTouchPointsWithSameContentOffset = 0;
  for (NSUInteger touchPointIndex = 1; touchPointIndex < [touchPath count]; touchPointIndex++) {
    @autoreleasepool {
      CGPoint currentTouchPoint = [touchPath[touchPointIndex] CGPointValue];
      [eventGenerator continueTouchAtPoint:currentTouchPoint immediateDelivery:YES];
      BOOL detectedResistanceFromContentOffsets = NO;
      // Keep track of |consecutiveTouchPointsWithSameContentOffset| if we must detect resistance
      // from content offset.
      if (shouldDetectResistanceFromContentOffset) {
        if (CGPointEqualToPoint(prevOffset, scrollView.contentOffset)) {
          consecutiveTouchPointsWithSameContentOffset++;
        } else {
          consecutiveTouchPointsWithSameContentOffset = 0;
          prevOffset = scrollView.contentOffset;
        }
      }
      if (touchPointIndex > kMinTouchPointsToDetectScrollResistance) {
        if (shouldDetectResistanceFromContentOffset &&
            consecutiveTouchPointsWithSameContentOffset > kMinTouchPointsToDetectScrollResistance) {
          detectedResistanceFromContentOffsets = YES;
        }
        if ([scrollView grey_hasScrollResistance] || detectedResistanceFromContentOffsets) {
          // Looks like we have reached the edge we can stop scrolling now.
          hasResistance = YES;
          break;
        }
      }
    }
  }
  [eventGenerator endTouch];

  // Drain the main loop to process the touch path and finish scroll bounce animation if any.
  while ([[GREYAppStateTracker sharedInstance] currentState] & kGREYPendingUIScrollViewScrolling) {
    [[GREYUIThreadExecutor sharedInstance] drainOnce];
  }

  // If the scroll has content size smaller than the view size, even without resistance, offset
  // won't change and the scroll does not take any effect.
  BOOL hasOffsetChanged = !CGPointEqualToPoint(scrollView.contentOffset, originalOffset);
  return !hasResistance && hasOffsetChanged;
}

@end
