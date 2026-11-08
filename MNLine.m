#import "MNLine.h"
#import "MNFormat.h"
#import "MNParser.h"

// The highlighter calls into this for every laid-out paragraph, so its calls stay silent.
#define QLog(...) do { if (!quiet) MNLog(__VA_ARGS__); } while (0)

// The date and phone patterns are anchored to the whole string (\A...\z), like NSPredicate's MATCHES.
static BOOL matches(NSRegularExpression *regex, NSString *s) {
	return [regex firstMatchInString:s options:0 range:NSMakeRange(0, s.length)] != nil;
}

BOOL MNLooksLikeDateOrPhone(NSString *s) {
	static NSRegularExpression *hex, *date, *phone;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		hex = [NSRegularExpression regularExpressionWithPattern:@"(^|[^0-9.,])0x[0-9]" options:0 error:NULL];
		// dd-mm-yy, dd-mm-yyyy and yyyy-mm-dd, with "-" or "/". Narrow on purpose: 100-20-5 is arithmetic.
		date = [NSRegularExpression regularExpressionWithPattern:@"\\A(?:\\d{1,2}[-/]\\d{1,2}[-/]\\d{2,4}|\\d{4}[-/]\\d{1,2}[-/]\\d{1,2})\\z" options:0 error:NULL];
		phone = [NSRegularExpression regularExpressionWithPattern:@"\\A\\d{3,}(?:-\\d{2,}){2,}\\z" options:0 error:NULL];
	});
	// This runs for every place an expression could start, so the regexes only run when they can match.
	if ([s rangeOfString:@"0x"].location != NSNotFound && matches(hex, s)) return YES;
	// Dates and phone numbers start with a digit and are at least "1-1-26" long.
	if (s.length < 6 || !isDigit([s characterAtIndex:0])) return NO;
	return matches(date, s) || matches(phone, s);
}

// The scan behind MNEvaluateLine. When the expression is well formed but has no value (1/0,
// sqrt(-1)) it returns nil, sets `*domainError` and still reports the expression's range, and
// `*errorTerm` gets the operand that made it lose its value (the "0" in "5/0").
//
// `variableRanges`, when given, receives the range in `line` of each variable name the
// expression reads (only for an expression that has a value).
static NSString *evaluateLine(NSString *line, NSDictionary<NSString *, NSNumber *> *vars, NSRange *exprRange,
	BOOL *usesVariables, BOOL *domainError, NSRange *errorTerm, NSMutableArray<NSValue *> *variableRanges, BOOL quiet) {
	if (usesVariables) *usesVariables = NO;
	if (domainError) *domainError = NO;
	unichar dec, grp;
	MNLoadSeparators(&dec, &grp);
	QLog(@"locale=%@ dec='%C' grp='%C' vars=%lu line='%@'", [NSLocale currentLocale].localeIdentifier, dec,
		(unichar)(grp ? grp : '-'), (unsigned long)vars.count, line);

	NSUInteger end = line.length;
	while (end > 0 && isSpace([line characterAtIndex:end - 1])) end--;
	if (end == 0) {
		QLog(@"empty line, skip");
		return nil;
	}

	// A number right after an earlier "=" is that calculation's result, not an operand
	// of the next one, so scanning starts after it.
	NSUInteger scanFrom = 0;
	NSRange eq = [line rangeOfString:@"=" options:NSBackwardsSearch];
	if (eq.location != NSNotFound) {
		NSUInteger k = eq.location + 1;
		while (k < end && isSpace([line characterAtIndex:k])) k++;
		scanFrom = MNResultNumberEnd(line, k, end, dec, grp, NULL);
		QLog(@"earlier '=' found, scanning from index %lu", (unsigned long)scanFrom);
	}

	// The parser reads straight from one copy of the line instead of a new string per candidate.
	unichar stackBuf[256];
	unichar *chars = end <= 256 ? stackBuf : malloc(sizeof(unichar) * end);
	[line getCharacters:chars range:NSMakeRange(0, end)];
	NSString *found = nil;
	for (NSUInteger st = scanFrom; st < end; st++) {
		unichar c = chars[st];
		BOOL canStart = isDigit(c) || c == '(' || c == '-' || c == '+' || c == dec
			|| isWordLetter(c) || c == 0x03C0 || c == 0x221A; // function names, variables, π, √
		if (!canStart) continue;
		if (st > 0) {
			unichar prev = chars[st - 1];
			if (!isSpace(prev) && prev != ':' && prev != '=') continue;
		}
		NSString *cand = [line substringWithRange:NSMakeRange(st, end - st)];
		if (MNLooksLikeDateOrPhone(cand)) {
			QLog(@"candidate '%@' @%lu looks like date/phone, skip", cand, (unsigned long)st);
			continue;
		}
		double v;
		NSMutableArray<NSValue *> *candidateVariables = variableRanges ? [NSMutableArray array] : nil;
		MNEvalContext ctx = { .dec = dec, .grp = grp, .vars = vars, .variableRanges = candidateVariables };
		if (MNEvaluateCharacters(chars + st, end - st, &ctx, &v)) {
			NSString *result = MNFormatResult(v);
			QLog(@"candidate '%@' @%lu = %.15g -> '%@'", cand, (unsigned long)st, v, result);
			if (!result.length) break;
			if (exprRange) *exprRange = NSMakeRange(st, end - st);
			if (usesVariables) *usesVariables = ctx.usedVariable;
			for (NSValue *name in candidateVariables) {
				[variableRanges addObject:[NSValue valueWithRange:NSMakeRange(st + name.rangeValue.location, name.rangeValue.length)]];
			}
			found = result;
			break;
		}
		if (ctx.domainError) {
			QLog(@"candidate '%@' @%lu is well formed but has no value", cand, (unsigned long)st);
			if (exprRange) *exprRange = NSMakeRange(st, end - st);
			if (domainError) *domainError = YES;
			if (errorTerm) {
				*errorTerm = ctx.errorRange.location != NSNotFound
					? NSMakeRange(st + ctx.errorRange.location, ctx.errorRange.length)
					: NSMakeRange(st, end - st);
			}
			break;
		}
		QLog(@"candidate '%@' @%lu not an expression", cand, (unsigned long)st);
	}
	if (chars != stackBuf) free(chars);
	if (!found) QLog(@"no expression found in line");
	return found;
}

