#import "MNResultTap.h"
#import "MNDocument.h"
#import <objc/runtime.h>

API_AVAILABLE(ios(16.0))
@interface MNResultTapController : NSObject <UIGestureRecognizerDelegate, UIEditMenuInteractionDelegate>
@property (nonatomic, weak) ICBaseTextView *textView;
@property (nonatomic, strong) UIEditMenuInteraction *interaction;
@property (nonatomic) NSRange result;       // the tapped result, as a range of the note's text
@property (nonatomic) CGRect resultRect;    // where it sits, in the text view
@end

@implementation MNResultTapController

// Whether `point` is on a result that is still correct; if so remembers it.
- (BOOL)findResultAtPoint:(CGPoint)point {
	ICBaseTextView *tv = self.textView;
	if (!tv || !tv.window) return NO;
	NSString *all = tv.text;
	UITextPosition *position = [tv closestPositionToPoint:point];
	if (!position) return NO;
	NSInteger offset = [tv offsetFromPosition:tv.beginningOfDocument toPosition:position];
	if (offset < 0 || offset > (NSInteger)all.length) return NO;

	NSRange paragraph = [all paragraphRangeForRange:NSMakeRange((NSUInteger)offset, 0)];
	if ([all rangeOfString:@"=" options:0 range:paragraph].location == NSNotFound) return NO;

	for (NSValue *value in [MNDocumentForText(all) resultRangesInParagraphAt:paragraph.location]) {
		NSRange absolute = value.rangeValue;
		UITextRange *range = MNTextRange(tv, absolute);
		if (!range) continue;
		CGRect rect = [tv firstRectForRange:range];
		if (CGRectIsNull(rect) || CGRectIsInfinite(rect) || CGRectIsEmpty(rect)) continue;
		// A little slack, so the number is easy to hit; the blank space after the line is not a hit.
		if (!CGRectContainsPoint(CGRectInset(rect, -12, -10), point)) continue;
		self.result = absolute;
		self.resultRect = rect;
		return YES;
	}
	return NO;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
	return [self findResultAtPoint:[gestureRecognizer locationInView:self.textView]];
}

// Notes has its own taps (caret, links...); ours must not hold them back.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
	return YES;
}

- (void)tapped:(UITapGestureRecognizer *)tap {
	if (tap.state != UIGestureRecognizerStateRecognized) return;
	if (![self findResultAtPoint:[tap locationInView:self.textView]]) return;
	NSRange result = self.result;
	CGRect rect = self.resultRect;
	MNLog(@"tap on a result at %@", NSStringFromRange(result));

	// The same tap makes Notes place the caret; let that settle, then select the result and show
	// the standard edit menu on it.
	__weak MNResultTapController *weakSelf = self;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		MNResultTapController *strongSelf = weakSelf;
		ICBaseTextView *tv = strongSelf.textView;
		if (!tv || !tv.window || NSMaxRange(result) > tv.text.length) return;
		if (!tv.isFirstResponder) [tv becomeFirstResponder];
		tv.selectedRange = result;
		MNLog(@"selected '%@'", [tv.text substringWithRange:result]);
		UIEditMenuConfiguration *configuration = [UIEditMenuConfiguration configurationWithIdentifier:nil
			sourcePoint:CGPointMake(CGRectGetMidX(rect), CGRectGetMinY(rect))];
		configuration.preferredArrowDirection = UIEditMenuArrowDirectionDown;
		[strongSelf.interaction presentEditMenuWithConfiguration:configuration];
	});
}

- (CGRect)editMenuInteraction:(UIEditMenuInteraction *)interaction targetRectForConfiguration:(UIEditMenuConfiguration *)configuration {
	return self.resultRect;
}

// The standard actions the responder chain offers for the selected text (Copy, Cut, Paste, Look Up,
// ...), unchanged.
- (UIMenu *)editMenuInteraction:(UIEditMenuInteraction *)interaction menuForConfiguration:(UIEditMenuConfiguration *)configuration
	suggestedActions:(NSArray<UIMenuElement *> *)suggestedActions {
	MNLog(@"edit menu: %lu standard action(s)", (unsigned long)suggestedActions.count);
	return [UIMenu menuWithChildren:suggestedActions];
}

@end

void MNResultTapInstall(ICBaseTextView *tv) {
	if (@available(iOS 16.0, *)) {
		if (tv.mnResultTapController) return;
		MNResultTapController *controller = [MNResultTapController new];
		controller.textView = tv;
		controller.interaction = [[UIEditMenuInteraction alloc] initWithDelegate:controller];
		[tv addInteraction:controller.interaction];

		UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:controller action:@selector(tapped:)];
		tap.cancelsTouchesInView = NO;
		tap.delegate = controller;
		[tv addGestureRecognizer:tap];

		tv.mnResultTapController = controller;
		MNLog(@"result tap installed on %@", NSStringFromClass([tv class]));
	}
}
