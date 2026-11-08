#import "MNLive.h"
#import "MNFormat.h"
#import "MNHighlight.h"
#import "MNLine.h"
#import "MNVariables.h"

static BOOL gRefreshing = NO;
static __weak ICBaseTextView *gActiveTextView; // last text view the user edited, for undo/redo

// Collects the edits one line needs; every range is an offset in the whole text (`docLoc` is
// where the line starts).
//
// The line the user is on (dependentsOnly NO): a wrong result is replaced, the result of an
// unfinished expression is removed, a missing result is brought back. The pair touched by the
// selection ([selStart, selEnd], relative to the line, -1 when the selection is elsewhere) is
// left alone so it can be edited by hand; it is recomputed on the next edit of the line.
//
// A line below that reads a variable (dependentsOnly YES): only a wrong result is replaced,
// and only when the expression really uses a variable, so lines the user did not touch and
// that do not depend on anything are never rewritten.
static void collectLineEdits(NSString *line, NSUInteger docLoc, NSDictionary<NSString *, NSNumber *> *vars,
	BOOL dependentsOnly, NSInteger selStart, NSInteger selEnd,
	NSMutableArray<NSValue *> *ranges, NSMutableArray<NSString *> *texts) {
	if ([line rangeOfString:@"="].location == NSNotFound) return;
	// "a = 1  b = 2" is a line of definitions: every "=" there introduces a value, not a result.
	if (MNParseDefinitions(line, NULL, NULL, NULL)) return;
	unichar dec, grp;
	MNLoadSeparators(&dec, &grp);

	NSUInteger prevEnd = 0, searchFrom = 0;
	while (searchFrom < line.length) {
		NSRange eq = [line rangeOfString:@"=" options:0 range:NSMakeRange(searchFrom, line.length - searchFrom)];
		if (eq.location == NSNotFound) break;
		NSUInteger e = eq.location;
		searchFrom = e + 1;
		NSRange tok = MNResultTokenAfter(line, e, dec, grp);
		if (tok.location == NSNotFound) {
			// "expr =" with nothing after it: bring the result back (e.g. after the user
			// repaired an expression whose result was removed). Skipped while the caret
			// sits after the "=", where the typing hook is in charge.
			if (!dependentsOnly) {
				NSString *rest = [line substringFromIndex:e + 1];
				BOOL restBlank = [rest stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].length == 0;
				if (restBlank && selEnd < (NSInteger)(e + 1)) {
					NSString *res = MNEvaluateLine([line substringToIndex:e], vars, NULL, NULL);
					if (res.length) {
						[ranges addObject:[NSValue valueWithRange:NSMakeRange(docLoc + e + 1, rest.length)]];
						[texts addObject:[@" " stringByAppendingString:res]];
					}
				}
			}
			prevEnd = e + 1;
			continue;
		}
		NSUInteger tokEnd = tok.location + tok.length;
		BOOL touched = selEnd >= (NSInteger)tok.location && selStart <= (NSInteger)tokEnd;

		BOOL usesVariables = NO;
		NSString *res = MNEvaluateLine([line substringToIndex:e], vars, NULL, &usesVariables);
		if (res.length) {
			NSString *cur = [line substringWithRange:tok];
			if (!touched && (!dependentsOnly || usesVariables) && ![cur isEqualToString:res]) {
				[ranges addObject:[NSValue valueWithRange:NSMakeRange(docLoc + tok.location, tok.length)]];
				[texts addObject:res];
			}
		} else if (!dependentsOnly && !touched) {
			NSString *seg = [line substringWithRange:NSMakeRange(prevEnd, e - prevEnd)];
			if (MNLooksLikeBrokenMath(seg)) {
				[ranges addObject:[NSValue valueWithRange:NSMakeRange(docLoc + e + 1, tokEnd - (e + 1))]];
				[texts addObject:@""];
			}
		}
		prevEnd = tokEnd;
		searchFrom = MAX(searchFrom, tokEnd);
	}
}

