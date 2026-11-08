#import "MNVariables.h"
#import "MNDocument.h"
#import "MNFormat.h"
#import "MNLine.h"
#import "MNParser.h"

BOOL MNParseDefinitions(NSString *line, NSArray<NSString *> **names, NSArray<NSString *> **expressions,
	NSArray<NSValue *> **nameRanges) {
	NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];
	NSString *text = [line stringByTrimmingCharactersInSet:whitespace];
	NSUInteger length = text.length;
	NSUInteger lead = 0; // how far the trimmed text is shifted inside `line`
	while (lead < line.length && [whitespace characterIsMember:[line characterAtIndex:lead]]) lead++;

	NSMutableArray<NSNumber *> *equals = [NSMutableArray array];
	for (NSUInteger i = 0; i < length; i++) {
		if ([text characterAtIndex:i] == '=') [equals addObject:@(i)];
	}
	if (equals.count == 0) return NO;

	// Each "=" must be preceded by a name; the first name opens the line and every later one
	// follows whitespace. What lies between one "=" and the next name is that definition's value.
	NSMutableArray<NSString *> *foundNames = [NSMutableArray array];
	NSMutableArray<NSNumber *> *nameStarts = [NSMutableArray array];
	NSMutableArray<NSValue *> *foundRanges = [NSMutableArray array];
	for (NSUInteger k = 0; k < equals.count; k++) {
		NSInteger j = (NSInteger)equals[k].unsignedIntegerValue - 1;
		while (j >= 0 && isSpace([text characterAtIndex:j])) j--;
		NSInteger last = j;
		while (j >= 0 && isNameChar([text characterAtIndex:j])) j--;
		NSInteger first = j + 1;
		if (last < first || !isWordLetter([text characterAtIndex:first])) return NO;
		if (first == 0 ? k != 0 : (k == 0 || !isSpace([text characterAtIndex:first - 1]))) return NO;
		if (k > 0 && first <= (NSInteger)equals[k - 1].unsignedIntegerValue) return NO;
		NSString *name = [text substringWithRange:NSMakeRange(first, last - first + 1)].lowercaseString;
		if (MNIsReservedWord(name)) return NO;
		[foundNames addObject:name];
		[nameStarts addObject:@(first)];
		[foundRanges addObject:[NSValue valueWithRange:NSMakeRange(lead + first, last - first + 1)]];
	}

	NSMutableArray<NSString *> *values = [NSMutableArray array];
	for (NSUInteger k = 0; k < equals.count; k++) {
		NSUInteger from = equals[k].unsignedIntegerValue + 1;
		NSUInteger to = (k + 1 < equals.count) ? nameStarts[k + 1].unsignedIntegerValue : length;
		NSString *value = [[text substringWithRange:NSMakeRange(from, to - from)] stringByTrimmingCharactersInSet:whitespace];
		if (value.length == 0) return NO;
		[values addObject:value];
	}
	if (names) *names = foundNames;
	if (expressions) *expressions = values;
	if (nameRanges) *nameRanges = foundRanges;
	return YES;
}

BOOL MNUpdateVariables(NSMutableDictionary<NSString *, NSNumber *> *vars, NSString *line) {
	NSArray<NSString *> *names, *expressions;
	if (!MNParseDefinitions(line, &names, &expressions, NULL)) return NO;
	unichar dec, grp;
	MNLoadSeparators(&dec, &grp);
	for (NSUInteger i = 0; i < names.count; i++) {
		MNEvalContext ctx = { .dec = dec, .grp = grp, .vars = vars, .allowBare = YES };
		double value;
		if (MNEvaluateExpression(expressions[i], &ctx, &value)) vars[names[i]] = @(value);
		else [vars removeObjectForKey:names[i]]; // redefined with something that does not compute
	}
	return YES;
}

NSMutableDictionary<NSString *, NSNumber *> *MNCollectVariables(NSString *text, NSUInteger limit) {
	NSMutableDictionary<NSString *, NSNumber *> *vars = [NSMutableDictionary dictionary];
	MNEnumerateParagraphsWithEquals(text, NSMakeRange(0, MIN(limit, text.length)), ^(NSString *paragraph, NSRange range, BOOL *stop) {
		MNUpdateVariables(vars, paragraph);
	});
	return vars;
}

NSArray<NSValue *> *MNUsedDefinitionRanges(NSString *document, NSUInteger paragraphStart, NSString *paragraph) {
	if (paragraphStart > document.length || !MNParseDefinitions(paragraph, NULL, NULL, NULL)) return @[];
	MNDocument *analysis = MNDocumentForText(document);
	NSMutableArray<NSValue *> *used = [NSMutableArray array];
	for (NSValue *value in [analysis usedNameRangesInParagraphAt:paragraphStart]) {
		[used addObject:[NSValue valueWithRange:NSMakeRange(value.rangeValue.location - paragraphStart, value.rangeValue.length)]];
	}
	return used;
}
