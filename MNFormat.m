#import "MNFormat.h"
#import "MNParser.h"

static NSLocale *gLocaleOverride;

// Built from the Region once and kept until it changes: the separators are asked for on every line
// the highlighter looks at, and a number formatter is costly to create.
static BOOL gSeparatorsLoaded;
static unichar gDec, gGrp;
static NSNumberFormatter *gFormatter;

static void resetLocaleCaches(void) {
	gSeparatorsLoaded = NO;
	gFormatter = nil;
}

static NSLocale *currentLocale(void) {
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		[[NSNotificationCenter defaultCenter] addObserverForName:NSCurrentLocaleDidChangeNotification object:nil
			queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
			resetLocaleCaches();
		}];
	});
	return gLocaleOverride ?: [NSLocale currentLocale];
}

void MNOverrideLocale(NSLocale *locale) {
	gLocaleOverride = locale;
	resetLocaleCaches();
}

void MNLoadSeparators(unichar *dec, unichar *grp) {
	if (!gSeparatorsLoaded) {
		NSLocale *loc = currentLocale();
		NSString *decStr = [loc objectForKey:NSLocaleDecimalSeparator];
		NSString *grpStr = [loc objectForKey:NSLocaleGroupingSeparator];
		gDec = decStr.length ? [decStr characterAtIndex:0] : '.';
		gGrp = grpStr.length ? [grpStr characterAtIndex:0] : 0;
		if (isSpace(gGrp) || gGrp == 0x202F || gGrp == gDec) gGrp = 0;
		gSeparatorsLoaded = YES;
	}
	*dec = gDec;
	*grp = gGrp;
}

// Very large or small values, e.g. 2^100, use scientific notation: "1,26765006E30".
static NSString *formatScientific(double v) {
	char buf[40];
	snprintf(buf, sizeof(buf), "%.9e", v);
	NSString *s = [NSString stringWithUTF8String:buf];
	NSRange e = [s rangeOfString:@"e"];
	if (e.location == NSNotFound) return nil;
	NSString *mantissa = [s substringToIndex:e.location];
	NSInteger exponent = [s substringFromIndex:e.location + 1].integerValue;
	if ([mantissa containsString:@"."]) {
		while ([mantissa hasSuffix:@"0"]) mantissa = [mantissa substringToIndex:mantissa.length - 1];
		if ([mantissa hasSuffix:@"."]) mantissa = [mantissa substringToIndex:mantissa.length - 1];
	}
	NSString *decimal = [currentLocale() objectForKey:NSLocaleDecimalSeparator] ?: @".";
	mantissa = [mantissa stringByReplacingOccurrencesOfString:@"." withString:decimal];
	return [NSString stringWithFormat:@"%@E%ld", mantissa, (long)exponent];
}

NSString *MNFormatResult(double v) {
	if (!isfinite(v)) return nil;
	if (v == 0 || fabs(v) < 1e-12) v = 0; // drops -0.0 and float noise such as 0.1+0.2-0.3
	if (fabs(v) >= 1e15 || (v != 0 && fabs(v) < 1e-9)) return formatScientific(v);
	if (!gFormatter) {
		NSNumberFormatter *fmt = [NSNumberFormatter new];
		fmt.locale = currentLocale();
		fmt.numberStyle = NSNumberFormatterDecimalStyle;
		fmt.usesGroupingSeparator = YES;
		fmt.minimumFractionDigits = 0;
		fmt.maximumFractionDigits = 10;
		gFormatter = fmt;
	}
	return [gFormatter stringFromNumber:@(v)];
}

NSUInteger MNResultNumberEnd(NSString *line, NSUInteger k, NSUInteger limit, unichar dec, unichar grp, NSUInteger *digitCount) {
	NSUInteger digits = 0;
	if (k < limit && [line characterAtIndex:k] == '-') k++;
	while (k < limit) {
		unichar c = [line characterAtIndex:k];
		if (isDigit(c)) digits++;
		else if (!(c == dec || (grp && c == grp))) break;
		k++;
	}
	if (digits > 0 && k + 1 < limit && [line characterAtIndex:k] == 'E') {
		NSUInteger j = k + 1;
		if ([line characterAtIndex:j] == '-') j++;
		NSUInteger expStart = j;
		while (j < limit && isDigit([line characterAtIndex:j])) j++;
		if (j > expStart) k = j;
	}
	if (digitCount) *digitCount = digits;
	return k;
}

NSString *MNNormalizeExpression(NSString *expr) {
	NSMutableString *out = [NSMutableString string];
	BOOL afterOperand = NO;
	NSUInteger n = expr.length, i = 0;
	while (i < n) {
		unichar c = [expr characterAtIndex:i];
		if (isSpace(c)) {
			i++;
			continue;
		}
		if (isWordLetter(c)) {
			// Where an operand may start the word is a whole name ("tien_cho", "a1"); right after
			// an operand it is only letters, so "5x3" stays "5 x 3" and "30rad" a unit.
			NSUInteger st = i;
			while (i < n && (afterOperand ? isWordLetter([expr characterAtIndex:i]) : isNameChar([expr characterAtIndex:i]))) i++;
			NSString *typed = [expr substringWithRange:NSMakeRange(st, i - st)];
			NSString *lower = typed.lowercaseString;
			NSString *shown = MNIsReservedWord(lower) ? lower : typed; // variables keep their case
			NSUInteger j = i;
			while (j < n && isSpace([expr characterAtIndex:j])) j++;
			BOOL isCall = j < n && [expr characterAtIndex:j] == '(';
			if (afterOperand && [lower isEqualToString:@"x"]) {
				[out appendString:@" x "];
				afterOperand = NO;
			} else if (afterOperand && lower.length > 1 && [lower hasPrefix:@"x"]) {
				// "2xb" is 2 x b: the multiplication sign, then the name that follows it.
				[out appendString:@" x "];
				afterOperand = NO;
				i = st + 1;
			} else if (afterOperand) {
				[out appendString:shown]; // angle unit: "deg" or "rad"
			} else {
				[out appendString:shown];
				afterOperand = !isCall; // a function name is followed by "(", anything else is an operand
			}
			continue;
		}
		i++;
		if (c == '(' || c == 0x221A || c == '^') {
			[out appendFormat:@"%C", c];
			afterOperand = NO;
		} else if (c == ')' || c == '%' || c == 0x03C0 || c == 0x00B0) {
			[out appendFormat:@"%C", c];
			afterOperand = YES;
		} else if (c == '+' || c == '-' || c == '*' || c == '/') {
			unichar op = (c == '*') ? 'x' : c;
			if (afterOperand) [out appendFormat:@" %C ", op];
			else [out appendFormat:@"%C", op];
			afterOperand = NO;
		} else {
			[out appendFormat:@"%C", c]; // digits and separators
			afterOperand = YES;
		}
	}
	return out;
}