// Brings the results around the caret up to date: the caret's line, and, when that line
// defines a variable, every line below it that reads a variable.
//
// A non-empty selection normally means the user is doing something else, so nothing happens.
// Undo and redo are the exception: iOS 16 leaves the restored text selected, and the result
// next to an undone expression must still be recomputed. The selection is kept as it was.
static void refreshLiveResults(ICBaseTextView *tv, BOOL afterUndoRedo) {
	MNLog(@"refresh: busy=%d window=%d editable=%d marked=%d sel=%@ undoRedo=%d", gRefreshing, tv.window != nil,
		tv.isEditable, tv.markedTextRange != nil, NSStringFromRange(tv.selectedRange), afterUndoRedo);
	if (gRefreshing || !tv.window || !tv.isEditable || tv.markedTextRange != nil || !tv.textStorage) return;
	NSRange sel = tv.selectedRange;
	if (sel.length != 0 && !afterUndoRedo) {
		MNLog(@"refresh skipped: the selection is not empty");
		return;
	}
	NSString *all = tv.text;
	if (sel.location > all.length) return;

	NSRange lr = [all lineRangeForRange:NSMakeRange(sel.location, 0)];
	NSUInteger lineLen = lr.length;
	while (lineLen > 0) {
		unichar c = [all characterAtIndex:lr.location + lineLen - 1];
		if (c != '\n' && c != '\r') break;
		lineLen--;
	}
	NSString *line = [all substringWithRange:NSMakeRange(lr.location, lineLen)];
	if ([line rangeOfString:@"="].location == NSNotFound) {
		MNLog(@"refresh skipped: no '=' on the caret line '%@'", line);
		return;
	}

	NSMutableDictionary<NSString *, NSNumber *> *vars = MNCollectVariables(all, lr.location);
	NSInteger selStart = (NSInteger)sel.location - (NSInteger)lr.location;
	NSInteger selEnd = selStart + (NSInteger)sel.length;

	NSMutableArray<NSValue *> *ranges = [NSMutableArray array];
	NSMutableArray<NSString *> *texts = [NSMutableArray array];
	collectLineEdits(line, lr.location, vars, NO, selStart, selEnd, ranges, texts);

	// The caret line defines a variable: lines below that read it may now show a wrong result.
	if (MNUpdateVariables(vars, line)) {
		NSUInteger below = NSMaxRange(lr);
		if (below < all.length) {
			MNEnumerateParagraphsWithEquals(all, NSMakeRange(below, all.length - below), ^(NSString *text, NSRange paragraph, BOOL *stop) {
				if (MNUpdateVariables(vars, text)) return; // a later definition: keep following it
				collectLineEdits(text, paragraph.location, vars, YES, -1, -1, ranges, texts);
			});
		}
	}
	if (ranges.count == 0) return;

	MNLog(@"live update on line '%@': %lu change(s)", line, (unsigned long)ranges.count);

	// Notes parks the caret at the end of an edited range, so work out where the selection
	// belongs: edits before it shift it, edits after it leave it alone.
	NSInteger shift = 0;
	for (NSUInteger i = 0; i < ranges.count; i++) {
		NSRange r = ranges[i].rangeValue;
		if (NSMaxRange(r) <= sel.location) shift += (NSInteger)texts[i].length - (NSInteger)r.length;
	}
	NSRange wantedSel = NSMakeRange((NSUInteger)((NSInteger)sel.location + shift), sel.length);

	gRefreshing = YES;
	// Edit the text storage directly rather than going through the input system
	// (replaceRange:), which always parks the caret at the end of the replaced range.
	NSTextStorage *ts = tv.textStorage;
	// Keep these automatic edits out of the undo stack: one undo should revert what the user
	// typed, and the result is then recomputed, instead of needing a separate undo step.
	MNWithoutUndo(tv, ^{
		[ts beginEditing];
		for (NSInteger i = (NSInteger)ranges.count - 1; i >= 0; i--) { // right to left keeps earlier offsets valid
			NSRange r = ranges[i].rangeValue;
			NSString *expected = [all substringWithRange:r];
			if (NSMaxRange(r) > ts.length || ![[ts.string substringWithRange:r] isEqualToString:expected]) {
				MNLog(@"  skip: storage at %@ is not '%@'", NSStringFromRange(r), expected);
				continue;
			}
			MNLog(@"  '%@' -> '%@'", expected, texts[i]);
			[ts replaceCharactersInRange:r withString:texts[i]];
		}
		[ts endEditing];
	});
	if (!NSEqualRanges(tv.selectedRange, wantedSel)) {
		MNLog(@"selection %@ -> %@", NSStringFromRange(tv.selectedRange), NSStringFromRange(wantedSel));
		tv.selectedRange = wantedSel;
	}
	gRefreshing = NO;

	// The results that were just written play the colour animation. A recomputed result is new text
	// without the result colour, so without it the digits would show black for a moment before turning yellow.
	// Edits went in from right to left, so each result's new place is its old one shifted by the
	// edits before it.
	NSString *edited = tv.text;
	NSMutableArray<NSValue *> *flash = [NSMutableArray array];
	NSInteger delta = 0;
	for (NSUInteger i = 0; i < ranges.count; i++) {
		NSRange r = ranges[i].rangeValue;
		NSString *text = texts[i];
		NSInteger newLocation = (NSInteger)r.location + delta;
		delta += (NSInteger)text.length - (NSInteger)r.length;
		NSUInteger lead = 0; // "bring the result back" writes " 12": only the digits flash
		while (lead < text.length && [text characterAtIndex:lead] == ' ') lead++;
		if (lead == text.length || newLocation < 0) continue;
		NSRange digits = NSMakeRange((NSUInteger)newLocation + lead, text.length - lead);
		if (NSMaxRange(digits) <= edited.length && [[edited substringWithRange:digits] isEqualToString:[text substringFromIndex:lead]]) {
			[flash addObject:[NSValue valueWithRange:digits]];
		}
	}
	MNHighlightFlashResults(tv, flash);

	// Notes may move the caret again once its own editing pass finishes; put it back once.
	__weak ICBaseTextView *weakTV = tv;
	dispatch_async(dispatch_get_main_queue(), ^{
		ICBaseTextView *strongTV = weakTV;
		if (!strongTV || gRefreshing || strongTV.markedTextRange != nil) return;
		NSRange now = strongTV.selectedRange;
		if (!NSEqualRanges(now, wantedSel) && NSMaxRange(wantedSel) <= strongTV.text.length) {
			MNLog(@"selection re-asserted %@ -> %@", NSStringFromRange(now), NSStringFromRange(wantedSel));
			strongTV.selectedRange = wantedSel;
		}
	});
}

