#import "MNParser.h"

// Recursive descent parser. From loosest to tightest binding:
//   expr    = term (("+" | "-") term)*
//   term    = unary (("x" | "*" | "/") unary)*
//   unary   = ("-" | "+") unary | power
//   power   = primary ("^" unary)?
//   primary = number | "(" expr ")" | function "(" expr ")" | constant | variable | "√" primary,
//             each followed by an optional angle unit and any number of "%"

typedef struct {
	const unichar *s;
	NSUInteger n;
	NSUInteger i;
	unichar dec; // decimal separator of the user's Region
	unichar grp; // grouping separator of the user's Region, 0 if none/whitespace
	BOOL ok;
	NSUInteger binaryOps;
	BOOL lastWasPercent; // the operand just parsed ended with "%"
	BOOL termIsPercent;  // the term just parsed is a lone percentage
	__unsafe_unretained NSDictionary<NSString *, NSNumber *> *vars; // variables by lowercase name
	BOOL usedVariable;   // a variable was read
	__unsafe_unretained NSMutableArray<NSValue *> *variableRanges; // where the variable names sit, or nil
	BOOL hasError;       // an operation turned finite operands into infinity or NaN
	NSRange errorRange;  // the operand responsible for the first such operation
	BOOL implicitNext;   // the operand just parsed is a number written right against a name or "(": "2b", "3(4+5)"
} MNParser;

BOOL MNIsReservedWord(NSString *word) {
	static NSSet<NSString *> *words;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		// "x" is not here: the multiplication sign is only read right after an operand, where a
		// name cannot stand, so "2 x x" is 2 times the variable x.
		words = [NSSet setWithArray:@[@"sqrt", @"cbrt", @"ln", @"log", @"exp", @"abs", @"sin", @"cos", @"tan",
			@"asin", @"acos", @"atan", @"pi", @"e", @"deg", @"rad"]];
	});
	return [words containsObject:word];
}

static double parseExpr(MNParser *p);
static double parseUnary(MNParser *p);

static void skipSpaces(MNParser *p) {
	while (p->i < p->n && isSpace(p->s[p->i])) p->i++;
}

// Remembers the first operand that made the expression lose its value: [start, end) of the
// text, without trailing spaces. Later failures are only fallout of that one.
static void recordError(MNParser *p, NSUInteger start, NSUInteger end) {
	if (p->hasError) return;
	while (end > start && isSpace(p->s[end - 1])) end--;
	p->hasError = YES;
	p->errorRange = NSMakeRange(start, end - start);
}

static double parseNumber(MNParser *p) {
	char buf[64];
	NSUInteger len = 0;
	NSUInteger run = 0;

	while (p->i < p->n && isDigit(p->s[p->i])) {
		if (len < sizeof(buf) - 2) buf[len++] = (char)p->s[p->i];
		p->i++;
		run++;
	}

	// Grouping separators are only valid as 1-3 digits followed by groups of exactly 3.
	if (p->grp && p->i < p->n && p->s[p->i] == p->grp) {
		if (run == 0 || run > 3) {
			p->ok = NO;
			return 0;
		}
		while (p->i < p->n && p->s[p->i] == p->grp) {
			BOOL threeDigits = p->i + 3 < p->n
				&& isDigit(p->s[p->i + 1]) && isDigit(p->s[p->i + 2]) && isDigit(p->s[p->i + 3])
				&& (p->i + 4 >= p->n || !isDigit(p->s[p->i + 4]));
			if (!threeDigits) {
				p->ok = NO;
				return 0;
			}
			for (int k = 1; k <= 3; k++) {
				if (len < sizeof(buf) - 2) buf[len++] = (char)p->s[p->i + k];
			}
			p->i += 4;
		}
	}

	if (p->i + 1 < p->n && p->s[p->i] == p->dec && isDigit(p->s[p->i + 1])) {
		if (len < sizeof(buf) - 2) buf[len++] = '.';
		p->i++;
		while (p->i < p->n && isDigit(p->s[p->i])) {
			if (len < sizeof(buf) - 1) buf[len++] = (char)p->s[p->i];
			p->i++;
		}
	}

	if (len == 0) {
		p->ok = NO;
		return 0;
	}
	buf[len] = 0;
	return strtod(buf, NULL);
}

