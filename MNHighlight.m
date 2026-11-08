#import "MNHighlight.h"
#import "MNDocument.h"
#import "MNLine.h"
#import <objc/runtime.h>

// Temporary attributes exist on iOS's NSLayoutManager (implemented in UIFoundation) but are
// missing from the public SDK headers, so they are declared here.
@interface NSLayoutManager (MNTemporaryAttributes)
- (void)addTemporaryAttribute:(NSAttributedStringKey)name value:(id)value forCharacterRange:(NSRange)range;
- (void)removeTemporaryAttribute:(NSAttributedStringKey)name forCharacterRange:(NSRange)range;
- (id)temporaryAttribute:(NSAttributedStringKey)name atCharacterIndex:(NSUInteger)index longestEffectiveRange:(NSRangePointer)effectiveRange inRange:(NSRange)rangeLimit;
@end

// The result colour is the yellow of the Notes app: RGB (226, 168, 0) on a light page and a
// brighter (255, 204, 0) on a dark one. It is a dynamic colour, so it follows light and dark mode by
// itself, and the same object is used everywhere so that it can be recognised by equality.
static UIColor *resultColor(void) {
	static UIColor *color;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		UIColor *light = [UIColor colorWithRed:226.0 / 255.0 green:168.0 / 255.0 blue:0.0 / 255.0 alpha:1];
		UIColor *dark = [UIColor colorWithRed:255.0 / 255.0 green:204.0 / 255.0 blue:0.0 / 255.0 alpha:1];
		color = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
			return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? dark : light;
		}];
	});
	return color;
}

// The flash that plays when a result appears (see "Flash of a new result" below), nil when none
// plays. It is declared up here because the colouring code asks which colour a result has right now.
@class MNFlash;
static MNFlash *gFlash;
static UIColor *flashColorOfCharacter(NSUInteger index);

// Calls `apply` with the colour for the result or name at `absolute`: the result colour in one piece, or,
// while it flashes, one character at a time with the colour that character has in the current frame.
static void forEachColoredPart(NSRange absolute, void (^apply)(NSRange part, UIColor *color)) {
	if (!gFlash) {
		apply(absolute, resultColor());
		return;
	}
	for (NSUInteger i = absolute.location; i < NSMaxRange(absolute); i++) {
		apply(NSMakeRange(i, 1), flashColorOfCharacter(i) ?: resultColor());
	}
}

// The red mark under the operand that makes an expression lose its value (the "0" in 5/0, ...).
static UIColor *errorColor(void) {
	return [UIColor systemRedColor];
}

#pragma mark - Red mark under "=" (both TextKit versions)

// Notes does not draw an underline set through rendering attributes (the colour of the same
// attribute set is drawn, the underline is not), so the mark is a thin red view placed under the
// operand itself. It is a subview of the text view, so it scrolls with the text, and it is placed
// again after every edit.
static void updateErrorMarks(ICBaseTextView *tv) {
	NSString *all = tv.text;
	NSArray<NSValue *> *marks = [all rangeOfString:@"="].location != NSNotFound ? MNDocumentForText(all).errorRanges : @[];

	NSMutableArray<UIView *> *pool = tv.mnMarkViews;
	if (!pool) {
		pool = [NSMutableArray array];
		tv.mnMarkViews = pool;
	}
	NSUInteger used = 0;
	for (NSValue *value in marks) {
		NSRange r = value.rangeValue;
		UITextRange *range = MNTextRange(tv, r);
		if (!range) continue;
		CGRect start = [tv caretRectForPosition:range.start];
		CGRect end = [tv caretRectForPosition:range.end];
		// The two carets bracket the operand on one line; they would not on a wrapped line.
		if (CGRectIsNull(start) || CGRectIsInfinite(start) || fabs(start.origin.y - end.origin.y) > 1 || end.origin.x <= start.origin.x) continue;
		UIView *mark;
		if (used < pool.count) {
			mark = pool[used];
		} else {
			mark = [UIView new];
			mark.backgroundColor = errorColor();
			mark.userInteractionEnabled = NO;
			mark.layer.cornerRadius = 1;
			[pool addObject:mark];
		}
		mark.frame = CGRectMake(start.origin.x, CGRectGetMaxY(start) - 1, end.origin.x - start.origin.x, 2);
		if (mark.superview != tv) [tv addSubview:mark];
		MNLog(@"red mark under '%@' at %lu: %@", [all substringWithRange:r], (unsigned long)r.location, NSStringFromCGRect(mark.frame));
		used++;
	}
	for (NSUInteger i = used; i < pool.count; i++) [pool[i] removeFromSuperview];
}

