#import "MNBase.h"

// One analysis of a whole note: for every paragraph, the variables visible on it and what the
// highlighter draws there. A calculation can change the colour of a definition far above it and the
// layout manager asks about one paragraph at a time, so answering each question on its own meant
// reading the note from the top again for every paragraph. Ranges are offsets in the note's text.
@interface MNDocument : NSObject

@property (nonatomic, readonly) NSString *text;

// Whether any paragraph is a definition line.
@property (nonatomic, readonly) BOOL hasDefinitions;

// The operands to blame for every expression without a value in the note (the red marks).
@property (nonatomic, readonly) NSArray<NSValue *> *errorRanges;

// The variables visible on the paragraph that contains `offset`: every definition above it. Past the
// last paragraph, every definition in the note.
- (NSDictionary<NSString *, NSNumber *> *)variablesAt:(NSUInteger)offset;

// What takes the result colour in the paragraph that contains `offset`: in a calculation line the
// results that are still correct and the variables they read, in a definition line the names that
// a correct calculation further down reads.
- (NSArray<NSValue *> *)coloredRangesInParagraphAt:(NSUInteger)offset;

// Only the correct result numbers of the paragraph that contains `offset`, without the variables.
- (NSArray<NSValue *> *)resultRangesInParagraphAt:(NSUInteger)offset;

// Only for a definition line: the names that a correct calculation further down reads.
- (NSArray<NSValue *> *)usedNameRangesInParagraphAt:(NSUInteger)offset;

// Every name of every definition line, in order, and whether a correct calculation below reads it.
- (void)enumerateDefinitionNames:(void (^)(NSRange name, BOOL used))block;

@end

// The analysis of `text`. The last one is kept and handed out again while the text and the Region's
// separators stay the same, so every caller during one layout pass or refresh shares a single scan.
MNDocument *MNDocumentForText(NSString *text);
