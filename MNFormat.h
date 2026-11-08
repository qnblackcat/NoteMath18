#import "MNBase.h"

// Decimal and grouping separators of the user's Region. `grp` is 0 when the Region groups
// with whitespace or has no usable separator.
void MNLoadSeparators(unichar *dec, unichar *grp);

// Result text for `v` in the Region's number format (grouping, scientific notation for very
// large or small values). nil when the value cannot be shown.
NSString *MNFormatResult(double v);

// End index of a result number starting at `k` (optional "-", digits, separators, "E<exp>").
// `digitCount` receives the number of mantissa digits; pass NULL if not needed.
NSUInteger MNResultNumberEnd(NSString *line, NSUInteger k, NSUInteger limit, unichar dec, unichar grp, NSUInteger *digitCount);

// Canonical spacing for a validated expression: " op " around the binary + - x /, nothing
// around "^", before "%" or inside parentheses, unary signs attached, "*" shown as "x".
// Function names are lowercased; variable names keep the case they were typed in.
NSString *MNNormalizeExpression(NSString *expr);

// Tests only: pretend the Region is `locale`. Pass nil to use the device's Region again.
void MNOverrideLocale(NSLocale *locale);
