#import "MNCommon.h"
#import "MNFormat.h"
#import "MNHighlight.h"
#import "MNLine.h"
#import "MNLive.h"
#import "MNResultTap.h"
#import "MNVariables.h"

// NoteMath18: type "expr =" in Notes and get the result. iOS 18 has Math Notes built in, so the
// package refuses to install there (see `control`).
//
// Like iOS 18, the result is first only a suggestion: typing "1+1=" shows "1+1=2" (yellow, nothing
// re-spaced, the caret in front of the 2). Space or return accepts it: the expression is re-spaced
// as "1 + 1 = 2" and the 2 plays its colour animation. Anything else typed, a backspace, or moving
// the caret takes the suggestion away again. The suggestion is real text in the note while it
// shows, so it is removed again from the note in all those cases.

static __weak ICBaseTextView *gPendingView;
static NSRange gPendingRange;     // where the suggested result sits in the note
static NSString *gPendingText;    // the suggested result; nil when there is no suggestion
static BOOL gPendingBusy;         // the tweak is editing or moving the caret itself

static void clearPending(void) {
	gPendingView = nil;
	gPendingText = nil;
	gPendingRange = NSMakeRange(NSNotFound, 0);
}

// Whether `tv` shows a suggestion that is still intact in its text.
static BOOL pendingActive(ICBaseTextView *tv) {
	if (!gPendingText || gPendingView != tv) return NO;
	NSString *all = tv.text;
	if (NSMaxRange(gPendingRange) > all.length || ![[all substringWithRange:gPendingRange] isEqualToString:gPendingText]) {
		clearPending();
		return NO;
	}
	return YES;
}

// Takes the suggestion out of the note and keeps the caret where it was.
static void dropPending(ICBaseTextView *tv) {
	NSRange r = gPendingRange;
	clearPending();
	NSTextStorage *ts = tv.textStorage;
	if (!ts || NSMaxRange(r) > ts.length) return;
	NSRange sel = tv.selectedRange;
	NSRange wanted = sel;
	if (sel.location >= NSMaxRange(r)) wanted.location -= r.length;
	else if (sel.location > r.location) wanted.location = r.location;
	gPendingBusy = YES;
	MNWithoutUndo(tv, ^{
		[ts replaceCharactersInRange:r withString:@""];
		if (!NSEqualRanges(tv.selectedRange, wanted)) tv.selectedRange = wanted;
	});
	gPendingBusy = NO;
	MNLog(@"suggestion dropped");
	MNHighlightRefreshLine(tv);
}

// Space or return: the suggestion becomes the result of the calculation.
static void commitPending(ICBaseTextView *tv) {
	NSRange r = gPendingRange;
	NSString *result = gPendingText;
	clearPending();
	NSString *all = tv.text;
	if (r.location == 0 || [all characterAtIndex:r.location - 1] != '=') return;
	NSUInteger lineStart = [all lineRangeForRange:NSMakeRange(r.location, 0)].location;
	NSString *left = [all substringWithRange:NSMakeRange(lineStart, r.location - 1 - lineStart)];
	NSRange exprRange;
	NSString *check = MNEvaluateLine(left, MNCollectVariables(all, lineStart), &exprRange, NULL);
	if (![check isEqualToString:result]) return;

	// "1+1=" becomes "1 + 1 = " in front of the result that is already there.
	NSString *prefix = [MNNormalizeExpression([left substringWithRange:exprRange]) stringByAppendingString:@" = "];
	NSUInteger from = lineStart + exprRange.location;
	UITextRange *range = MNTextRange(tv, NSMakeRange(from, r.location - from));
	if (!range) return;
	gPendingBusy = YES;
	[tv replaceRange:range withText:prefix];
	NSUInteger resultStart = from + prefix.length;
	tv.selectedRange = NSMakeRange(resultStart + result.length, 0);
	gPendingBusy = NO;
	MNLog(@"suggestion '%@' accepted", result);
	MNHighlightRefreshLine(tv);
	MNHighlightFlashResults(tv, @[[NSValue valueWithRange:NSMakeRange(resultStart, result.length)]]);
}

%hook ICBaseTextView

%property (nonatomic, strong) NSNumber *mnGeneration;
%property (nonatomic, strong) NSNumber *mnHighlightInstalled;
%property (nonatomic, strong) NSMutableArray *mnMarkViews;
%property (nonatomic, strong) id mnResultTapController;