// Trigonometric functions work in degrees. Tiny noise such as sin(180) = 1.2e-16 becomes 0.
// A value outside a function's domain (sqrt(-1), ln(0), asin(2), tan(90)) comes back as NaN
// or infinity instead of failing the parse, so MNEvaluateExpression can report domainError.
static double applyFunction(MNParser *p, NSString *name, double v) {
	double rad = v * M_PI / 180.0;
	double out;
	if ([name isEqualToString:@"sqrt"]) return sqrt(v);
	if ([name isEqualToString:@"cbrt"]) return cbrt(v);
	if ([name isEqualToString:@"ln"]) return log(v);
	if ([name isEqualToString:@"log"]) return log10(v);
	if ([name isEqualToString:@"exp"]) return exp(v);
	if ([name isEqualToString:@"abs"]) return fabs(v);
	if ([name isEqualToString:@"sin"]) {
		out = sin(rad);
		return fabs(out) < 1e-8 ? 0 : out;
	}
	if ([name isEqualToString:@"cos"]) {
		out = cos(rad);
		return fabs(out) < 1e-8 ? 0 : out;
	}
	if ([name isEqualToString:@"tan"]) {
		if (fabs(cos(rad)) < 1e-12) return NAN; // tan(90), tan(270), ...
		out = tan(rad);
		return fabs(out) < 1e-8 ? 0 : out;
	}
	if ([name isEqualToString:@"asin"]) return asin(v) * 180.0 / M_PI;
	if ([name isEqualToString:@"acos"]) return acos(v) * 180.0 / M_PI;
	if ([name isEqualToString:@"atan"]) return atan(v) * 180.0 / M_PI;
	p->ok = NO;
	return 0;
}

// Optional angle unit right after an operand: "°" or "deg" (degrees, the default) or
// "rad" (radians, converted to degrees). Anything else is left unread.
static double applyAngleUnit(MNParser *p, double v) {
	NSUInteger save = p->i;
	skipSpaces(p);
	if (p->i < p->n && p->s[p->i] == 0x00B0) {
		p->i++;
		return v;
	}
	NSUInteger st = p->i;
	while (p->i < p->n && isWordLetter(p->s[p->i])) p->i++;
	if (p->i > st) {
		NSString *word = [[NSString stringWithCharacters:p->s + st length:p->i - st] lowercaseString];
		if ([word isEqualToString:@"deg"]) return v;
		if ([word isEqualToString:@"rad"]) return v * 180.0 / M_PI;
	}
	p->i = save;
	return v;
}

// Closes the ")" of a group or function call.
static void expectCloseParen(MNParser *p) {
	skipSpaces(p);
	if (p->i < p->n && p->s[p->i] == ')') p->i++;
	else p->ok = NO;
}

