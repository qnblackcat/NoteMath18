#import "MNBase.h"

// Variables: `name = expression` defines `name` for the lines below it, e.g.
//     rent = 1500
//     rent x 12 =        ->   rent x 12 = 18.000
// Several definitions may share a line: `a = 1  b = 2  c = a + b`. A name starts with a letter
// (any language) and goes on with letters, digits and "_"; it is case-insensitive and cannot
// be a function, a constant or an angle unit ("x" is fine: "2 x x" is 2 times the variable x).
// Keys of the dictionaries below are lowercase names.

// Splits a line that consists only of definitions into their names (lowercased), expressions
// and the range of each name inside `line`, in order. NO for any other line, e.g.
// "3 x 3 = 9", "tiền thuê = 5" or "a = b = 5". Any output may be NULL.
BOOL MNParseDefinitions(NSString *line, NSArray<NSString *> **names, NSArray<NSString *> **expressions,
	NSArray<NSValue *> **nameRanges);

// If `line` consists of definitions, stores their values in `vars` in order (a later one may
// use an earlier one; one that does not compute is removed) and returns YES. Any other line: NO.
BOOL MNUpdateVariables(NSMutableDictionary<NSString *, NSNumber *> *vars, NSString *line);

// The variables visible at offset `limit` of `text`: every definition on the lines above it,
// later definitions replacing earlier ones.
NSMutableDictionary<NSString *, NSNumber *> *MNCollectVariables(NSString *text, NSUInteger limit);

// For a definition line (`paragraph`, starting at `paragraphStart` in `document`): the ranges,
// relative to `paragraph`, of the names whose variable is read by a calculation further down
// whose result is still correct ("a" and "b" in "a=1 b=2" once "a+b=3" follows). A variable
// that no calculation reads, or that is redefined before one does, is not included; neither
// is any other kind of line. Answered from the note's MNDocument.
NSArray<NSValue *> *MNUsedDefinitionRanges(NSString *document, NSUInteger paragraphStart, NSString *paragraph);
