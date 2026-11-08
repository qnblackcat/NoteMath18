#import "MNCommon.h"

// Colours the result after "=" in Notes' yellow (like iOS 18) together with the variables the calculation
// reads and, in a definition line, the names that a correct calculation below reads ("a" and "b" in
// "a=1 b=2" once "a+b=3" follows). A result that has just appeared plays a short colour animation
// from left to right. The yellow is a dynamic colour, a little brighter in dark mode. An expression
// that has no value (1/0, sqrt(-1), ...) gets a red mark under the operand to blame: the "0" in
// "5/0 =", the "-1" in "sqrt(-1) =". None of this touches the note's text; it is only drawn on
// screen, never stored or synced:
//  - TextKit 2 (Notes on iOS 17): a rendering-attributes validator, called by the layout
//    manager for every paragraph it lays out, plus direct updates for what that cannot see;
//  - TextKit 1 (Notes on iOS 16 and earlier): temporary attributes of the layout manager,
//    applied by these calls;
//  - the red mark is a thin view under the operand in both, since Notes draws no underline set
//    through attributes.

// The text view is on screen: install the validator (TextKit 2) or colour the whole note
// (TextKit 1). Safe to call repeatedly.
void MNHighlightInstall(ICBaseTextView *tv);

// The text around the caret changed: recolour it (TextKit 1), or recolour the names in the
// note's definition lines (TextKit 2), since a calculation can change the colour of a
// definition above it without that definition's paragraph being laid out again.
void MNHighlightRefreshLine(ICBaseTextView *tv);

// Plays iOS 18's short colour animation (text colour, bright yellow, usual yellow) on results that
// just appeared. `ranges` are absolute ranges of the result numbers. A flash already playing ends
// first. It also ends by itself once one of the results is edited (see MNHighlightTextChanged);
// typing elsewhere, a return after the result for instance, lets it play on.
void MNHighlightFlashResults(ICBaseTextView *tv, NSArray<NSValue *> *ranges);

// The text of `tv` may have changed: ends a flash if one of its results no longer reads the same.
void MNHighlightTextChanged(ICBaseTextView *tv);