// Debounced like iOS 18: the refresh runs once typing pauses, not on every keystroke.
static void scheduleLiveRefresh(ICBaseTextView *tv, BOOL afterUndoRedo) {
	NSNumber *gen = @(tv.mnGeneration.unsignedIntegerValue + 1);
	tv.mnGeneration = gen;
	__weak ICBaseTextView *weakTV = tv;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		ICBaseTextView *strongTV = weakTV;
		if (!strongTV) return;
		if (![strongTV.mnGeneration isEqual:gen]) return;
		refreshLiveResults(strongTV, afterUndoRedo);
		// TextKit 1: colours do not follow edits by themselves. This also recolours a result that
		// refreshLiveResults just replaced, and with a definition in the note every line below it.
		MNHighlightRefreshLine(strongTV);
	});
}

BOOL MNLiveIsRefreshing(void) {
	return gRefreshing;
}

void MNLiveTextDidChange(ICBaseTextView *tv) {
	gActiveTextView = tv;
	MNHighlightTextChanged(tv);
	scheduleLiveRefresh(tv, NO);
}

void MNLiveUndoRedo(NSString *notificationName) {
	ICBaseTextView *tv = gActiveTextView;
	if (!tv || gRefreshing) return;
	MNLog(@"%@ -> scheduling refresh", notificationName);
	scheduleLiveRefresh(tv, YES);
}