NSString *MNEvaluateLine(NSString *line, NSDictionary<NSString *, NSNumber *> *vars, NSRange *exprRange, BOOL *usesVariables) {
	return evaluateLine(line, vars, exprRange, usesVariables, NULL, NULL, nil, NO);
}

NSRange MNResultTokenAfter(NSString *line, NSUInteger eqIndex, unichar dec, unichar grp) {
	NSUInteger n = line.length, k = eqIndex + 1;
	while (k < n && isSpace([line characterAtIndex:k])) k++;
	NSUInteger start = k;
	NSUInteger digits = 0;
	k = MNResultNumberEnd(line, k, n, dec, grp, &digits);
	if (digits == 0) return NSMakeRange(NSNotFound, 0);
	if (k < n && !isSpace([line characterAtIndex:k])) return NSMakeRange(NSNotFound, 0);
	return NSMakeRange(start, k - start);
}

// Calls `block` for every "=" in `text` (trailing newlines ignored) with the whole line, the "="
// and the number written right after it (location NSNotFound when there is none). Scanning goes
// on after that number: it is a result, so it holds no expression of its own.
static void forEachEquals(NSString *text, void (^block)(NSString *line, NSRange equals, NSRange result)) {
	if ([text rangeOfString:@"="].location == NSNotFound) return;
	NSUInteger length = text.length;
	while (length > 0) {
		unichar c = [text characterAtIndex:length - 1];
		if (c != '\n' && c != '\r') break;
		length--;
	}
	NSString *line = [text substringToIndex:length];

	unichar dec, grp;
	MNLoadSeparators(&dec, &grp);
	NSUInteger searchFrom = 0;
	while (searchFrom < line.length) {
		NSRange equals = [line rangeOfString:@"=" options:0 range:NSMakeRange(searchFrom, line.length - searchFrom)];
		if (equals.location == NSNotFound) break;
		searchFrom = equals.location + 1;
		NSRange result = MNResultTokenAfter(line, equals.location, dec, grp);
		block(line, equals, result);
		if (result.location != NSNotFound) searchFrom = MAX(searchFrom, NSMaxRange(result));
	}
}