static double parsePrimary(MNParser *p) {
	skipSpaces(p);
	if (p->i >= p->n) {
		p->ok = NO;
		return 0;
	}
	unichar c = p->s[p->i];
	double v = 0;
	BOOL numberLiteral = NO;
	p->implicitNext = NO;
	if (isDigit(c) || c == p->dec) {
		v = applyAngleUnit(p, parseNumber(p));
		numberLiteral = YES;
	} else if (c == '(') {
		p->i++;
		v = parseExpr(p);
		expectCloseParen(p);
		v = applyAngleUnit(p, v);
	} else if (c == 0x03C0) { // π
		p->i++;
		v = applyAngleUnit(p, M_PI);
	} else if (c == 0x221A) { // √
		p->i++;
		p->binaryOps++;
		skipSpaces(p);
		NSUInteger operandStart = p->i;
		double operand = parsePrimary(p);
		NSUInteger operandEnd = p->i;
		v = applyFunction(p, @"sqrt", operand);
		if (!isfinite(v) && isfinite(operand)) recordError(p, operandStart, operandEnd);
	} else if (isWordLetter(c)) {
		NSUInteger st = p->i;
		while (p->i < p->n && isNameChar(p->s[p->i])) p->i++; // a name: "a", "rent", "tien_cho", "a1"
		NSString *name = [[NSString stringWithCharacters:p->s + st length:p->i - st] lowercaseString];
		NSUInteger afterName = p->i;
		skipSpaces(p);
		if (p->i < p->n && p->s[p->i] == '(') {
			p->i++;
			skipSpaces(p);
			NSUInteger argStart = p->i;
			double arg = parseExpr(p);
			NSUInteger argEnd = p->i;
			expectCloseParen(p);
			p->binaryOps++;
			v = applyFunction(p, name, arg);
			if (!isfinite(v) && isfinite(arg)) recordError(p, argStart, argEnd);
		} else {
			p->i = afterName;
			NSNumber *variable = p->vars[name];
			if ([name isEqualToString:@"pi"]) v = applyAngleUnit(p, M_PI);
			else if ([name isEqualToString:@"e"]) v = M_E;
			else if (variable) {
				v = variable.doubleValue;
				p->usedVariable = YES;
				[p->variableRanges addObject:[NSValue valueWithRange:NSMakeRange(st, afterName - st)]];
			} else p->ok = NO;
		}
	} else {
		p->ok = NO;
	}

	// A number written right against a name or "(" is multiplied with it: "2b", "2pi", "3(4+5)".
	BOOL adjacent = p->ok && p->i < p->n && (isWordLetter(p->s[p->i]) || p->s[p->i] == '(');

	// "10%" is a percentage; whether it means "of the left side" is decided in parseExpr.
	skipSpaces(p);
	BOOL percent = NO;
	while (p->ok && p->i < p->n && p->s[p->i] == '%') {
		p->i++;
		p->binaryOps++;
		v /= 100.0;
		percent = YES;
		skipSpaces(p);
	}
	p->lastWasPercent = percent;
	p->implicitNext = numberLiteral && adjacent && !percent;
	return v;
}

// Exponent binds tighter than a leading minus (-2^2 = -4) and is right associative.
static double parsePower(MNParser *p) {
	skipSpaces(p);
	NSUInteger start = p->i;
	double base = parsePrimary(p);
	skipSpaces(p);
	if (p->ok && p->i < p->n && p->s[p->i] == '^') {
		p->i++;
		p->binaryOps++;
		double exponent = parseUnary(p);
		p->lastWasPercent = NO;
		double result = pow(base, exponent);
		if (!isfinite(result) && isfinite(base) && isfinite(exponent)) recordError(p, start, p->i); // 2^100000, 0^-1
		return result;
	}
	return base;
}

static double parseUnary(MNParser *p) {
	skipSpaces(p);
	if (p->i < p->n && p->s[p->i] == '-') {
		p->i++;
		return -parseUnary(p);
	}
	if (p->i < p->n && p->s[p->i] == '+') {
		p->i++;
		return parseUnary(p);
	}
	return parsePower(p);
}

// "x" is a multiplication sign only when it stands alone between operands ("5 x 3"),
// so "0x1F", "max" or "2x" are never treated as math.
// Whether the name that starts at `j` can be an operand: a defined variable, pi, e, or a function
// called with "(". Right after an "x" that makes "2xb" 2 times b and "2xsqrt(16)" 2 times a root,
// while "5xyz" with nothing called xyz or yz stays unread.
static BOOL operandNameAt(MNParser *p, NSUInteger j) {
	NSUInteger k = j;
	while (k < p->n && isNameChar(p->s[k])) k++;
	NSString *name = [[NSString stringWithCharacters:p->s + j length:k - j] lowercaseString];
	if (p->vars[name] || [name isEqualToString:@"pi"] || [name isEqualToString:@"e"]) return YES;
	return k < p->n && p->s[k] == '(' && MNIsReservedWord(name) && ![name isEqualToString:@"deg"] && ![name isEqualToString:@"rad"];
}

