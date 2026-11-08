#import "MNBase.h"

// What an evaluation may use and reports back.
typedef struct {
	unichar dec; // decimal separator of the user's Region
	unichar grp; // grouping separator of the user's Region, 0 if none
	__unsafe_unretained NSDictionary<NSString *, NSNumber *> *vars; // variables by lowercase name, or nil
	BOOL allowBare;     // accept a lone number or variable (the right side of "a = 5")
	BOOL usedVariable;  // out: the expression read at least one variable
	BOOL domainError;   // out: well formed but without a value (1/0, sqrt(-1), ln(0), tan(90), overflow)
	// Optional out: receives the range (in `expr`) of every variable name that was read.
	__unsafe_unretained NSMutableArray<NSValue *> *variableRanges;
	// Out, when `domainError` is set: the range (in `expr`) of the operand that made the expression
	// lose its value, e.g. the "0" in "5/0" or the "-1" in "sqrt(-1)"; location NSNotFound if
	// there is no single culprit.
	NSRange errorRange;
} MNEvalContext;

// Evaluates `expr` (+ - x * / ^ % parentheses, functions, constants, angle units, variables)
// using the Region's separators. Returns NO unless the whole string is one valid expression
// with a finite value and at least one operation (or `allowBare` is set); a lone number is
// not an expression. A well formed expression without a value also returns NO but sets
// `domainError`, which tells it apart from text that is not an expression at all.
BOOL MNEvaluateExpression(NSString *expr, MNEvalContext *ctx, double *out);

// MNEvaluateExpression on `n` characters, for callers that try many parts of one line. Ranges
// reported through `ctx` are relative to `chars`.
BOOL MNEvaluateCharacters(const unichar *chars, NSUInteger n, MNEvalContext *ctx, double *out);

// Words the parser understands itself (functions, constants, angle units); lowercase.
// A variable cannot take one of these names.
BOOL MNIsReservedWord(NSString *lowercaseWord);