void MNAnalyzeLine(NSString *text, NSDictionary<NSString *, NSNumber *> *vars, NSMutableArray<NSValue *> *results,
	NSMutableArray<NSValue *> *variables, NSMutableArray<NSString *> *variableNames, NSMutableArray<NSValue *> *errors) {
	BOOL wantsConfirmed = results || variables || variableNames;
	forEachEquals(text, ^(NSString *line, NSRange equals, NSRange result) {
		BOOL hasResult = result.location != NSNotFound;
		if (!(hasResult && wantsConfirmed) && !errors) return;
		NSString *before = [line substringToIndex:equals.location];
		NSMutableArray<NSValue *> *names = hasResult && (variables || variableNames) ? [NSMutableArray array] : nil;
		BOOL domainError = NO;
		NSRange term = NSMakeRange(0, 0);
		NSString *calculated = evaluateLine(before, vars, NULL, NULL, &domainError, &term, names, YES);
		if (domainError) [errors addObject:[NSValue valueWithRange:term]];
		// Only a calculation whose result is still correct counts as reading its variables.
		if (!hasResult || !calculated.length || ![calculated isEqualToString:[line substringWithRange:result]]) return;
		// Like iOS 18: the variables the calculation reads take the result colour along with its result.
		[variables addObjectsFromArray:names];
		for (NSValue *name in names) [variableNames addObject:[before substringWithRange:name.rangeValue].lowercaseString];
		[results addObject:[NSValue valueWithRange:result]];
	});
}

NSArray<NSValue *> *MNConfirmedResultRanges(NSString *text, NSDictionary<NSString *, NSNumber *> *vars) {
	NSMutableArray<NSValue *> *found = [NSMutableArray array];
	MNAnalyzeLine(text, vars, found, found, nil, nil); // one array: each calculation's names, then its result
	return found;
}

NSArray<NSValue *> *MNConfirmedResultNumberRanges(NSString *text, NSDictionary<NSString *, NSNumber *> *vars) {
	NSMutableArray<NSValue *> *found = [NSMutableArray array];
	MNAnalyzeLine(text, vars, found, nil, nil, nil);
	return found;
}

NSSet<NSString *> *MNUsedVariableNames(NSString *text, NSDictionary<NSString *, NSNumber *> *vars) {
	if (vars.count == 0) return [NSSet set];
	NSMutableArray<NSString *> *names = [NSMutableArray array];
	MNAnalyzeLine(text, vars, nil, nil, names, nil);
	return [NSSet setWithArray:names];
}

NSArray<NSValue *> *MNErrorTermRanges(NSString *text, NSDictionary<NSString *, NSNumber *> *vars) {
	NSMutableArray<NSValue *> *found = [NSMutableArray array];
	MNAnalyzeLine(text, vars, nil, nil, nil, found);
	return found;
}

void MNEnumerateParagraphsWithEquals(NSString *text, NSRange range, void (^block)(NSString *paragraph, NSRange paragraphRange, BOOL *stop)) {
	[text enumerateSubstringsInRange:range options:NSStringEnumerationByParagraphs | NSStringEnumerationSubstringNotRequired
		usingBlock:^(NSString *substring, NSRange paragraph, NSRange enclosing, BOOL *stop) {
		if ([text rangeOfString:@"=" options:0 range:paragraph].location == NSNotFound) return;
		block([text substringWithRange:paragraph], paragraph, stop);
	}];
}

// Only numbers, + - x * / ^ % ( ), at least one digit and one operator (a leading sign counts).
// Lines with function names (sin, sqrt...) are not covered: their stale result stays put.
BOOL MNLooksLikeBrokenMath(NSString *seg) {
	NSString *t = [seg stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
	if (t.length == 0) return NO;
	static NSCharacterSet *allowed;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		allowed = [NSCharacterSet characterSetWithCharactersInString:@"0123456789.,+-x*/^%() \t"];
	});
	if ([t rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return NO;
	if (MNLooksLikeDateOrPhone(t)) return NO;
	if (![t rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet]].length) return NO;
	if ([t rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"+-x*/^"]].location == NSNotFound) return NO;
	// A leading "x" is a multiplication fragment ("x 5" left over from "3 x 5") only when a
	// number or "(" follows; "x + 2" is algebra and must keep its result.
	if ([t characterAtIndex:0] == 'x') {
		NSUInteger j = 1;
		while (j < t.length && isSpace([t characterAtIndex:j])) j++;
		if (j >= t.length) return NO;
		unichar next = [t characterAtIndex:j];
		if (!(isDigit(next) || next == '(' || next == '.' || next == ',')) return NO;
	}
	return YES;
}