// Once the text view is on screen: colours for results, names and errors, and the tap on a result.
- (void)didMoveToWindow {
	%orig;
	MNHighlightInstall(self);
	if (self.window) MNResultTapInstall(self);
}

// Typing "=" after an expression offers the result; space or return accepts it, anything else
// makes it go away.
- (void)insertText:(NSString *)text {
	if (pendingActive(self)) {
		NSRange sel = self.selectedRange;
		BOOL atSuggestion = sel.length == 0 && sel.location == gPendingRange.location;
		BOOL space = [text isEqualToString:@" "], newline = [text isEqualToString:@"\n"];
		if (atSuggestion && (space || newline)) {
			commitPending(self);
			if (newline) { %orig; } // return still starts a new line; the space only accepts
			return;
		}
		dropPending(self);
	}
	if ([text isEqualToString:@"="] && self.isEditable && self.markedTextRange == nil) {
		NSRange sel = self.selectedRange;
		NSString *all = self.text;
		MNLog(@"'=' typed in %@ sel=%@", NSStringFromClass([self class]), NSStringFromRange(sel));
		BOOL atLineEnd = sel.length == 0 && sel.location <= all.length
			&& (sel.location == all.length || [all characterAtIndex:sel.location] == '\n');
		if (atLineEnd) {
			NSUInteger lineStart = [all lineRangeForRange:NSMakeRange(sel.location, 0)].location;
			NSString *line = [all substringWithRange:NSMakeRange(lineStart, sel.location - lineStart)];
			NSString *result = MNEvaluateLine(line, MNCollectVariables(all, lineStart), NULL, NULL);
			if (result.length) {
				MNLog(@"suggesting result '%@'", result);
				%orig(text);
				NSUInteger location = self.selectedRange.location;
				%orig(result);
				gPendingBusy = YES;
				self.selectedRange = NSMakeRange(location, 0); // the caret stays in front of the suggestion
				gPendingBusy = NO;
				gPendingView = self;
				gPendingRange = NSMakeRange(location, result.length);
				gPendingText = result;
				MNHighlightRefreshLine(self);
				return;
			}
		}
	}
	%orig;
	// "=" typed after an expression that has no value ("5/0"): nothing was inserted, but the
	// operand to blame now gets its red mark.
	if ([text isEqualToString:@"="]) MNHighlightRefreshLine(self);
}

- (void)deleteBackward {
	if (pendingActive(self)) dropPending(self);
	%orig;
}

// The caret left the suggestion: it goes away.
- (void)setSelectedTextRange:(UITextRange *)range {
	%orig;
	if (gPendingBusy || !gPendingText || gPendingView != self) return;
	NSRange sel = self.selectedRange;
	if (sel.length == 0 && sel.location == gPendingRange.location) return;
	__weak ICBaseTextView *weakSelf = self;
	dispatch_async(dispatch_get_main_queue(), ^{
		ICBaseTextView *tv = weakSelf;
		if (!tv || gPendingBusy || !pendingActive(tv)) return;
		NSRange now = tv.selectedRange;
		if (now.length == 0 && now.location == gPendingRange.location) return;
		dropPending(tv);
	});
}

%end

// Everything that changes a note after the "=" was typed is handled by MNLive.
%ctor {
	NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
	NSOperationQueue *main = [NSOperationQueue mainQueue];
	Class textViewClass = %c(ICBaseTextView);

	[center addObserverForName:UITextViewTextDidChangeNotification object:nil queue:main usingBlock:^(NSNotification *note) {
		if (!textViewClass || MNLiveIsRefreshing() || ![note.object isKindOfClass:textViewClass]) return;
		MNLog(@"text changed in %@", NSStringFromClass([note.object class]));
		MNLiveTextDidChange(note.object);
	}];

	// Undo and redo change the text without UITextViewTextDidChangeNotification, so the
	// result next to an undone expression would otherwise stay stale.
	void (^onUndoRedo)(NSNotification *) = ^(NSNotification *note) {
		MNLiveUndoRedo(note.name);
	};
	[center addObserverForName:NSUndoManagerDidUndoChangeNotification object:nil queue:main usingBlock:onUndoRedo];
	[center addObserverForName:NSUndoManagerDidRedoChangeNotification object:nil queue:main usingBlock:onUndoRedo];
}
