#import "MNBase.h"

// Finds the longest valid expression that ends at the end of `line` and returns its
// formatted result, or nil. `vars` are the variables visible on that line (see MNVariables),
// may be nil. `exprRange` receives the expression's range inside `line`, `usesVariables`
// whether it reads a variable; either may be NULL. Text up to and including the number after
// an earlier "=" is skipped: that number is the result of the previous calculation, not an
// operand.
NSString *MNEvaluateLine(NSString *line, NSDictionary<NSString *, NSNumber *> *vars, NSRange *exprRange, BOOL *usesVariables);

// The number written right after the "=" at `eqIndex` ("9" in "3 x 3 = 9"), or
// NSNotFound when nothing numeric follows or it is glued to other text ("=100d").
NSRange MNResultTokenAfter(NSString *line, NSUInteger eqIndex, unichar dec, unichar grp);

// Ranges (in `text`) of results that are still correct: "9" in "3 x 3 = 9", but not in
// "3 x 4 = 9". The variables such a calculation reads are included too ("a" and "b" in
// "a + b = 3"), as iOS 18 colours them. Silent, since the highlighter calls it for every
// laid-out paragraph.
NSArray<NSValue *> *MNConfirmedResultRanges(NSString *text, NSDictionary<NSString *, NSNumber *> *vars);

// Only the result numbers of MNConfirmedResultRanges, without the variables ("3" in "2a + 3b = 8").
NSArray<NSValue *> *MNConfirmedResultNumberRanges(NSString *text, NSDictionary<NSString *, NSNumber *> *vars);

// The variables (lowercase names) read by the calculations in `text` whose result is still
// correct: {a, b} for "a + b = 3", nothing for "a + b = 5". Silent, like MNConfirmedResultRanges.
NSSet<NSString *> *MNUsedVariableNames(NSString *text, NSDictionary<NSString *, NSNumber *> *vars);

// For each "=" that follows an expression which is well formed but has no value (1/0, sqrt(-1),
// ln(0), tan(90), overflow): the range (in `text`) of the operand to blame, which gets the red
// mark: the "0" in "5/0 =", the "-1" in "sqrt(-1) =", the whole "2^100000". Half-typed
// expressions ("5 + =") and ordinary text are never reported. Silent, like MNConfirmedResultRanges.
NSArray<NSValue *> *MNErrorTermRanges(NSString *text, NSDictionary<NSString *, NSNumber *> *vars);

// Everything the highlighter draws on a calculation line, from one scan of each "=": the result
// numbers that are still correct (`results`), the variables those calculations read (`variables`,
// ranges, and `variableNames`, lowercase) and the operands to blame for expressions without a value
// (`errors`). Ranges are in `text`. Any output may be nil; passing one array as both `results` and
// `variables` lists each calculation's names followed by its result. Silent, like the functions above.
void MNAnalyzeLine(NSString *text, NSDictionary<NSString *, NSNumber *> *vars, NSMutableArray<NSValue *> *results,
	NSMutableArray<NSValue *> *variables, NSMutableArray<NSString *> *variableNames, NSMutableArray<NSValue *> *errors);

// Calls `block` for each paragraph of `text` inside `range` that contains "=", with its text and
// range (without the line terminator).
void MNEnumerateParagraphsWithEquals(NSString *text, NSRange range, void (^block)(NSString *paragraph, NSRange paragraphRange, BOOL *stop));

// YES for a left-hand side that stopped being a valid expression ("3 x", "(2 +", "+ 2"),
// so its result should go away. Prose and algebra ("Total", "x + 2") never qualify.
BOOL MNLooksLikeBrokenMath(NSString *seg);

// Dates (26-10-2026), phone-like numbers (0912-345-678) and hex literals (0x10) are not math.
BOOL MNLooksLikeDateOrPhone(NSString *s);