#pragma mark - TextKit 2

// The whole text of a TextKit 2 text view, needed to know which variables are defined above a paragraph.
static NSString *documentText(NSTextLayoutManager *manager) {
	NSTextContentManager *content = manager.textContentManager;
	if ([content isKindOfClass:[NSTextContentStorage class]]) return ((NSTextContentStorage *)content).textStorage.string;
	return nil;
}

// The text range for `absolute`, an offset range in the whole document.
static NSTextRange *textRangeAt(NSTextLayoutManager *manager, NSRange absolute) {
	id<NSTextLocation> origin = manager.documentRange.location;
	id<NSTextLocation> start = [manager locationFromLocation:origin withOffset:(NSInteger)absolute.location];
	id<NSTextLocation> end = [manager locationFromLocation:origin withOffset:(NSInteger)NSMaxRange(absolute)];
	return (start && end) ? [[NSTextRange alloc] initWithLocation:start endLocation:end] : nil;
}

// Removes the result colour this tweak set earlier inside `paragraph` (and nothing else). Rendering
// attributes stay on the characters they were set on, so without this a name that was coloured
// stays coloured after the result next to it was edited ("a+b" in "a+b=4" once the 3 became a 4).
static void clearResultColor(NSTextLayoutManager *manager, NSTextRange *paragraph) {
	UIColor *color = resultColor();
	NSMutableArray<NSTextRange *> *ours = [NSMutableArray array];
	[manager enumerateRenderingAttributesFromLocation:paragraph.location reverse:NO
		usingBlock:^BOOL(NSTextLayoutManager *mgr, NSDictionary<NSAttributedStringKey, id> *attributes, NSTextRange *range) {
		if ([range.location compare:paragraph.endLocation] != NSOrderedAscending) return NO;
		if ([attributes[NSForegroundColorAttributeName] isEqual:color]) {
			NSTextRange *inside = [range textRangeByIntersectingWithTextRange:paragraph];
			if (inside) [ours addObject:inside];
		}
		return YES;
	}];
	for (NSTextRange *range in ours) [manager removeRenderingAttribute:NSForegroundColorAttributeName forTextRange:range];
}

// Called by the layout manager for each paragraph it lays out: the results that are still correct
// and, in a definition line, the names that a correct calculation further down reads ("a" and "b"
// in "a=1 b=2" once "a+b=3" follows) take the result colour. Every paragraph of one layout pass
// asks the same MNDocument, so the note is read once, not once per paragraph.
static void highlightFragment(NSTextLayoutManager *manager, NSTextLayoutFragment *fragment) {
	NSTextElement *element = fragment.textElement;
	if (![element isKindOfClass:[NSTextParagraph class]]) return;
	NSString *text = ((NSTextParagraph *)element).attributedString.string;
	NSTextRange *elementRange = element.elementRange;
	if (!elementRange) return;
	clearResultColor(manager, elementRange); // also when the "=" is gone: nothing stays coloured by accident
	if ([text rangeOfString:@"="].location == NSNotFound) return;

	NSInteger offset = [manager offsetFromLocation:manager.documentRange.location toLocation:elementRange.location];
	if (offset < 0) return;
	NSString *document = documentText(manager);
	NSArray<NSValue *> *colored;
	if (document) {
		colored = [MNDocumentForText(document) coloredRangesInParagraphAt:(NSUInteger)offset];
	} else {
		// Without the note around the paragraph there are no variables: its results alone.
		NSMutableArray<NSValue *> *absolute = [NSMutableArray array];
		for (NSValue *value in MNConfirmedResultRanges(text, nil)) {
			[absolute addObject:[NSValue valueWithRange:NSMakeRange((NSUInteger)offset + value.rangeValue.location, value.rangeValue.length)]];
		}
		colored = absolute;
	}
	for (NSValue *value in colored) {
		MNLog(@"highlight %@", NSStringFromRange(value.rangeValue));
		forEachColoredPart(value.rangeValue, ^(NSRange part, UIColor *color) {
			NSTextRange *range = textRangeAt(manager, part);
			if (range) [manager addRenderingAttribute:NSForegroundColorAttributeName value:color forTextRange:range];
		});
	}
}

