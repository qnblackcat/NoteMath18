#import <UIKit/UIKit.h>
#import "MNBase.h"

// Private Notes text view (subclass: ICTK2TextView on iOS 17, ICTextView on iOS 16). Declared
// only so the tweak can call UITextView API on it. The mn* properties are added to the class by
// %property in Tweak.x.
@interface ICBaseTextView : UITextView
@property (nonatomic, strong) NSNumber *mnGeneration;             // counts edits, for the debounced refresh
@property (nonatomic, strong) NSNumber *mnHighlightInstalled;     // @YES once the colouring is installed
@property (nonatomic, strong) NSMutableArray<UIView *> *mnMarkViews; // pool of the red marks under operands
@property (nonatomic, strong) id mnResultTapController;           // MNResultTapController
@end

// The text range of `tv` for `range`, offsets in its text; nil when it does not fit.
static inline UITextRange *MNTextRange(UITextView *tv, NSRange range) {
	UITextPosition *start = [tv positionFromPosition:tv.beginningOfDocument offset:(NSInteger)range.location];
	UITextPosition *end = [tv positionFromPosition:tv.beginningOfDocument offset:(NSInteger)NSMaxRange(range)];
	return (start && end) ? [tv textRangeFromPosition:start toPosition:end] : nil;
}

// Runs `edit` with undo registration off, so an edit the tweak makes by itself is never an undo step.
static inline void MNWithoutUndo(UITextView *tv, void (^edit)(void)) {
	NSUndoManager *undo = tv.undoManager;
	BOOL wasEnabled = undo.isUndoRegistrationEnabled;
	if (wasEnabled) [undo disableUndoRegistration];
	edit();
	if (wasEnabled) [undo enableUndoRegistration];
}
