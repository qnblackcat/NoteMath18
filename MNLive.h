#import "MNCommon.h"

// Live update of results that are already in a note ("3 x 3 = 9" edited to "3 x 4" becomes
// "= 12"). Runs debounced after edits, undo and redo, on the line the caret is in.

// YES while the tweak is editing the text itself; change notifications are ignored then.
BOOL MNLiveIsRefreshing(void);

// The user edited `tv`: remember it for undo/redo and schedule a refresh.
void MNLiveTextDidChange(ICBaseTextView *tv);

// Undo or redo happened (the text view posts no change notification for those).
void MNLiveUndoRedo(NSString *notificationName);