static void installTextKit2(ICBaseTextView *tv, NSTextLayoutManager *manager) {
	if (tv.mnHighlightInstalled) return;
	tv.mnHighlightInstalled = @YES;
	MNLog(@"highlight install (TextKit 2): validator=%d", manager.renderingAttributesValidator != nil);

	// Keep any validator Notes already installed (find, links, ...) and add ours after it.
	// The block must not capture the text view, which owns this layout manager.
	void (^previous)(NSTextLayoutManager *, NSTextLayoutFragment *) = manager.renderingAttributesValidator;
	manager.renderingAttributesValidator = ^(NSTextLayoutManager *mgr, NSTextLayoutFragment *fragment) {
		if (previous) previous(mgr, fragment);
		highlightFragment(mgr, fragment);
	};
	[manager invalidateRenderingAttributesForTextRange:manager.documentRange];
}

// The names (absolute ranges in the document) that last had the result colour, kept on the layout
// manager so that only names whose colour changes are redrawn.
static char kMNColoredNames;

// Asks the views that draw the note's paragraphs to draw again: all of them (`rect` CGRectNull) or
// only those that overlap `rect`, in the text view's coordinates. Switching between dark and light
// mode does this, and every name showed its colour afterwards: the colour was already set, only the
// repaint was missing. The views are private classes, found by name ("...LayoutFragment..."), and
// if none is found every descendant of the text view is redrawn instead.
static void redrawFragmentsIn(UIView *textView, UIView *view, CGRect rect, NSUInteger *count) {
	BOOL everywhere = CGRectIsNull(rect);
	for (UIView *subview in view.subviews) {
		BOOL fragment = [NSStringFromClass([subview class]) containsString:@"Fragment"];
		if (fragment && (everywhere || CGRectIntersectsRect([subview convertRect:subview.bounds toView:textView], rect))) {
			[subview setNeedsDisplay];
			(*count)++;
		}
		if (!fragment || everywhere) redrawFragmentsIn(textView, subview, rect, count);
	}
}

static void redrawEveryDescendant(UIView *view) {
	for (UIView *subview in view.subviews) {
		[subview setNeedsDisplay];
		redrawEveryDescendant(subview);
	}
}

static void redrawFragmentViews(UIView *textView, CGRect rect) {
	NSUInteger count = 0;
	redrawFragmentsIn(textView, textView, rect, &count);
	if (count == 0 && !CGRectIsNull(rect)) redrawFragmentsIn(textView, textView, CGRectNull, &count);
	if (count == 0) redrawEveryDescendant(textView);
	MNLog(@"redrawing %lu view(s)", (unsigned long)count);
}

