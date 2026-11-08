#import "MNCommon.h"

// Tap a coloured result and the whole number is selected and iOS's own edit menu (Copy, Paste, ...)
// appears on it: for "100 * 5 = 500" a tap on the 500 selects "500". Needs iOS 16's edit menu;
// earlier systems do nothing. The tap recogniser only takes part when the touch lands on a result
// that is still correct, so every other tap reaches Notes untouched. Safe to call repeatedly for
// the same text view.
void MNResultTapInstall(ICBaseTextView *tv);