static BOOL xIsMultiply(MNParser *p) {
	NSUInteger j = p->i + 1;
	if (j < p->n && isWordLetter(p->s[j])) return operandNameAt(p, j); // "2xb"
	BOOL spaced = NO;
	while (j < p->n && isSpace(p->s[j])) {
		j++;
		spaced = YES;
	}
	if (j >= p->n) return NO;
	unichar c = p->s[j];
	if (isDigit(c) || c == '(' || c == '-' || c == p->dec) return YES;
	return spaced && (isWordLetter(c) || c == 0x03C0 || c == 0x221A); // "5 x sin(30)", "5 x rent"
}

static double parseTerm(MNParser *p) {
	double v = parseUnary(p);
	BOOL percentOnly = p->lastWasPercent;
	while (p->ok) {
		skipSpaces(p);
		if (p->i >= p->n) break;
		unichar c = p->s[p->i];
		if (c == '*' || (c == 'x' && xIsMultiply(p))) {
			p->i++;
			p->binaryOps++;
			percentOnly = NO;
			skipSpaces(p);
			NSUInteger factorStart = p->i;
			double factor = parseUnary(p);
			double product = v * factor;
			if (!isfinite(product) && isfinite(v) && isfinite(factor)) recordError(p, factorStart, p->i);
			v = product;
		} else if (c == '/') {
			p->i++;
			p->binaryOps++;
			percentOnly = NO;
			skipSpaces(p);
			NSUInteger divisorStart = p->i;
			double divisor = parseUnary(p);
			double quotient = v / divisor; // x/0 is infinity or NaN: a domain error, not a syntax error
			if (!isfinite(quotient) && isfinite(v) && isfinite(divisor)) recordError(p, divisorStart, p->i);
			v = quotient;
		} else if (p->implicitNext) {
			// "2b", "2pi", "3(4+5)": no sign between a number and what follows it.
			p->implicitNext = NO;
			p->binaryOps++;
			percentOnly = NO;
			NSUInteger factorStart = p->i;
			double factor = parsePower(p);
			double product = v * factor;
			if (!isfinite(product) && isfinite(v) && isfinite(factor)) recordError(p, factorStart, p->i);
			v = product;
		} else {
			break;
		}
	}
	p->termIsPercent = percentOnly;
	return v;
}

// After + or -, a lone percentage is a share of what is on the left: 200 + 10% = 220.
static double parseExpr(MNParser *p) {
	double v = parseTerm(p);
	while (p->ok) {
		skipSpaces(p);
		if (p->i >= p->n) break;
		unichar c = p->s[p->i];
		if (c == '+' || c == '-') {
			p->i++;
			p->binaryOps++;
			double r = parseTerm(p);
			if (p->termIsPercent) r *= v;
			v = (c == '+') ? v + r : v - r;
		} else {
			break;
		}
	}
	return v;
}

BOOL MNEvaluateCharacters(const unichar *chars, NSUInteger n, MNEvalContext *ctx, double *out) {
	MNParser p = { .s = chars, .n = n, .dec = ctx->dec, .grp = ctx->grp, .ok = YES,
		.vars = ctx->vars, .variableRanges = ctx->variableRanges };
	double v = parseExpr(&p);
	skipSpaces(&p);
	BOOL wellFormed = p.ok && p.i == p.n && (p.binaryOps > 0 || ctx->allowBare);
	BOOL good = wellFormed && isfinite(v);
	ctx->usedVariable = p.usedVariable;
	ctx->domainError = wellFormed && !isfinite(v);
	ctx->errorRange = p.hasError ? p.errorRange : NSMakeRange(NSNotFound, 0);
	if (good) *out = v;
	return good;
}

BOOL MNEvaluateExpression(NSString *expr, MNEvalContext *ctx, double *out) {
	NSUInteger n = expr.length;
	unichar stackBuf[256];
	unichar *buf = n <= 256 ? stackBuf : malloc(sizeof(unichar) * n);
	[expr getCharacters:buf range:NSMakeRange(0, n)];
	BOOL good = MNEvaluateCharacters(buf, n, ctx, out);
	if (buf != stackBuf) free(buf);
	return good;
}