// The names in a definition line take the result colour because of a calculation further down.
// When that calculation is typed, the definition's paragraph is not laid out again, so the validator
// never gets to see the change: the names are coloured (or uncoloured) directly instead, and the
// paragraphs redrawn when a name's colour changed, since setting a rendering attribute does not
// repaint a paragraph that is already on screen.
static void refreshDefinitionColors(UIView *tv, NSTextLayoutManager *manager) {
	NSString *document = documentText(manager);
	MNLog(@"definition colours: document has %lu characters", (unsigned long)document.length);
	if (document.length == 0) return;

	NSSet<NSValue *> *before = objc_getAssociatedObject(manager, &kMNColoredNames) ?: [NSSet set];
	NSMutableSet<NSValue *> *now = [NSMutableSet set];
	__block BOOL repaint = NO;
	[MNDocumentForText(document) enumerateDefinitionNames:^(NSRange name, BOOL used) {
		NSTextRange *range = textRangeAt(manager, name);
		if (!range) return;
		NSValue *key = [NSValue valueWithRange:name];
		if (used) {
			[now addObject:key];
			[manager addRenderingAttribute:NSForegroundColorAttributeName value:resultColor() forTextRange:range];
		} else {
			[manager removeRenderingAttribute:NSForegroundColorAttributeName forTextRange:range];
		}
		if (used != [before containsObject:key]) {
			MNLog(@"name '%@' @%lu is now %@", [document substringWithRange:name], (unsigned long)name.location, used ? @"coloured" : @"plain");
			repaint = YES;
		}
	}];

	// Names that were coloured before and are no longer definitions (their line was edited away).
	for (NSValue *key in before) {
		if (![now containsObject:key] && NSMaxRange(key.rangeValue) <= document.length) {
			NSTextRange *range = textRangeAt(manager, key.rangeValue);
			if (range) [manager removeRenderingAttribute:NSForegroundColorAttributeName forTextRange:range];
		}
	}
	objc_setAssociatedObject(manager, &kMNColoredNames, now, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	if (repaint) redrawFragmentViews(tv, CGRectNull);
}

#pragma mark - TextKit 1

// The layout manager of a TextKit 1 text view, or nil when the text view uses TextKit 2.
// Never touch -layoutManager on a TextKit 2 text view: that silently switches it to TextKit 1.
static NSLayoutManager *textKit1Manager(ICBaseTextView *tv) {
	if (@available(iOS 16.0, *)) {
		if (tv.textLayoutManager) return nil;
	}
	return tv.layoutManager;
}

// The layout manager of a TextKit 2 text view, or nil (TextKit 1, or earlier than iOS 16).
static NSTextLayoutManager *textKit2Manager(ICBaseTextView *tv) {
	if (@available(iOS 16.0, *)) return tv.textLayoutManager;
	return nil;
}

// Removes the temporary attribute `key` from the parts of `paragraph` where it equals `value`
// (the ones this tweak added).
static void clearOurs(NSLayoutManager *manager, NSRange paragraph, NSAttributedStringKey key, id value) {
	NSUInteger i = paragraph.location;
	while (i < NSMaxRange(paragraph)) {
		NSRange effective;
		id current = [manager temporaryAttribute:key atCharacterIndex:i longestEffectiveRange:&effective inRange:paragraph];
		if ([current isEqual:value]) [manager removeTemporaryAttribute:key forCharacterRange:effective];
		i = MAX(NSMaxRange(effective), i + 1);
	}
}

// Recolours every paragraph that overlaps `range`: removes the result colour this tweak applied
// earlier (and nothing else), then applies it to the results and definition names that are still due.
static void highlightTextKit1(ICBaseTextView *tv, NSLayoutManager *manager, NSRange range) {
	NSString *all = tv.text;
	if (NSMaxRange(range) > all.length) return;
	UIColor *color = resultColor();
	MNDocument *document = MNDocumentForText(all);
	NSRange first = [all lineRangeForRange:NSMakeRange(range.location, 0)];
	range = NSMakeRange(first.location, NSMaxRange(range) - first.location);
	[all enumerateSubstringsInRange:range options:NSStringEnumerationByParagraphs | NSStringEnumerationSubstringNotRequired
		usingBlock:^(NSString *substring, NSRange paragraph, NSRange enclosing, BOOL *stop) {
		clearOurs(manager, paragraph, NSForegroundColorAttributeName, color);
		for (NSValue *value in [document coloredRangesInParagraphAt:paragraph.location]) {
			MNLog(@"highlight '%@'", [all substringWithRange:value.rangeValue]);
			forEachColoredPart(value.rangeValue, ^(NSRange part, UIColor *partColor) {
				[manager addTemporaryAttribute:NSForegroundColorAttributeName value:partColor forCharacterRange:part];
			});
		}
	}];
}

#pragma mark - Flash of a new result

// iOS 18 plays a short colour animation on a result that has just appeared: each digit starts in
// the text colour, lights up in a bright yellow and settles into the usual yellow, and the digits go
// one after the other from left to right, so the bright spot sweeps across the number. The colour
// is not a layout change, so it is driven from a display link that sets the colour of every digit
// every frame (forEachColoredPart makes the colouring code above follow it) and, in TextKit 2,
// redraws the paragraph views, since a rendering attribute set on its own does not repaint them.

static const CFTimeInterval kCharDuration = 0.5;  // one digit: text colour, bright yellow, usual yellow
static const CFTimeInterval kCharDelay = 0.07;    // each digit starts this much later than the one on its left
static const CFTimeInterval kMaxTotal = 1.0;      // a long result sweeps faster instead of taking longer than this
static const double kFlashPeak = 0.4;              // share of a digit's time at which its yellow is brightest

// One animated character, prepared when the flash begins so that a frame only does the minimum.
@interface MNFlashCharacter : NSObject
@property (nonatomic) NSUInteger index;               // absolute index in the text
@property (nonatomic) NSUInteger step;                // its position inside its result (decides when it starts)
@property (nonatomic) double drawnProgress;           // progress it was last drawn with, -1 before the first frame
@property (nonatomic, strong) UIColor *color;         // its colour in the current frame, nil before the first
@property (nonatomic, strong) NSTextRange *textRange; // TextKit 2: its range, computed once; nil in TextKit 1 or when unknown
@end

@implementation MNFlashCharacter
@end

// Everything about the flash that is playing. It is also the display link's target; the link holds
// it until the flash finishes and invalidates the link.
@interface MNFlash : NSObject {
@public
	CGFloat _startRGB[3], _peakRGB[3], _endRGB[3]; // the three colours, resolved once for the text view's traits
}
@property (nonatomic, weak) ICBaseTextView *textView;
@property (nonatomic, copy) NSArray<NSValue *> *ranges; // absolute ranges of the results being animated
@property (nonatomic, copy) NSArray<NSString *> *texts; // their text when the flash began: a range holds while its text is the same
@property (nonatomic, copy) NSArray<MNFlashCharacter *> *characters;
@property (nonatomic, copy) NSDictionary<NSNumber *, MNFlashCharacter *> *charactersByIndex;
@property (nonatomic) CFTimeInterval startTime;
@property (nonatomic) CFTimeInterval delay;             // start delay between two neighbouring digits
@property (nonatomic) CFTimeInterval total;             // how long the whole flash lasts
@property (nonatomic) CGRect rect;                      // where the animated results are, in the text view's coordinates
@property (nonatomic, strong) CADisplayLink *link;
@end

static UIColor *flashColorOfCharacter(NSUInteger index) {
	return gFlash.charactersByIndex[@(index)].color;
}

static void colorComponents(UIColor *color, UITraitCollection *traits, CGFloat out[4]) {
	[[color resolvedColorWithTraitCollection:traits] getRed:&out[0] green:&out[1] blue:&out[2] alpha:&out[3]];
}

// The three colours of the flash for these traits, resolved once per flash instead of once per digit per frame.
static void prepareFlashColors(MNFlash *flash, UITraitCollection *traits) {
	// The brightest yellow: a touch lighter on a dark page, where it has to stand out from white text.
	BOOL dark = traits.userInterfaceStyle == UIUserInterfaceStyleDark;
	CGFloat start[4], end[4];
	colorComponents([UIColor labelColor], traits, start);
	colorComponents(resultColor(), traits, end);
	CGFloat peak[3] = {1.0, dark ? 0.84 : 0.76, dark ? 0.20 : 0.0};
	for (int c = 0; c < 3; c++) {
		flash->_startRGB[c] = start[c];
		flash->_peakRGB[c] = peak[c];
		flash->_endRGB[c] = end[c];
	}
}

static UIColor *flashColorAt(MNFlash *flash, double progress) {
	const CGFloat *from, *to;
	double t;
	if (progress < kFlashPeak) {
		from = flash->_startRGB;
		to = flash->_peakRGB;
		t = progress / kFlashPeak;
	} else {
		from = flash->_peakRGB;
		to = flash->_endRGB;
		t = (progress - kFlashPeak) / (1 - kFlashPeak);
	}
	return [UIColor colorWithRed:from[0] + (to[0] - from[0]) * t green:from[1] + (to[1] - from[1]) * t
		blue:from[2] + (to[2] - from[2]) * t alpha:1];
}

// Sets the colour every animated digit has `elapsed` seconds into the flash. A digit that has not
// started yet or has finished keeps its colour and is skipped.
static void applyFlashFrame(MNFlash *flash, ICBaseTextView *tv, CFTimeInterval elapsed) {
	NSUInteger length = tv.text.length;
	NSLayoutManager *manager = textKit1Manager(tv);
	NSTextLayoutManager *textManager = manager ? nil : textKit2Manager(tv);
	if (!manager && !textManager) return;
	BOOL changed = NO;
	for (MNFlashCharacter *character in flash.characters) {
		double progress = MIN(MAX((elapsed - flash.delay * (double)character.step) / kCharDuration, 0), 1);
		if (progress == character.drawnProgress) continue;
		character.drawnProgress = progress;
		UIColor *color = flashColorAt(flash, progress);
		character.color = color;
		changed = YES;
		if (manager) {
			if (character.index < length) {
				[manager addTemporaryAttribute:NSForegroundColorAttributeName value:color forCharacterRange:NSMakeRange(character.index, 1)];
			}
		} else if (character.textRange) {
			[textManager addRenderingAttribute:NSForegroundColorAttributeName value:color forTextRange:character.textRange];
		}
	}
	if (changed && textManager) redrawFragmentViews(tv, flash.rect);
}

// Whether every animated result is still where it was and reads the same. Typing after it, on the
// next line for instance, leaves it intact.
static BOOL flashIntact(MNFlash *flash, ICBaseTextView *tv) {
	NSString *all = tv.text;
	for (NSUInteger i = 0; i < flash.ranges.count; i++) {
		NSRange r = flash.ranges[i].rangeValue;
		if (NSMaxRange(r) > all.length || ![[all substringWithRange:r] isEqualToString:flash.texts[i]]) return NO;
	}
	return YES;
}

// Ends the flash: the results go back to the plain result colour (or to whatever the validator makes of them).
static void finishFlash(void) {
	MNFlash *flash = gFlash;
	if (!flash) return;
	gFlash = nil; // from here on the colouring code uses the plain result colour again
	[flash.link invalidate];
	flash.link = nil;
	ICBaseTextView *tv = flash.textView;
	if (!tv || !tv.window) return;
	BOOL unchanged = flashIntact(flash, tv);

	NSUInteger length = tv.text.length;
	NSLayoutManager *manager = textKit1Manager(tv);
	if (manager) {
		for (NSValue *value in flash.ranges) {
			NSRange r = value.rangeValue;
			if (NSMaxRange(r) > length) continue;
			if (unchanged) [manager addTemporaryAttribute:NSForegroundColorAttributeName value:resultColor() forCharacterRange:r];
			else [manager removeTemporaryAttribute:NSForegroundColorAttributeName forCharacterRange:r]; // the next refresh recolours
		}
		return;
	}
	NSTextLayoutManager *textManager = textKit2Manager(tv);
	if (!textManager) return;
	for (NSValue *value in flash.ranges) {
		if (NSMaxRange(value.rangeValue) > length) continue;
		NSTextRange *range = textRangeAt(textManager, value.rangeValue);
		if (!range) continue;
		if (unchanged) {
			// Set the result colour right here: waiting for the validator left the result in the
			// text colour until the next edit.
			[textManager addRenderingAttribute:NSForegroundColorAttributeName value:resultColor() forTextRange:range];
		} else {
			[textManager removeRenderingAttribute:NSForegroundColorAttributeName forTextRange:range];
			[textManager invalidateRenderingAttributesForTextRange:range]; // the validator decides again
		}
	}
	// Results still where they were: only their paragraphs need drawing again. Edited ones may have
	// moved anywhere, so then everything is redrawn.
	redrawFragmentViews(tv, unchanged ? flash.rect : CGRectNull);
}

@implementation MNFlash
- (void)tick:(CADisplayLink *)link {
	// A flash that was replaced without finishing: just stop.
	if (self != gFlash) {
		[link invalidate];
		return;
	}
	ICBaseTextView *tv = self.textView;
	CFTimeInterval elapsed = CACurrentMediaTime() - self.startTime;
	if (!tv || !tv.window || elapsed >= self.total) {
		finishFlash();
		return;
	}
	applyFlashFrame(self, tv, elapsed);
}
@end

void MNHighlightFlashResults(ICBaseTextView *tv, NSArray<NSValue *> *ranges) {
	finishFlash();
	if (!tv.window || ranges.count == 0) return;
	NSString *all = tv.text;
	NSMutableArray<NSValue *> *valid = [NSMutableArray array];
	NSMutableArray<NSString *> *texts = [NSMutableArray array];
	NSUInteger longest = 0; // the longest result decides how long the sweep takes
	for (NSValue *value in ranges) {
		NSRange r = value.rangeValue;
		if (r.length == 0 || NSMaxRange(r) > all.length) continue;
		[valid addObject:value];
		[texts addObject:[all substringWithRange:r]];
		longest = MAX(longest, r.length);
	}
	if (valid.count == 0) return;
	MNLog(@"flash %lu result(s)", (unsigned long)valid.count);

	MNFlash *flash = [MNFlash new];
	flash.textView = tv;
	flash.ranges = valid;
	flash.texts = texts;
	flash.startTime = CACurrentMediaTime();
	// A long result starts its digits closer together so the whole flash never outlasts kMaxTotal.
	flash.delay = longest > 1 ? MIN(kCharDelay, (kMaxTotal - kCharDuration) / (double)(longest - 1)) : kCharDelay;
	flash.total = kCharDuration + flash.delay * (double)(longest - 1);
	prepareFlashColors(flash, tv.traitCollection);

	NSMutableArray<MNFlashCharacter *> *characters = [NSMutableArray array];
	NSMutableDictionary<NSNumber *, MNFlashCharacter *> *byIndex = [NSMutableDictionary dictionary];
	CGRect rect = CGRectNull;
	NSTextLayoutManager *textManager = textKit2Manager(tv);
	for (NSValue *value in valid) {
		NSRange r = value.rangeValue;
		// TextKit 2: the locations are computed once here, a character at a time from the result's start.
		id<NSTextLocation> location = textManager ? [textManager locationFromLocation:textManager.documentRange.location withOffset:(NSInteger)r.location] : nil;
		for (NSUInteger k = 0; k < r.length; k++) {
			MNFlashCharacter *character = [MNFlashCharacter new];
			character.index = r.location + k;
			character.step = k;
			character.drawnProgress = -1;
			if (textManager) {
				id<NSTextLocation> next = [textManager locationFromLocation:location withOffset:1];
				// Without a range such a digit just does not flash.
				if (location && next) character.textRange = [[NSTextRange alloc] initWithLocation:location endLocation:next];
				location = next;
			}
			[characters addObject:character];
			byIndex[@(character.index)] = character;
		}
		UITextRange *textRange = MNTextRange(tv, r);
		for (UITextSelectionRect *selection in textRange ? [tv selectionRectsForRange:textRange] : @[]) {
			rect = CGRectUnion(rect, CGRectInset(selection.rect, -4, -4));
		}
	}
	flash.characters = characters;
	flash.charactersByIndex = byIndex;
	flash.rect = rect;

	gFlash = flash;
	flash.link = [CADisplayLink displayLinkWithTarget:flash selector:@selector(tick:)];
	[flash.link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
	applyFlashFrame(flash, tv, 0);
}

void MNHighlightTextChanged(ICBaseTextView *tv) {
	if (gFlash && gFlash.textView == tv && !flashIntact(gFlash, tv)) finishFlash();
}

#pragma mark - Entry points

void MNHighlightInstall(ICBaseTextView *tv) {
	if (!tv.window) return;
	updateErrorMarks(tv);
	NSLayoutManager *manager = textKit1Manager(tv);
	if (manager) {
		MNLog(@"highlight scan (TextKit 1), %lu characters", (unsigned long)tv.text.length);
		highlightTextKit1(tv, manager, NSMakeRange(0, tv.text.length));
		return;
	}
	NSTextLayoutManager *textManager = textKit2Manager(tv);
	if (textManager) installTextKit2(tv, textManager);
}

void MNHighlightRefreshLine(ICBaseTextView *tv) {
	if (!tv.window) return;
	updateErrorMarks(tv);
	NSString *all = tv.text;
	NSLayoutManager *manager = textKit1Manager(tv);
	if (!manager) {
		// TextKit 2 colours a paragraph when it is laid out, but a calculation typed below a
		// definition changes that definition's colour without touching its paragraph.
		NSTextLayoutManager *textManager = textKit2Manager(tv);
		BOOL installed = tv.mnHighlightInstalled != nil;
		BOOL hasEquals = [all rangeOfString:@"="].location != NSNotFound;
		MNLog(@"refresh colours (TextKit 2): manager=%d installed=%d hasEquals=%d", textManager != nil, installed, hasEquals);
		if (textManager && installed && hasEquals) refreshDefinitionColors(tv, textManager);
		return;
	}
	NSRange sel = tv.selectedRange;
	if (sel.location > all.length) return;
	// A definition elsewhere in the note can change colour with this edit, or a result below a
	// changed definition: recolour all of it then.
	if (MNDocumentForText(all).hasDefinitions) highlightTextKit1(tv, manager, NSMakeRange(0, all.length));
	else highlightTextKit1(tv, manager, [all lineRangeForRange:NSMakeRange(sel.location, 0)]);
}
